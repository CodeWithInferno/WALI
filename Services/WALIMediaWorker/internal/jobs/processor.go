package jobs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/claims"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
)

const maximumAccountExportBytes = 10 << 20

type Action uint8

const (
	ActionAck Action = iota + 1
	ActionNack
	ActionLeave
)

type Result struct {
	Action   Action
	SafeCode string
}

type SandboxRunner interface {
	Run(context.Context, sandbox.Spec) error
}

type CleanupQueue interface {
	Enqueue(context.Context, string, string) error
}

type ScratchCleaner interface {
	Remove(string) error
}

type osScratchCleaner struct{}

func (osScratchCleaner) Remove(value string) error { return os.RemoveAll(value) }

type SQLCleanupQueue struct {
	database *sql.DB
}

func NewSQLCleanupQueue(database *sql.DB) (*SQLCleanupQueue, error) {
	if database == nil {
		return nil, errors.New("database is required")
	}
	return &SQLCleanupQueue{database: database}, nil
}

func (q *SQLCleanupQueue) Enqueue(ctx context.Context, scratchPath, reason string) error {
	validRelative := strings.HasPrefix(scratchPath, "scratch/") && filepath.Clean(scratchPath) == scratchPath &&
		!strings.Contains(scratchPath, "..") && !strings.ContainsAny(scratchPath, "\\:\x00\r\n") && len(scratchPath) <= 160
	if !validRelative || (reason != "remove_completed" && reason != "remove_failed" && reason != "remove_rejected") {
		return errors.New("cleanup request is invalid")
	}
	var queued bool
	if err := q.database.QueryRowContext(ctx, `select wali.worker_enqueue_cleanup($1, $2)`, scratchPath, reason).Scan(&queued); err != nil {
		return err
	}
	if !queued {
		return errors.New("cleanup request was not queued")
	}
	return nil
}

type Dependencies struct {
	Attempts          AttemptStore
	Blobs             storage.BlobStore
	Sandbox           SandboxRunner
	Classifier        classifier.Classifier
	Classification    ClassificationInputStore
	Cleanup           CleanupQueue
	Cleaner           ScratchCleaner
	ScratchRoot       string
	MediaImage        string
	VerifierImage     string
	PolicyDigest      string
	StillPolicyDigest string
	HeartbeatInterval time.Duration
	LeaseDuration     time.Duration
}

type Processor struct {
	dependencies Dependencies
	claimDecoder claims.Decoder
}

type ExportProcessor struct {
	store       ExportStore
	blobs       storage.BlobStore
	scratchRoot string
}

type PromotionProcessor struct {
	store       PromotionStore
	blobs       storage.PromotionStore
	scratchRoot string
}

type CleanupProcessor struct {
	scratchRoot string
	blobs       storage.ObjectDeleter
	store       CleanupStore
}

func NewCleanupProcessor(scratchRoot string, blobs storage.ObjectDeleter, store CleanupStore) (*CleanupProcessor, error) {
	if blobs == nil || store == nil || !filepath.IsAbs(scratchRoot) || filepath.Clean(scratchRoot) != scratchRoot || scratchRoot == "/" {
		return nil, errors.New("cleanup root is invalid")
	}
	return &CleanupProcessor{scratchRoot: scratchRoot, blobs: blobs, store: store}, nil
}

