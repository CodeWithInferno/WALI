package queue

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/config"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/stdlib"
)

var (
	queueNamePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)
	workerIDPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)
)

type Message struct {
	ID           int64
	Body         []byte
	VisibleUntil time.Time
}

type Backend interface {
	Read(context.Context, string, time.Duration) (Message, bool, error)
	Ack(context.Context, string, int64) error
	Nack(context.Context, string, int64, time.Duration) error
	Reject(context.Context, string, int64, string) error
}

type Handler interface {
	Process(context.Context, jobs.ProcessSubmission, jobs.Lease) jobs.Result
}

type ExportHandler interface {
	Process(context.Context, jobs.ExportJob, jobs.Lease) jobs.Result
}

type PromotionHandler interface {
	Process(context.Context, jobs.PromotionJob, jobs.Lease) jobs.Result
}

type CleanupHandler interface {
	Process(context.Context, jobs.CleanupJob, jobs.Lease) jobs.Result
}

type BackupVerificationHandler interface {
	Process(context.Context, jobs.BackupVerificationJob, jobs.Lease) jobs.Result
}

type AccountDeletionHandler interface {
	Process(context.Context, jobs.AccountDeletionJob, jobs.Lease) jobs.Result
}

type Consumer struct {
	backend    Backend
	handler    Handler
	queueName  string
	workerID   string
	visibility time.Duration
	retryDelay time.Duration
}

func NewConsumer(backend Backend, handler Handler, queueName, workerID string, visibility, retryDelay time.Duration) (*Consumer, error) {
	if backend == nil || handler == nil {
		return nil, errors.New("queue backend and handler are required")
	}
	if !queueNamePattern.MatchString(queueName) || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("queue name and worker ID must be bounded lowercase identifiers")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute {
		return nil, errors.New("visibility must be between 30 seconds and 30 minutes")
	}
	if retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("retry delay must be between 1 second and 15 minutes")
	}
	return &Consumer{
		backend: backend, handler: handler, queueName: queueName, workerID: workerID,
		visibility: visibility, retryDelay: retryDelay,
	}, nil
}

func (c *Consumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, c.queueName, c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodeProcessSubmission(bytes.NewReader(message.Body), 16<<10)
	if err != nil {
		if rejectErr := c.backend.Reject(ctx, c.queueName, message.ID, "invalid_job_envelope"); rejectErr != nil {
			return true, fmt.Errorf("reject invalid message: %w", rejectErr)
		}
		return true, nil
	}
	result := c.handler.Process(ctx, job, jobs.Lease{
		MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil,
	})
	return true, finishMessage(ctx, c.backend, c.queueName, message.ID, c.retryDelay, result)
}

func finishMessage(ctx context.Context, backend Backend, queueName string, messageID int64, retryDelay time.Duration, result jobs.Result) error {
	switch result.Action {
	case jobs.ActionAck:
		return backend.Ack(ctx, queueName, messageID)
	case jobs.ActionNack:
		return backend.Nack(ctx, queueName, messageID, retryDelay)
	case jobs.ActionLeave:
		return nil
	default:
		return errors.New("processor returned an invalid queue action")
	}
}

func (c *Consumer) Run(ctx context.Context, idleDelay time.Duration) error {
	if idleDelay < 100*time.Millisecond || idleDelay > time.Minute {
		return errors.New("idle delay must be between 100 milliseconds and 1 minute")
	}
	for {
		processed, err := c.RunOnce(ctx)
		if err != nil {
			return err
		}
		if processed {
			continue
		}
		timer := time.NewTimer(idleDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

type ExportConsumer struct {
	backend                Backend
	handler                ExportHandler
	workerID               string
	visibility, retryDelay time.Duration
}

func NewExportConsumer(backend Backend, handler ExportHandler, workerID string, visibility, retryDelay time.Duration) (*ExportConsumer, error) {
	if backend == nil || handler == nil || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("export consumer dependencies are invalid")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute || retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("export consumer timing is invalid")
	}
	return &ExportConsumer{backend: backend, handler: handler, workerID: workerID, visibility: visibility, retryDelay: retryDelay}, nil
}

func (c *ExportConsumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, "wali_exports", c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodeExportJob(bytes.NewReader(message.Body), 16<<10)
	if err != nil {
		return true, c.backend.Reject(ctx, "wali_exports", message.ID, "invalid_job_envelope")
	}
	result := c.handler.Process(ctx, job, jobs.Lease{MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil})
	return true, finishMessage(ctx, c.backend, "wali_exports", message.ID, c.retryDelay, result)
}

func (c *ExportConsumer) Run(ctx context.Context, idleDelay time.Duration) error {
	return runLoop(ctx, idleDelay, c.RunOnce)
}

type PromotionConsumer struct {
	backend                Backend
	handler                PromotionHandler
	workerID               string
	visibility, retryDelay time.Duration
}

func NewPromotionConsumer(backend Backend, handler PromotionHandler, workerID string, visibility, retryDelay time.Duration) (*PromotionConsumer, error) {
	if backend == nil || handler == nil || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("promotion consumer dependencies are invalid")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute || retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("promotion consumer timing is invalid")
	}
	return &PromotionConsumer{backend: backend, handler: handler, workerID: workerID, visibility: visibility, retryDelay: retryDelay}, nil
}

func (c *PromotionConsumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, "wali_promotions", c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodePromotionJob(bytes.NewReader(message.Body), 64<<10)
	if err != nil {
		return true, c.backend.Reject(ctx, "wali_promotions", message.ID, "invalid_job_envelope")
	}
	result := c.handler.Process(ctx, job, jobs.Lease{MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil})
	return true, finishMessage(ctx, c.backend, "wali_promotions", message.ID, c.retryDelay, result)
}

func (c *PromotionConsumer) Run(ctx context.Context, idleDelay time.Duration) error {
	return runLoop(ctx, idleDelay, c.RunOnce)
}

type CleanupConsumer struct {
	backend                Backend
	handler                CleanupHandler
	workerID               string
	visibility, retryDelay time.Duration
}

func NewCleanupConsumer(backend Backend, handler CleanupHandler, workerID string, visibility, retryDelay time.Duration) (*CleanupConsumer, error) {
	if backend == nil || handler == nil || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("cleanup consumer dependencies are invalid")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute || retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("cleanup consumer timing is invalid")
	}
	return &CleanupConsumer{backend: backend, handler: handler, workerID: workerID, visibility: visibility, retryDelay: retryDelay}, nil
}

