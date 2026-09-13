package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/config"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/health"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/queue"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(logger); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("worker stopped", "safe_code", "worker_stopped", "error", err.Error())
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.ScratchRoot, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(cfg.ScratchRoot, 0o700); err != nil {
		return err
	}

	database, err := queue.OpenWorkerDatabase(cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer database.Close()
	database.SetMaxOpenConns(4)
	database.SetMaxIdleConns(2)
	database.SetConnMaxLifetime(15 * time.Minute)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	pingContext, cancelPing := context.WithTimeout(ctx, 10*time.Second)
	err = database.PingContext(pingContext)
	cancelPing()
	if err != nil {
		return err
	}

	var storageClient *storage.Client
	var storageReady func(context.Context) error
	var staticMediaReady func(context.Context) error
	httpClient := &http.Client{Timeout: 15 * time.Minute}
	if cfg.StorageAuthMode == config.StorageAuthDatabaseRenewal {
		issuer, issuerErr := storage.NewDatabaseCredentialIssuer(database)
		if issuerErr != nil {
			return issuerErr
		}
		credentials, credentialErr := storage.NewCredentialCache(ctx, issuer, cfg.WorkerID, cfg.StorageURL, time.Now)
		if credentialErr != nil {
			return credentialErr
		}
		storageClient, err = storage.NewClientWithTokenSource(cfg.StorageURL, cfg.StoragePublishableKey, credentials, httpClient)
		storageReady = credentials.Ready
	} else {
		storageClient, err = storage.NewClient(cfg.StorageURL, cfg.StoragePublishableKey, cfg.StorageWorkerToken, httpClient)
		if err == nil {
			staticMediaReady, err = config.NewStaticMediaAdmission(cfg.StorageWorkerToken, cfg.WorkerID, time.Now)
		}
	}
	if err != nil {
		return err
	}
	attempts, err := jobs.NewSQLAttemptStore(database)
	if err != nil {
		return err
	}
	cleanup, err := jobs.NewSQLCleanupQueue(database)
	if err != nil {
		return err
	}
	runner, err := sandbox.NewRunner(cfg.PodmanPath, nil)
	if err != nil {
		return err
	}
	var activeClassifier classifier.Classifier = classifier.Noop{}
	if cfg.ClassifierImage != "" {
		activeClassifier, err = classifier.NewSandboxed(runner, cfg.ClassifierImage)
		if err != nil {
			return err
		}
	}
	processor, err := jobs.NewProcessor(jobs.Dependencies{
		Attempts: attempts, Blobs: storageClient, Sandbox: runner,
		Classifier: activeClassifier, Classification: attempts, Cleanup: cleanup,
		ScratchRoot: cfg.ScratchRoot, MediaImage: cfg.MediaImage,
		VerifierImage: cfg.VerifierImage, HeartbeatInterval: cfg.HeartbeatInterval,
		LeaseDuration: cfg.LeaseDuration, PolicyDigest: cfg.MediaPolicyDigest, StillPolicyDigest: cfg.StillPolicyDigest,
	})
	if err != nil {
		return err
	}
	exportProcessor, err := jobs.NewExportProcessor(attempts, storageClient, cfg.ScratchRoot)
	if err != nil {
		return err
	}
	promotionProcessor, err := jobs.NewPromotionProcessor(attempts, storageClient, cfg.ScratchRoot)
	if err != nil {
		return err
	}
	cleanupProcessor, err := jobs.NewCleanupProcessor(cfg.ScratchRoot, storageClient, attempts)
	if err != nil {
		return err
	}
	backupProcessor, err := jobs.NewBackupVerificationProcessor(attempts, storageClient, cfg.ScratchRoot)
	if err != nil {
		return err
	}
	accountDeletionProcessor, err := jobs.NewAccountDeletionProcessor(attempts)
	if err != nil {
		return err
	}
	pgmqBackend, err := queue.NewPGMQBackend(database)
	if cfg.StillPolicyDigest != "" {
		pgmqBackend, err = queue.NewPGMQBackendV2(database)
	}
	if err != nil {
		return err
	}
	var backend queue.Backend = pgmqBackend
	if storageReady != nil {
		backend, err = queue.NewStorageGatedBackend(backend, storageReady)
		if err != nil {
			return err
		}
	}
	if staticMediaReady != nil {
		backend, err = queue.NewMediaAdmissionGatedBackend(backend, staticMediaReady)
		if err != nil {
			return err
		}
	}
	readiness := storageReady
	if staticMediaReady != nil {
		readiness = staticMediaReady
	}
	metrics := health.NewMetrics()
	healthHandler, err := health.NewHandler(metrics, databaseReadiness{database: database, storageReady: readiness})
	if err != nil {
		return err
	}
	handler := &instrumentedProcessor{processor: processor, metrics: metrics, logger: logger}
	consumer, err := queue.NewConsumer(backend, handler, cfg.QueueName, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	exportConsumer, err := queue.NewExportConsumer(backend, exportProcessor, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	promotionConsumer, err := queue.NewPromotionConsumer(backend, promotionProcessor, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	cleanupConsumer, err := queue.NewCleanupConsumer(backend, cleanupProcessor, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	backupConsumer, err := queue.NewBackupVerificationConsumer(backend, backupProcessor, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	accountDeletionConsumer, err := queue.NewAccountDeletionConsumer(backend, accountDeletionProcessor, cfg.WorkerID, cfg.VisibilityTimeout, cfg.RetryDelay)
	if err != nil {
		return err
	}
	logger.Info("worker started", "worker_id", cfg.WorkerID, "classifier_enabled", activeClassifier.Enabled())
	serviceContext, stopServices := context.WithCancel(ctx)
	serviceErrors := make(chan error, 7)
	go func() { serviceErrors <- consumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- exportConsumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- promotionConsumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- cleanupConsumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- backupConsumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- accountDeletionConsumer.Run(serviceContext, cfg.IdleDelay) }()
	go func() { serviceErrors <- health.ServeUnix(serviceContext, cfg.HealthSocket, healthHandler) }()
	err = <-serviceErrors
	stopServices()
	for range 6 {
		<-serviceErrors
	}
	snapshot := metrics.Snapshot()
	logger.Info("worker stopped", "jobs", snapshot.Total, "duration_ms", snapshot.DurationTotal.Milliseconds())
	return err
}

type databaseReadiness struct {
	database     *sql.DB
	storageReady func(context.Context) error
}

func (readiness databaseReadiness) Ready(ctx context.Context) error {
	if err := readiness.database.PingContext(ctx); err != nil {
		return err
	}
	if readiness.storageReady != nil {
		return readiness.storageReady(ctx)
	}
	return nil
}

type instrumentedProcessor struct {
	processor *jobs.Processor
	metrics   *health.Metrics
	logger    *slog.Logger
}

func (p *instrumentedProcessor) Process(ctx context.Context, job jobs.ProcessSubmission, lease jobs.Lease) jobs.Result {
	started := time.Now()
	result := p.processor.Process(ctx, job, lease)
	p.metrics.Record(result.SafeCode, time.Since(started))
	p.logger.Info("attempt finished", "attempt_id", job.AttemptID, "submission_id", job.SubmissionID,
		"generation", job.Generation, "safe_code", result.SafeCode)
	return result
}