func (processor *CleanupProcessor) Process(ctx context.Context, job CleanupJob, lease Lease) Result {
	if job.Kind == "storage_object" {
		begin, err := processor.store.BeginCleanup(ctx, job, lease)
		if err != nil {
			return Result{Action: ActionNack, SafeCode: "cleanup_begin_failed"}
		}
		switch begin.Disposition {
		case "completed", "stale":
			return Result{Action: ActionAck, SafeCode: "already_terminal"}
		case "active":
			return Result{Action: ActionLeave, SafeCode: "cleanup_active_elsewhere"}
		case "started":
		default:
			return Result{Action: ActionNack, SafeCode: "cleanup_begin_invalid"}
		}
		if err := processor.blobs.Delete(ctx, begin.Bucket, begin.Path); err != nil {
			return Result{Action: ActionNack, SafeCode: "cleanup_object_delete_failed"}
		}
		current, err := processor.store.CompleteCleanup(ctx, job, lease)
		if err != nil {
			return Result{Action: ActionNack, SafeCode: "cleanup_complete_failed"}
		}
		if !current {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		return Result{Action: ActionAck, SafeCode: "ok"}
	}
	relative := strings.TrimPrefix(job.ScratchPath, "scratch/")
	target := filepath.Join(processor.scratchRoot, filepath.FromSlash(relative))
	if filepath.Dir(target) != processor.scratchRoot || !strings.HasPrefix(target, processor.scratchRoot+string(filepath.Separator)) {
		return Result{Action: ActionAck, SafeCode: "cleanup_path_invalid"}
	}
	if err := os.RemoveAll(target); err != nil {
		return Result{Action: ActionNack, SafeCode: "cleanup_remove_failed"}
	}
	return Result{Action: ActionAck, SafeCode: "ok"}
}

type ImmutableDownloader interface {
	DownloadVerified(context.Context, storage.ImmutableObjectRef, string) error
}

type BackupVerificationProcessor struct {
	store       BackupVerificationStore
	blobs       ImmutableDownloader
	scratchRoot string
}

type AccountDeletionProcessor struct{ store AccountDeletionStore }

func NewAccountDeletionProcessor(store AccountDeletionStore) (*AccountDeletionProcessor, error) {
	if store == nil {
		return nil, errors.New("account deletion store is required")
	}
	return &AccountDeletionProcessor{store: store}, nil
}

func (processor *AccountDeletionProcessor) Process(ctx context.Context, job AccountDeletionJob, lease Lease) Result {
	disposition, err := processor.store.BeginAccountDeletion(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "account_deletion_begin_failed"}
	}
	switch disposition {
	case "held":
		return Result{Action: ActionNack, SafeCode: "account_deletion_held"}
	case "active":
		return Result{Action: ActionNack, SafeCode: "account_deletion_active_elsewhere"}
	case "cleanup_pending":
		return Result{Action: ActionNack, SafeCode: "account_deletion_cleanup_pending"}
	case "completed", "stale":
		return Result{Action: ActionAck, SafeCode: "already_terminal"}
	case "ready":
		current, completeErr := processor.store.CompleteAccountDeletion(ctx, job, lease)
		if completeErr != nil {
			return Result{Action: ActionNack, SafeCode: "account_deletion_complete_failed"}
		}
		if !current {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		return Result{Action: ActionAck, SafeCode: "ok"}
	default:
		_, _ = processor.store.FailAccountDeletion(ctx, job, lease, "WALI_ACCOUNT_DELETION_STATE_INVALID")
		return Result{Action: ActionAck, SafeCode: "account_deletion_state_invalid"}
	}
}

func NewBackupVerificationProcessor(store BackupVerificationStore, blobs ImmutableDownloader, scratchRoot string) (*BackupVerificationProcessor, error) {
	if store == nil || blobs == nil || !filepath.IsAbs(scratchRoot) || filepath.Clean(scratchRoot) != scratchRoot || scratchRoot == "/" {
		return nil, errors.New("backup verification dependencies are invalid")
	}
	return &BackupVerificationProcessor{store: store, blobs: blobs, scratchRoot: scratchRoot}, nil
}

func (processor *BackupVerificationProcessor) Process(ctx context.Context, job BackupVerificationJob, lease Lease) Result {
	disposition, err := processor.store.BeginBackupVerification(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "backup_begin_failed"}
	}
	switch disposition {
	case "completed", "stale":
		return Result{Action: ActionAck, SafeCode: "already_terminal"}
	case "active":
		return Result{Action: ActionLeave, SafeCode: "backup_active_elsewhere"}
	case "started":
	default:
		return Result{Action: ActionNack, SafeCode: "backup_begin_invalid"}
	}
	directory, err := os.MkdirTemp(processor.scratchRoot, "backup-verification-")
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "backup_scratch_failed"}
	}
	defer os.RemoveAll(directory)
	type mismatch struct {
		Path string `json:"path"`
		Code string `json:"code"`
	}
	mismatches := make([]mismatch, 0)
	checked, cursor := 0, ""
	for pageNumber := 0; pageNumber < 100; pageNumber++ {
		page, readErr := processor.store.ReadBackupTargets(ctx, job, lease, cursor, 100)
		if readErr != nil {
			return Result{Action: ActionNack, SafeCode: "backup_targets_failed"}
		}
		for _, target := range page.Items {
			destination := filepath.Join(directory, fmt.Sprintf("object-%05d", checked))
			downloadErr := processor.blobs.DownloadVerified(ctx, storage.ImmutableObjectRef{
				Bucket: target.Bucket, Path: target.Path, Digest: target.Digest, ByteCount: target.ByteCount,
			}, destination)
			checked++
			if errors.Is(downloadErr, storage.ErrObjectIntegrity) || errors.Is(downloadErr, storage.ErrObjectMissing) {
				mismatches = append(mismatches, mismatch{Path: target.Path, Code: "integrity_mismatch"})
			} else if downloadErr != nil {
				return Result{Action: ActionNack, SafeCode: "backup_object_read_failed"}
			}
			_ = os.Remove(destination)
		}
		if page.NextCursor == "" {
			cursor = ""
			break
		}
		cursor = page.NextCursor
	}
	if cursor != "" {
		_, _ = processor.store.FailBackupVerification(ctx, job, lease, "WALI_BACKUP_TARGET_LIMIT")
		return Result{Action: ActionAck, SafeCode: "backup_target_limit"}
	}
	report := struct {
		SchemaVersion uint16     `json:"schema_version"`
		RunID         string     `json:"run_id"`
		ScheduledFor  string     `json:"scheduled_for"`
		Checked       int        `json:"checked_count"`
		Mismatches    []mismatch `json:"mismatches"`
	}{1, job.RunID, job.ScheduledFor.UTC().Format(time.RFC3339Nano), checked, mismatches}
	encoded, err := json.Marshal(report)
	if err != nil || len(encoded) > 1<<20 {
		_, _ = processor.store.FailBackupVerification(ctx, job, lease, "WALI_BACKUP_REPORT_INVALID")
		return Result{Action: ActionAck, SafeCode: "backup_report_invalid"}
	}
	digestBytes := sha256.Sum256(encoded)
	current, err := processor.store.CompleteBackupVerification(ctx, job, lease, checked, len(mismatches), hex.EncodeToString(digestBytes[:]))
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "backup_complete_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: "ok"}
}