func (c *CleanupConsumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, "wali_cleanup", c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodeCleanupJob(bytes.NewReader(message.Body), 4<<10)
	if err != nil {
		return true, c.backend.Reject(ctx, "wali_cleanup", message.ID, "invalid_job_envelope")
	}
	result := c.handler.Process(ctx, job, jobs.Lease{MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil})
	return true, finishMessage(ctx, c.backend, "wali_cleanup", message.ID, c.retryDelay, result)
}

func (c *CleanupConsumer) Run(ctx context.Context, idleDelay time.Duration) error {
	return runLoop(ctx, idleDelay, c.RunOnce)
}

type BackupVerificationConsumer struct {
	backend                Backend
	handler                BackupVerificationHandler
	workerID               string
	visibility, retryDelay time.Duration
}

func NewBackupVerificationConsumer(backend Backend, handler BackupVerificationHandler, workerID string, visibility, retryDelay time.Duration) (*BackupVerificationConsumer, error) {
	if backend == nil || handler == nil || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("backup verification consumer dependencies are invalid")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute || retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("backup verification consumer timing is invalid")
	}
	return &BackupVerificationConsumer{backend: backend, handler: handler, workerID: workerID, visibility: visibility, retryDelay: retryDelay}, nil
}

func (c *BackupVerificationConsumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, "wali_backup_verification", c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodeBackupVerificationJob(bytes.NewReader(message.Body), 4<<10)
	if err != nil {
		return true, c.backend.Reject(ctx, "wali_backup_verification", message.ID, "invalid_job_envelope")
	}
	result := c.handler.Process(ctx, job, jobs.Lease{MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil})
	return true, finishMessage(ctx, c.backend, "wali_backup_verification", message.ID, c.retryDelay, result)
}

func (c *BackupVerificationConsumer) Run(ctx context.Context, idleDelay time.Duration) error {
	return runLoop(ctx, idleDelay, c.RunOnce)
}

type AccountDeletionConsumer struct {
	backend                Backend
	handler                AccountDeletionHandler
	workerID               string
	visibility, retryDelay time.Duration
}

func NewAccountDeletionConsumer(backend Backend, handler AccountDeletionHandler, workerID string, visibility, retryDelay time.Duration) (*AccountDeletionConsumer, error) {
	if backend == nil || handler == nil || !workerIDPattern.MatchString(workerID) {
		return nil, errors.New("account deletion consumer dependencies are invalid")
	}
	if visibility < 30*time.Second || visibility > 30*time.Minute || retryDelay < time.Second || retryDelay > 15*time.Minute {
		return nil, errors.New("account deletion consumer timing is invalid")
	}
	return &AccountDeletionConsumer{backend: backend, handler: handler, workerID: workerID, visibility: visibility, retryDelay: retryDelay}, nil
}

func (c *AccountDeletionConsumer) RunOnce(ctx context.Context) (bool, error) {
	message, found, err := c.backend.Read(ctx, "wali_account_deletions", c.visibility)
	if err != nil || !found {
		return false, err
	}
	job, err := jobs.DecodeAccountDeletionJob(bytes.NewReader(message.Body), 4<<10)
	if err != nil {
		return true, c.backend.Reject(ctx, "wali_account_deletions", message.ID, "invalid_job_envelope")
	}
	result := c.handler.Process(ctx, job, jobs.Lease{MessageID: message.ID, Owner: c.workerID, ExpiresAt: message.VisibleUntil})
	return true, finishMessage(ctx, c.backend, "wali_account_deletions", message.ID, c.retryDelay, result)
}

func (c *AccountDeletionConsumer) Run(ctx context.Context, idleDelay time.Duration) error {
	return runLoop(ctx, idleDelay, c.RunOnce)
}