func NewPromotionProcessor(store PromotionStore, blobs storage.PromotionStore, scratchRoot string) (*PromotionProcessor, error) {
	if store == nil || blobs == nil || !filepath.IsAbs(scratchRoot) || filepath.Clean(scratchRoot) != scratchRoot || scratchRoot == "/" {
		return nil, errors.New("promotion processor dependencies are invalid")
	}
	return &PromotionProcessor{store: store, blobs: blobs, scratchRoot: scratchRoot}, nil
}

func (processor *PromotionProcessor) Process(ctx context.Context, job PromotionJob, lease Lease) Result {
	begin, err := processor.store.BeginPromotion(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "promotion_begin_failed"}
	}
	switch begin.Disposition {
	case "completed", "stale":
		return Result{Action: ActionAck, SafeCode: "already_terminal"}
	case "active":
		return Result{Action: ActionLeave, SafeCode: "promotion_active_elsewhere"}
	case "started":
	default:
		return Result{Action: ActionNack, SafeCode: "promotion_begin_invalid"}
	}
	directory, err := os.MkdirTemp(processor.scratchRoot, "promotion-"+job.PromotionID+"-")
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "promotion_scratch_failed"}
	}
	defer os.RemoveAll(directory)
	if err := os.Chmod(directory, 0o700); err != nil {
		return Result{Action: ActionNack, SafeCode: "promotion_scratch_failed"}
	}
	for index, artifact := range job.Artifacts {
		localPath := filepath.Join(directory, fmt.Sprintf("artifact-%d%s", index, filepath.Ext(artifact.SourcePath)))
		err := processor.blobs.DownloadVerified(ctx, storage.ImmutableObjectRef{
			Bucket: artifact.SourceBucket, Path: artifact.SourcePath,
			Digest: artifact.Digest, ByteCount: artifact.ByteCount,
		}, localPath)
		if err != nil {
			if errors.Is(err, storage.ErrObjectIntegrity) {
				return processor.fail(ctx, job, lease, "promotion_source_invalid")
			}
			return Result{Action: ActionNack, SafeCode: "promotion_source_unavailable"}
		}
		if err := processor.blobs.Publish(ctx, storage.PublishRequest{
			LocalPath: localPath, Bucket: artifact.DestinationBucket, ObjectPath: artifact.DestinationPath,
			Digest: artifact.Digest, ByteCount: artifact.ByteCount, MediaType: artifact.MediaType, CreateOnly: true,
		}); err != nil {
			if errors.Is(err, storage.ErrObjectIntegrity) {
				return processor.fail(ctx, job, lease, "promotion_destination_invalid")
			}
			return Result{Action: ActionNack, SafeCode: "promotion_upload_failed"}
		}
	}
	current, err := processor.store.CompletePromotion(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "promotion_complete_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "promotion_lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: "ok"}
}

func (processor *PromotionProcessor) fail(ctx context.Context, job PromotionJob, lease Lease, safeCode string) Result {
	current, err := processor.store.FailPromotion(ctx, job, lease, safeCode)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "promotion_failure_commit_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "promotion_lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: safeCode}
}

func NewExportProcessor(store ExportStore, blobs storage.BlobStore, scratchRoot string) (*ExportProcessor, error) {
	if store == nil || blobs == nil || !filepath.IsAbs(scratchRoot) || filepath.Clean(scratchRoot) != scratchRoot || scratchRoot == "/" {
		return nil, errors.New("export processor dependencies are invalid")
	}
	return &ExportProcessor{store: store, blobs: blobs, scratchRoot: scratchRoot}, nil
}

func (processor *ExportProcessor) Process(ctx context.Context, job ExportJob, lease Lease) Result {
	begin, err := processor.store.BeginExport(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "export_begin_failed"}
	}
	switch begin.Disposition {
	case "completed", "stale":
		return Result{Action: ActionAck, SafeCode: "already_terminal"}
	case "active":
		return Result{Action: ActionLeave, SafeCode: "export_active_elsewhere"}
	case "started":
	default:
		return Result{Action: ActionNack, SafeCode: "export_begin_invalid"}
	}
	expectedPath := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	if begin.Path != expectedPath {
		return processor.fail(ctx, job, lease, "export_path_invalid")
	}
	payload, err := processor.store.ReadExport(ctx, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "export_projection_failed"}
	}
	canonical, err := canonicalAccountExport(payload, job)
	if err != nil {
		return processor.fail(ctx, job, lease, "export_projection_invalid")
	}
	file, err := os.CreateTemp(processor.scratchRoot, "account-export-*.json")
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "export_scratch_failed"}
	}
	filePath := file.Name()
	defer os.Remove(filePath)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return Result{Action: ActionNack, SafeCode: "export_scratch_failed"}
	}
	hasher := sha256.New()
	written, writeErr := io.Copy(io.MultiWriter(file, hasher), bytes.NewReader(canonical))
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil || written != int64(len(canonical)) {
		return Result{Action: ActionNack, SafeCode: "export_scratch_failed"}
	}
	digest := hex.EncodeToString(hasher.Sum(nil))
	if err := processor.blobs.Publish(ctx, storage.PublishRequest{
		LocalPath: filePath, Bucket: "exports-private", ObjectPath: expectedPath,
		Digest: digest, ByteCount: written, MediaType: "application/json", CreateOnly: true,
	}); err != nil {
		return Result{Action: ActionNack, SafeCode: "export_upload_failed"}
	}
	current, err := processor.store.CompleteExport(ctx, job, lease, written, digest)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "export_complete_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "export_lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: "ok"}
}

func (processor *ExportProcessor) fail(ctx context.Context, job ExportJob, lease Lease, safeCode string) Result {
	current, err := processor.store.FailExport(ctx, job, lease, safeCode)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "export_failure_commit_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "export_lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: safeCode}
}

func canonicalAccountExport(payload json.RawMessage, job ExportJob) ([]byte, error) {
	if len(payload) == 0 || len(payload) > maximumAccountExportBytes {
		return nil, errors.New("export projection is out of bounds")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, errors.New("export projection is invalid JSON")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, errors.New("export projection contains trailing data")
	}
	root, ok := value.(map[string]any)
	if !ok || !exactExportRoot(root) || root["schema_version"] != json.Number("1") ||
		root["export_id"] != job.ExportID || root["user_id"] != job.UserID {
		return nil, errors.New("export projection identity is invalid")
	}
	if exportedAt, ok := root["exported_at"].(string); !ok {
		return nil, errors.New("export projection timestamp is invalid")
	} else if _, err := time.Parse(time.RFC3339, exportedAt); err != nil {
		return nil, errors.New("export projection timestamp is invalid")
	}
	for _, key := range []string{"profile", "preferences"} {
		if _, ok := root[key].(map[string]any); !ok {
			return nil, errors.New("export object projection is invalid")
		}
	}
	accountIdentity := root["account_identity"]
	if err := validateAccountIdentity(accountIdentity); err != nil {
		return nil, err
	}
	delete(root, "account_identity")
	nodes := 0
	validationError := validateExportValue(root, 0, &nodes)
	root["account_identity"] = accountIdentity
	if validationError != nil {
		return nil, validationError
	}
	for _, key := range []string{"terms_acceptances", "favorites", "saved_wallpapers", "creator_follows", "install_receipts", "engagement_events", "upload_sessions", "submissions", "rights_declarations", "reports"} {
		entries := root[key].([]any)
		sort.SliceStable(entries, func(left, right int) bool {
			leftJSON, _ := json.Marshal(entries[left])
			rightJSON, _ := json.Marshal(entries[right])
			return bytes.Compare(leftJSON, rightJSON) < 0
		})
	}
	canonical, err := json.Marshal(root)
	if err != nil || len(canonical) > maximumAccountExportBytes {
		return nil, errors.New("canonical export is out of bounds")
	}
	return canonical, nil
}

func exactExportRoot(root map[string]any) bool {
	required := []string{
		"schema_version", "export_id", "user_id", "exported_at", "account_identity", "profile", "creator_profile",
		"preferences", "terms_acceptances", "favorites", "saved_wallpapers", "creator_follows",
		"install_receipts", "engagement_events", "upload_sessions", "submissions",
		"rights_declarations", "reports",
	}
	if len(root) != len(required) {
		return false
	}
	for _, key := range required {
		if _, exists := root[key]; !exists {
			return false
		}
	}
	for _, key := range required[8:] {
		if _, ok := root[key].([]any); !ok {
			return false
		}
	}
	if root["creator_profile"] != nil {
		if _, ok := root["creator_profile"].(map[string]any); !ok {
			return false
		}
	}
	return true
}

func validateAccountIdentity(value any) error {
	identity, ok := value.(map[string]any)
	if !ok || len(identity) != 4 {
		return errors.New("account identity projection is invalid")
	}
	for _, key := range []string{"email", "providers", "created_at", "last_sign_in_at"} {
		if _, exists := identity[key]; !exists {
			return errors.New("account identity projection is invalid")
		}
	}
	if email := identity["email"]; email != nil {
		text, ok := email.(string)
		if !ok || len(text) == 0 || len(text) > 320 || strings.TrimSpace(text) != text || strings.IndexFunc(text, unicode.IsControl) >= 0 {
			return errors.New("account identity email is invalid")
		}
	}
	providers, ok := identity["providers"].([]any)
	if !ok || len(providers) > 8 {
		return errors.New("account identity providers are invalid")
	}
	previous := ""
	for index, value := range providers {
		provider, ok := value.(string)
		if !ok || !allowedIdentityProvider(provider) || (index > 0 && provider <= previous) {
			return errors.New("account identity providers are invalid")
		}
		previous = provider
	}
	for _, key := range []string{"created_at", "last_sign_in_at"} {
		if timestamp := identity[key]; timestamp != nil {
			text, ok := timestamp.(string)
			if !ok || (len(text) != 20 && len(text) != 25) {
				return errors.New("account identity timestamp is invalid")
			}
			if _, err := time.Parse(time.RFC3339, text); err != nil {
				return errors.New("account identity timestamp is invalid")
			}
		}
	}
	return nil
}

func allowedIdentityProvider(value string) bool {
	switch value {
	case "anonymous", "apple", "azure", "bitbucket", "discord", "email", "facebook", "figma", "fly", "github", "gitlab", "google", "kakao", "keycloak", "linkedin", "linkedin_oidc", "notion", "phone", "slack", "spotify", "sso", "twitch", "twitter", "workos", "zoom":
		return true
	default:
		return false
	}
}