func runLoop(ctx context.Context, idleDelay time.Duration, runOnce func(context.Context) (bool, error)) error {
	if idleDelay < 100*time.Millisecond || idleDelay > time.Minute {
		return errors.New("idle delay must be between 100 milliseconds and 1 minute")
	}
	for {
		processed, err := runOnce(ctx)
		if err != nil {
			return err
		}
		if processed {
			continue
		}
		timer := time.NewTimer(idleDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

type PGMQBackend struct {
	database *sql.DB
	mediaV2  bool
}

type databaseRoleSession interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

const workerRoleVerificationQuery = "select current_user::text, session_user::text, " +
	"coalesce((select rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb and not rolcreaterole and not rolreplication and not rolbypassrls from pg_catalog.pg_roles where rolname = session_user), false), " +
	"coalesce((select not rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb and not rolcreaterole and not rolreplication and not rolbypassrls from pg_catalog.pg_roles where rolname = current_user), false)"

// ActivateWorkerDatabaseRole is deliberately fixed: neither the role nor the
// verification query can be influenced by configuration or queue data.
func ActivateWorkerDatabaseRole(ctx context.Context, session databaseRoleSession) error {
	if session == nil {
		return errors.New("database session is required")
	}
	if _, err := session.Exec(ctx, "set role wali_worker"); err != nil {
		return fmt.Errorf("activate worker database role: %w", err)
	}
	var currentUser, sessionUser string
	var loginRestricted, roleRestricted bool
	if err := session.QueryRow(ctx, workerRoleVerificationQuery).Scan(&currentUser, &sessionUser, &loginRestricted, &roleRestricted); err != nil {
		return fmt.Errorf("verify worker database role: %w", err)
	}
	if currentUser != config.WorkerDatabaseRole || sessionUser == "" || sessionUser == currentUser || !loginRestricted || !roleRestricted {
		return errors.New("database session did not assume the dedicated worker role")
	}
	return nil
}

// OpenWorkerDatabase installs the role check on new and reused physical
// connections. A NOINHERIT login therefore receives only the privileges of
// the fixed NOLOGIN wali_worker group while a worker query is running.
func OpenWorkerDatabase(databaseURL string) (*sql.DB, error) {
	connectionConfig, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse worker database URL: %w", err)
	}
	activate := func(ctx context.Context, connection *pgx.Conn) error {
		return ActivateWorkerDatabaseRole(ctx, connection)
	}
	return stdlib.OpenDB(
		*connectionConfig,
		stdlib.OptionAfterConnect(activate),
		stdlib.OptionResetSession(activate),
	), nil
}

func NewPGMQBackend(database *sql.DB) (*PGMQBackend, error) {
	if database == nil {
		return nil, errors.New("database is required")
	}
	return &PGMQBackend{database: database}, nil
}

// NewPGMQBackendV2 opts this binary into version 2 still jobs. Older binaries
// continue using the SQL reader that filters unsupported versions before lease.
func NewPGMQBackendV2(database *sql.DB) (*PGMQBackend, error) {
	b, err := NewPGMQBackend(database)
	if err == nil {
		b.mediaV2 = true
	}
	return b, err
}

func (b *PGMQBackend) Read(ctx context.Context, queueName string, visibility time.Duration) (Message, bool, error) {
	var message Message
	var body []byte
	query := `select msg_id, message, vt from wali.worker_queue_read($1, $2)`
	if b.mediaV2 {
		query = `select msg_id, message, vt from wali.worker_queue_read_v2($1, $2)`
	}
	err := b.database.QueryRowContext(ctx,
		query,
		queueName, int(visibility.Seconds()),
	).Scan(&message.ID, &body, &message.VisibleUntil)
	if errors.Is(err, sql.ErrNoRows) {
		return Message{}, false, nil
	}
	if err != nil {
		return Message{}, false, err
	}
	message.Body = append([]byte(nil), body...)
	return message, true, nil
}

func (b *PGMQBackend) Ack(ctx context.Context, queueName string, messageID int64) error {
	var deleted bool
	if err := b.database.QueryRowContext(ctx, `select wali.worker_queue_ack($1, $2)`, queueName, messageID).Scan(&deleted); err != nil {
		return err
	}
	if !deleted {
		return errors.New("queue message was not deleted")
	}
	return nil
}

func (b *PGMQBackend) Nack(ctx context.Context, queueName string, messageID int64, delay time.Duration) error {
	var updated bool
	if err := b.database.QueryRowContext(ctx, `select wali.worker_queue_nack($1, $2, $3)`, queueName, messageID, int(delay.Seconds())).Scan(&updated); err != nil {
		return err
	}
	if !updated {
		return errors.New("queue message visibility was not updated")
	}
	return nil
}

func (b *PGMQBackend) Reject(ctx context.Context, queueName string, messageID int64, _ string) error {
	var archived bool
	if err := b.database.QueryRowContext(ctx, `select wali.worker_queue_reject($1, $2)`, queueName, messageID).Scan(&archived); err != nil {
		return err
	}
	if !archived {
		return errors.New("queue message was not archived")
	}
	return nil
}