func validateExportValue(value any, depth int, nodes *int) error {
	*nodes = *nodes + 1
	if depth > 32 || *nodes > 100_000 {
		return errors.New("export projection is too complex")
	}
	forbidden := map[string]struct{}{
		"access_token": {}, "refresh_token": {}, "service_role": {}, "password": {}, "secret": {},
		"email": {}, "phone": {}, "provider": {}, "provider_id": {}, "provider_subject": {}, "identity_id": {}, "auth_identity": {}, "auth_claims": {}, "claims": {},
		"raw_user_meta_data": {}, "raw_app_meta_data": {}, "private_note": {}, "proof_storage_path": {}, "notice_storage_path": {},
		"counter_notice_storage_path": {}, "ip_address": {}, "user_agent": {}, "device_id": {},
	}
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if len(key) > 128 {
				return errors.New("export key is too long")
			}
			normalized := strings.ToLower(key)
			_, explicitlyDenied := forbidden[normalized]
			if explicitlyDenied || normalized == "email" || strings.HasSuffix(normalized, "_email") || strings.HasSuffix(normalized, "_phone") ||
				strings.HasSuffix(normalized, "_provider_id") || strings.HasSuffix(normalized, "_identity_id") || strings.HasSuffix(normalized, "_claims") ||
				strings.Contains(normalized, "token") || strings.Contains(normalized, "password") || strings.Contains(normalized, "secret") ||
				strings.Contains(normalized, "private_note") || strings.Contains(normalized, "moderator_note") || strings.Contains(normalized, "ip_address") ||
				strings.Contains(normalized, "user_agent") || strings.Contains(normalized, "device_id") || strings.Contains(normalized, "storage_path") {
				return errors.New("export contains a forbidden field")
			}
			if err := validateExportValue(child, depth+1, nodes); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range typed {
			if err := validateExportValue(child, depth+1, nodes); err != nil {
				return err
			}
		}
	case string:
		if len(typed) > 65_536 || strings.ContainsRune(typed, '\x00') {
			return errors.New("export string is out of bounds")
		}
	case nil, bool, json.Number:
	default:
		return errors.New("export contains an unsupported JSON value")
	}
	return nil
}

func NewProcessor(dependencies Dependencies) (*Processor, error) {
	if dependencies.Attempts == nil || dependencies.Blobs == nil || dependencies.Sandbox == nil || dependencies.Classifier == nil || dependencies.Cleanup == nil ||
		(dependencies.Classifier.Enabled() && dependencies.Classification == nil) {
		return nil, errors.New("processor dependencies are incomplete")
	}
	if !filepath.IsAbs(dependencies.ScratchRoot) || filepath.Clean(dependencies.ScratchRoot) != dependencies.ScratchRoot || dependencies.ScratchRoot == "/" {
		return nil, errors.New("scratch root must be a narrow absolute clean path")
	}
	if dependencies.HeartbeatInterval <= 0 {
		return nil, errors.New("heartbeat interval must be positive")
	}
	if len(dependencies.PolicyDigest) != 64 || strings.ToLower(dependencies.PolicyDigest) != dependencies.PolicyDigest {
		return nil, errors.New("reviewed media policy digest is required")
	}
	if dependencies.StillPolicyDigest != "" && !jobDigestPattern.MatchString(dependencies.StillPolicyDigest) {
		return nil, errors.New("still policy digest must be empty or lowercase SHA-256")
	}
	if dependencies.LeaseDuration <= 0 {
		dependencies.LeaseDuration = 2 * time.Minute
	}
	if dependencies.Cleaner == nil {
		dependencies.Cleaner = osScratchCleaner{}
	}
	return &Processor{dependencies: dependencies, claimDecoder: claims.NewDecoder(1 << 20)}, nil
}

func (p *Processor) Process(parent context.Context, job ProcessSubmission, lease Lease) (result Result) {
	disposition, err := p.dependencies.Attempts.Begin(parent, job, lease)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "attempt_begin_failed"}
	}
	switch disposition {
	case BeginAlreadyCompleted, BeginStaleGeneration:
		return Result{Action: ActionAck, SafeCode: "already_terminal"}
	case BeginAlreadyActive:
		return Result{Action: ActionLeave, SafeCode: "attempt_active_elsewhere"}
	case BeginStarted:
	default:
		return Result{Action: ActionNack, SafeCode: "attempt_begin_invalid"}
	}
	policyDigest := p.dependencies.PolicyDigest
	if job.MediaKind == "still" {
		policyDigest = p.dependencies.StillPolicyDigest
	}
	if policyDigest == "" || job.PolicyDigest != policyDigest {
		return p.permanentFailure(parent, job, lease, "policy_mismatch")
	}

	ctx, cancel := context.WithDeadline(parent, job.DeadlineAt)
	defer cancel()
	executionContext := ctx
	var leaseLost <-chan struct{}
	defer func() {
		// The frozen execution budget cannot be recovered by redelivery. Record
		// that terminal fact using a fresh bounded context, only while this
		// worker still owns the current generation and an unexpired DB lease.
		if result.Action != ActionAck && executionContext.Err() == context.DeadlineExceeded &&
			parent.Err() == nil && !channelClosed(leaseLost) {
			result = p.finishExecutionTimeout(parent, job, lease)
		}
	}()
	if current := p.heartbeat(ctx, job, lease); !current {
		return Result{Action: ActionLeave, SafeCode: "lease_lost"}
	}
	var stopLeaseMonitor func()
	ctx, stopLeaseMonitor, leaseLost = p.monitorLease(ctx, job, lease)
	defer stopLeaseMonitor()

	attemptDirectory, err := os.MkdirTemp(p.dependencies.ScratchRoot, job.AttemptID+"-")
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "scratch_create_failed"}
	}
	defer p.removeOrEnqueueCleanup(attemptDirectory)
	if err := os.Chmod(attemptDirectory, 0o700); err != nil {
		return Result{Action: ActionNack, SafeCode: "scratch_permissions_failed"}
	}

	inputDirectory := filepath.Join(attemptDirectory, "input")
	mediaDirectory := filepath.Join(attemptDirectory, "media")
	verificationDirectory := filepath.Join(attemptDirectory, "verification")
	for _, directory := range []string{inputDirectory, mediaDirectory, verificationDirectory} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			return Result{Action: ActionNack, SafeCode: "scratch_layout_failed"}
		}
	}

	inputPath := filepath.Join(inputDirectory, "source.bin")
	observedInput, err := p.dependencies.Blobs.Download(ctx, job.Input, inputPath)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "download_failed"}
	}
	if observedInput.ByteCount != job.Input.ByteCount || !isRegularOpaqueFile(inputPath, job.Input.ByteCount) {
		return p.permanentFailure(ctx, job, lease, "input_integrity_failed")
	}
	if !p.heartbeat(ctx, job, lease) {
		return Result{Action: ActionLeave, SafeCode: "lease_lost"}
	}

	processSpec := p.sandboxSpec(sandbox.ModeProcess, job, observedInput.Digest, inputDirectory, mediaDirectory, p.dependencies.MediaImage)
	if err := p.dependencies.Sandbox.Run(ctx, processSpec); err != nil {
		if channelClosed(leaseLost) {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		if ctx.Err() != nil {
			return Result{Action: ActionNack, SafeCode: "processing_timeout"}
		}
		if safeCode, ok := p.declaredPermanentFailure(mediaDirectory, job, mediaPermanentSafeCodes); ok {
			return p.permanentFailure(ctx, job, lease, safeCode)
		}
		return Result{Action: ActionNack, SafeCode: "media_runtime_failed"}
	}

	mediaClaimPath := filepath.Join(mediaDirectory, "media-claim.json")
	mediaClaimFile, err := os.Open(mediaClaimPath)
	if err != nil {
		return p.permanentFailure(ctx, job, lease, "missing_media_claim")
	}
	sampleFrames := 7
	if job.MediaKind == "still" {
		sampleFrames = 1
	}
	mediaClaim, decodeErr := p.claimDecoder.DecodeMedia(mediaClaimFile, claims.Expectation{
		SchemaVersion: job.SchemaVersion, MediaKind: job.MediaKind,
		AttemptID: job.AttemptID, SubmissionID: job.SubmissionID,
		Generation: job.Generation, PolicyDigest: job.PolicyDigest,
		InputDigest: observedInput.Digest, Roles: job.ExpectedArtifactRoles, SampleFrames: sampleFrames,
	})
	closeErr := mediaClaimFile.Close()
	if decodeErr != nil || closeErr != nil {
		return p.permanentFailure(ctx, job, lease, "invalid_media_claim")
	}

	verifySpec := p.sandboxSpec(sandbox.ModeVerify, job, observedInput.Digest, mediaDirectory, verificationDirectory, p.dependencies.VerifierImage)
	if err := p.dependencies.Sandbox.Run(ctx, verifySpec); err != nil {
		if channelClosed(leaseLost) {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		if ctx.Err() != nil {
			return Result{Action: ActionNack, SafeCode: "verification_timeout"}
		}
		if safeCode, ok := p.declaredPermanentFailure(verificationDirectory, job, verifierPermanentSafeCodes); ok {
			return p.permanentFailure(ctx, job, lease, safeCode)
		}
		return Result{Action: ActionNack, SafeCode: "verifier_runtime_failed"}
	}
	verificationFile, err := os.Open(filepath.Join(verificationDirectory, "verification-claim.json"))
	if err != nil {
		return p.permanentFailure(ctx, job, lease, "missing_verification_claim")
	}
	_, decodeErr = p.claimDecoder.DecodeVerification(verificationFile, mediaClaim)
	closeErr = verificationFile.Close()
	if decodeErr != nil || closeErr != nil {
		return p.permanentFailure(ctx, job, lease, "invalid_verification_claim")
	}

	classificationRequest := classifier.Request{
		MediaKind: job.MediaKind,
		AttemptID: job.AttemptID, SubmissionID: job.SubmissionID, Generation: job.Generation,
		InputDirectory: mediaDirectory, OutputDirectory: filepath.Join(attemptDirectory, "classification"), PolicyDigest: job.PolicyDigest,
	}
	if p.dependencies.Classifier.Enabled() {
		text, readErr := p.dependencies.Classification.ReadClassificationInput(ctx, job, lease)
		if readErr != nil {
			return Result{Action: ActionNack, SafeCode: "classifier_input_failed"}
		}
		classifierInput := filepath.Join(attemptDirectory, "classifier-input")
		frames, prepareErr := prepareClassifierInput(mediaDirectory, classifierInput, mediaClaim.SampleFrames)
		if prepareErr != nil {
			return p.permanentFailure(ctx, job, lease, "classifier_frame_integrity_failed")
		}
		classificationRequest.InputDirectory = classifierInput
		classificationRequest.Title = text.Title
		classificationRequest.Description = text.Description
		classificationRequest.Frames = frames
	}
	classification, err := p.dependencies.Classifier.Classify(ctx, classificationRequest)
	if err != nil {
		if channelClosed(leaseLost) {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		return Result{Action: ActionNack, SafeCode: "classifier_runtime_failed"}
	}
	if classification.SafeCode == "" {
		return p.permanentFailure(ctx, job, lease, "invalid_classifier_claim")
	}

	for _, artifact := range mediaClaim.Artifacts {
		localPath := filepath.Join(mediaDirectory, filepath.FromSlash(artifact.RelativePath))
		if err := verifyOpaqueFile(localPath, artifact.Digest, artifact.ByteCount); err != nil {
			return p.permanentFailure(ctx, job, lease, "artifact_integrity_failed")
		}
		objectPath, err := storage.ImmutablePath(artifact.Digest, artifact.Role, artifact.RelativePath)
		if err != nil {
			return p.permanentFailure(ctx, job, lease, "artifact_path_invalid")
		}
		authorized, err := p.dependencies.Attempts.AuthorizeStagedArtifact(ctx, job, lease, completionArtifact(artifact))
		if err != nil {
			return Result{Action: ActionNack, SafeCode: "artifact_authorization_failed"}
		}
		if !authorized {
			return Result{Action: ActionLeave, SafeCode: "lease_lost"}
		}
		if err := p.dependencies.Blobs.Publish(ctx, storage.PublishRequest{
			LocalPath: localPath, Bucket: "processing-private", ObjectPath: objectPath,
			Digest: artifact.Digest, ByteCount: artifact.ByteCount,
			MediaType: artifact.MediaType, CreateOnly: true,
		}); err != nil {
			return Result{Action: ActionNack, SafeCode: "artifact_upload_failed"}
		}
	}

	if !p.heartbeat(ctx, job, lease) {
		return Result{Action: ActionLeave, SafeCode: "lease_lost"}
	}
	completion := Completion{
		SourceDigest: observedInput.Digest,
		Artifacts:    completionArtifacts(mediaClaim.Artifacts), Classification: classification,
	}
	if job.MediaKind == "still" {
		completion.SchemaVersion = 2
		completion.MediaKind = "still"
	}
	current, err := p.dependencies.Attempts.Complete(ctx, job, lease, completion)
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "completion_commit_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "stale_completion"}
	}
	return Result{Action: ActionAck, SafeCode: "ok"}
}

var mediaPermanentSafeCodes = []string{
	"image_color_profile_unsupported", "invalid_image_orientation", "animated_image_unsupported",
	"unsupported_image_format", "invalid_image_container", "private_image_metadata", "invalid_canonical_image",
	"invalid_input_type",
	"input_too_large",
	"input_digest_mismatch",
	"invalid_container",
	"unsupported_codec",
	"media_limits_exceeded",
	"canonicalization_failed",
	"output_quota_exceeded",
}

var verifierPermanentSafeCodes = []string{
	"invalid_media_claim",
	"artifact_missing",
	"artifact_mismatch",
	"unsafe_track_layout",
	"verification_failed",
}

func (p *Processor) declaredPermanentFailure(outputDirectory string, job ProcessSubmission, allowed []string) (string, bool) {
	file, err := os.Open(filepath.Join(outputDirectory, "failure.json"))
	if err != nil {
		return "", false
	}
	defer file.Close()
	claim, err := p.claimDecoder.DecodeFailure(file, claims.FailureExpectation{
		AttemptID: job.AttemptID, SubmissionID: job.SubmissionID,
		Generation: job.Generation, SafeCodes: allowed,
	})
	if err != nil {
		return "", false
	}
	return claim.SafeCode, true
}

func (p *Processor) heartbeat(ctx context.Context, job ProcessSubmission, lease Lease) bool {
	current, err := p.dependencies.Attempts.Heartbeat(ctx, job, lease, time.Now().Add(p.dependencies.LeaseDuration))
	return err == nil && current
}

func (p *Processor) monitorLease(parent context.Context, job ProcessSubmission, lease Lease) (context.Context, func(), <-chan struct{}) {
	ctx, cancel := context.WithCancel(parent)
	stop := make(chan struct{})
	done := make(chan struct{})
	lost := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(p.dependencies.HeartbeatInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-stop:
				return
			case <-ticker.C:
				if !p.heartbeat(ctx, job, lease) {
					if ctx.Err() != nil {
						return
					}
					close(lost)
					cancel()
					return
				}
			}
		}
	}()
	return ctx, func() {
		close(stop)
		cancel()
		<-done
	}, lost
}

func channelClosed(channel <-chan struct{}) bool {
	select {
	case <-channel:
		return true
	default:
		return false
	}
}

func (p *Processor) finishExecutionTimeout(parent context.Context, job ProcessSubmission, lease Lease) Result {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	current, err := p.dependencies.Attempts.Fail(ctx, job, lease, Failure{SafeCode: "processing_timeout"})
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "timeout_commit_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "lease_lost"}
	}
	return Result{Action: ActionAck, SafeCode: "processing_timeout"}
}

func (p *Processor) permanentFailure(ctx context.Context, job ProcessSubmission, lease Lease, safeCode string) Result {
	current, err := p.dependencies.Attempts.Fail(ctx, job, lease, Failure{SafeCode: safeCode})
	if err != nil {
		return Result{Action: ActionNack, SafeCode: "failure_commit_failed"}
	}
	if !current {
		return Result{Action: ActionLeave, SafeCode: "stale_failure"}
	}
	return Result{Action: ActionAck, SafeCode: safeCode}
}

func (p *Processor) sandboxSpec(mode sandbox.Mode, job ProcessSubmission, inputDigest, inputDirectory, outputDirectory, image string) sandbox.Spec {
	cpus := "2"
	if mode == sandbox.ModeProcess && job.MediaKind != "still" {
		cpus = "4"
	}
	return sandbox.Spec{
		MediaKind: job.MediaKind,
		Mode:      mode, AttemptID: job.AttemptID, SubmissionID: job.SubmissionID,
		Generation: job.Generation, InputDigest: inputDigest, Image: image,
		InputDirectory: inputDirectory, OutputDirectory: outputDirectory,
		PolicyDigest: job.PolicyDigest,
		Limits:       sandbox.Limits{CPUs: cpus, Memory: "4g", PIDs: 64, TmpfsBytes: 1 << 30},
	}
}

func completionArtifacts(artifactClaims []claims.ArtifactClaim) []CompletionArtifact {
	artifacts := make([]CompletionArtifact, 0, len(artifactClaims))
	for _, claim := range artifactClaims {
		artifacts = append(artifacts, completionArtifact(claim))
	}
	return artifacts
}

func completionArtifact(claim claims.ArtifactClaim) CompletionArtifact {
	return CompletionArtifact{Role: claim.Role, Digest: claim.Digest, ByteCount: claim.ByteCount,
		MediaType: claim.MediaType, Width: claim.Width, Height: claim.Height, DurationMS: claim.DurationMS,
		FrameRateNumerator: claim.FrameRateNumerator, FrameRateDenominator: claim.FrameRateDenominator,
		Codec: claim.Codec, PixelFormat: claim.PixelFormat, ColorSpace: claim.ColorSpace, HasAudio: claim.HasAudio}
}

func prepareClassifierInput(mediaDirectory, destination string, frameClaims []claims.FrameClaim) ([]classifier.Frame, error) {
	if err := os.Mkdir(destination, 0o700); err != nil {
		return nil, err
	}
	framesDirectory := filepath.Join(destination, "frames")
	if err := os.Mkdir(framesDirectory, 0o700); err != nil {
		return nil, err
	}
	frames := make([]classifier.Frame, 0, len(frameClaims))
	for _, frame := range frameClaims {
		source := filepath.Join(mediaDirectory, filepath.FromSlash(frame.RelativePath))
		if err := verifyOpaqueFile(source, frame.Digest, frame.ByteCount); err != nil {
			return nil, err
		}
		destinationPath := filepath.Join(framesDirectory, fmt.Sprintf("frame-%03d.jpg", frame.Ordinal))
		input, err := os.Open(source)
		if err != nil {
			return nil, err
		}
		output, err := os.OpenFile(destinationPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			_ = input.Close()
			return nil, err
		}
		written, copyErr := io.Copy(output, io.LimitReader(input, frame.ByteCount+1))
		inputErr, outputErr := input.Close(), output.Close()
		if copyErr != nil || inputErr != nil || outputErr != nil || written != frame.ByteCount {
			return nil, errors.New("copy verified classifier frame")
		}
		frames = append(frames, classifier.Frame{
			Ordinal: frame.Ordinal, Digest: frame.Digest, ByteCount: frame.ByteCount,
			Width: frame.Width, Height: frame.Height,
		})
	}
	return frames, nil
}

func isRegularOpaqueFile(filePath string, expectedBytes int64) bool {
	info, err := os.Lstat(filePath)
	return err == nil && info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 && info.Size() == expectedBytes
}

func (p *Processor) removeOrEnqueueCleanup(attemptDirectory string) {
	if err := p.dependencies.Cleaner.Remove(attemptDirectory); err != nil {
		_ = p.dependencies.Cleanup.Enqueue(context.Background(), "scratch/"+filepath.Base(attemptDirectory), "remove_failed")
	}
}

func verifyOpaqueFile(filePath, expectedDigest string, expectedBytes int64) error {
	info, err := os.Lstat(filePath)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() != expectedBytes {
		return errors.New("file is not a regular file of the expected size")
	}
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(file, expectedBytes+1))
	if err != nil {
		return err
	}
	if written != expectedBytes {
		return errors.New("file length changed while hashing")
	}
	if actual := hex.EncodeToString(hasher.Sum(nil)); !strings.EqualFold(actual, expectedDigest) || actual != expectedDigest {
		return fmt.Errorf("file digest mismatch: got %s", actual)
	}
	return nil
}
