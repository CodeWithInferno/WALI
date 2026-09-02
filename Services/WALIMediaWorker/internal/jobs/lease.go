package jobs

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
)

const ProcessSubmissionSchemaVersion = 1

var (
	jobIDPattern          = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	jobDigestPattern      = regexp.MustCompile(`^[a-f0-9]{64}$`)
	uploadPathPattern     = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/source$`)
	immutablePathPattern  = regexp.MustCompile(`^sha256/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}/[a-z0-9_-]+\.(jpg|jpeg|png|mp4)$`)
	exportPathPattern     = regexp.MustCompile(`^exports/[0-9a-f-]{36}/[0-9a-f-]{36}/account\.json$`)
	moderationPathPattern = regexp.MustCompile(`^(rights/[0-9a-f-]{36}/[0-9a-f-]{36}/proof\.[a-z0-9]{2,8}|copyright/[0-9a-f-]{36}/(notice|counter-notice)\.[a-z0-9]{2,8})$`)
	extensionKeyPattern   = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
)

type ProcessSubmission struct {
	SchemaVersion         uint16                     `json:"schema_version"`
	AttemptID             string                     `json:"attempt_id"`
	SubmissionID          string                     `json:"submission_id"`
	Generation            uint32                     `json:"generation"`
	Input                 storage.RawObjectRef       `json:"input"`
	PolicyDigest          string                     `json:"policy_digest"`
	ExpectedArtifactRoles []string                   `json:"expected_artifact_roles"`
	DeadlineAt            time.Time                  `json:"deadline_at"`
	Extensions            map[string]json.RawMessage `json:"extensions,omitempty"`
}

type Lease struct {
	MessageID int64
	Owner     string
	ExpiresAt time.Time
}

type BeginDisposition uint8

const (
	BeginStarted BeginDisposition = iota + 1
	BeginAlreadyActive
	BeginAlreadyCompleted
	BeginStaleGeneration
)

type Completion struct {
	SourceDigest   string               `json:"source_digest"`
	Artifacts      []CompletionArtifact `json:"artifacts"`
	Classification classifier.Result    `json:"classification"`
}

type CompletionArtifact struct {
	Role                 string `json:"role"`
	Digest               string `json:"digest"`
	ByteCount            int64  `json:"byte_count"`
	MediaType            string `json:"media_type"`
	Width                int    `json:"width"`
	Height               int    `json:"height"`
	DurationMS           int64  `json:"duration_ms"`
	FrameRateNumerator   int    `json:"frame_rate_numerator"`
	FrameRateDenominator int    `json:"frame_rate_denominator"`
	Codec                string `json:"codec"`
	PixelFormat          string `json:"pixel_format"`
	ColorSpace           string `json:"color_space"`
	HasAudio             bool   `json:"has_audio"`
}

type Failure struct {
	SafeCode string
}

type ExportJob struct {
	SchemaVersion uint16 `json:"schema_version"`
	ExportID      string `json:"export_id"`
	UserID        string `json:"user_id"`
}

type CleanupJob struct {
	SchemaVersion uint16 `json:"schema_version"`
	Kind          string `json:"kind"`
	ScratchPath   string `json:"scratch_path,omitempty"`
	Reason        string `json:"reason,omitempty"`
	CleanupID     string `json:"cleanup_id,omitempty"`
}

type CleanupBegin struct {
	Disposition string `json:"disposition"`
	Bucket      string `json:"bucket,omitempty"`
	Path        string `json:"path,omitempty"`
}

type CleanupStore interface {
	BeginCleanup(context.Context, CleanupJob, Lease) (CleanupBegin, error)
	CompleteCleanup(context.Context, CleanupJob, Lease) (bool, error)
	FailCleanup(context.Context, CleanupJob, Lease, string) (bool, error)
}

type BackupVerificationJob struct {
	SchemaVersion uint16    `json:"schema_version"`
	RunID         string    `json:"run_id"`
	ScheduledFor  time.Time `json:"scheduled_for"`
}

type BackupTarget struct {
	Bucket    string `json:"bucket"`
	Path      string `json:"path"`
	Digest    string `json:"digest"`
	ByteCount int64  `json:"byte_count"`
}

type BackupTargetPage struct {
	Items      []BackupTarget `json:"items"`
	NextCursor string         `json:"next_cursor"`
}

type BackupVerificationStore interface {
	BeginBackupVerification(context.Context, BackupVerificationJob, Lease) (string, error)
	ReadBackupTargets(context.Context, BackupVerificationJob, Lease, string, int) (BackupTargetPage, error)
	CompleteBackupVerification(context.Context, BackupVerificationJob, Lease, int, int, string) (bool, error)
	FailBackupVerification(context.Context, BackupVerificationJob, Lease, string) (bool, error)
}

type AccountDeletionJob struct {
	SchemaVersion uint16 `json:"schema_version"`
	DeletionID    string `json:"deletion_id"`
	UserID        string `json:"user_id"`
}

type AccountDeletionStore interface {
	BeginAccountDeletion(context.Context, AccountDeletionJob, Lease) (string, error)
	CompleteAccountDeletion(context.Context, AccountDeletionJob, Lease) (bool, error)
	FailAccountDeletion(context.Context, AccountDeletionJob, Lease, string) (bool, error)
}

type ExportBegin struct {
	Disposition string `json:"disposition"`
	Path        string `json:"path"`
}

type ExportStore interface {
	BeginExport(context.Context, ExportJob, Lease) (ExportBegin, error)
	ReadExport(context.Context, ExportJob, Lease) (json.RawMessage, error)
	CompleteExport(context.Context, ExportJob, Lease, int64, string) (bool, error)
	FailExport(context.Context, ExportJob, Lease, string) (bool, error)
}

type PromotionArtifact struct {
	Role              string `json:"role"`
	Digest            string `json:"digest"`
	ByteCount         int64  `json:"byte_count"`
	MediaType         string `json:"media_type"`
	SourceBucket      string `json:"source_bucket"`
	SourcePath        string `json:"source_path"`
	DestinationBucket string `json:"destination_bucket"`
	DestinationPath   string `json:"destination_path"`
}

type PromotionJob struct {
	SchemaVersion uint16              `json:"schema_version"`
	PromotionID   string              `json:"promotion_id"`
	ReleaseID     string              `json:"release_id"`
	Artifacts     []PromotionArtifact `json:"artifacts"`
}

type PromotionBegin struct {
	Disposition string              `json:"disposition"`
	PromotionID string              `json:"promotion_id,omitempty"`
	ReleaseID   string              `json:"release_id,omitempty"`
	Artifacts   []PromotionArtifact `json:"artifacts,omitempty"`
}

type PromotionStore interface {
	BeginPromotion(context.Context, PromotionJob, Lease) (PromotionBegin, error)
	CompletePromotion(context.Context, PromotionJob, Lease) (bool, error)
	FailPromotion(context.Context, PromotionJob, Lease, string) (bool, error)
}

type AttemptStore interface {
	Begin(context.Context, ProcessSubmission, Lease) (BeginDisposition, error)
	Heartbeat(context.Context, ProcessSubmission, Lease, time.Time) (bool, error)
	AuthorizeStagedArtifact(context.Context, ProcessSubmission, Lease, CompletionArtifact) (bool, error)
	Complete(context.Context, ProcessSubmission, Lease, Completion) (bool, error)
	Fail(context.Context, ProcessSubmission, Lease, Failure) (bool, error)
}

type ClassificationInput struct {
	Title       string `json:"title"`
	Description string `json:"description"`
}

type ClassificationInputStore interface {
	ReadClassificationInput(context.Context, ProcessSubmission, Lease) (ClassificationInput, error)
}

func DecodeProcessSubmission(reader io.Reader, maxBytes int64) (ProcessSubmission, error) {
	if maxBytes <= 0 || maxBytes > 1<<20 {
		return ProcessSubmission{}, errors.New("job JSON size limit must be between 1 and 1048576 bytes")
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxBytes+1))
	if err != nil {
		return ProcessSubmission{}, fmt.Errorf("read job: %w", err)
	}
	if int64(len(data)) > maxBytes {
		return ProcessSubmission{}, errors.New("job JSON is too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var job ProcessSubmission
	if err := decoder.Decode(&job); err != nil {
		return ProcessSubmission{}, fmt.Errorf("decode job: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return ProcessSubmission{}, errors.New("job JSON contains trailing data")
	}
	if err := validateJob(job); err != nil {
		return ProcessSubmission{}, err
	}
	return job, nil
}

func DecodeExportJob(reader io.Reader, maxBytes int64) (ExportJob, error) {
	if maxBytes <= 0 || maxBytes > 16<<10 {
		return ExportJob{}, errors.New("export job size limit must be between 1 and 16384 bytes")
	}
	decoder := json.NewDecoder(io.LimitReader(reader, maxBytes+1))
	decoder.DisallowUnknownFields()
	var job ExportJob
	if err := decoder.Decode(&job); err != nil {
		return ExportJob{}, fmt.Errorf("decode export job: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return ExportJob{}, errors.New("export job contains trailing or oversized data")
	}
	if job.SchemaVersion != 1 || !jobIDPattern.MatchString(job.ExportID) || !jobIDPattern.MatchString(job.UserID) {
		return ExportJob{}, errors.New("export job is invalid")
	}
	return job, nil
}

func DecodeCleanupJob(reader io.Reader, maxBytes int64) (CleanupJob, error) {
	if maxBytes <= 0 || maxBytes > 4<<10 {
		return CleanupJob{}, errors.New("cleanup job size limit is invalid")
	}
	decoder := json.NewDecoder(io.LimitReader(reader, maxBytes+1))
	decoder.DisallowUnknownFields()
	var job CleanupJob
	if err := decoder.Decode(&job); err != nil {
		return CleanupJob{}, errors.New("cleanup job is invalid")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return CleanupJob{}, errors.New("cleanup job has trailing or oversized data")
	}
	validPath := strings.HasPrefix(job.ScratchPath, "scratch/") && path.Clean(job.ScratchPath) == job.ScratchPath &&
		!strings.Contains(job.ScratchPath, "..") && !strings.ContainsAny(job.ScratchPath, "\\:\x00\r\n") && len(job.ScratchPath) <= 160
	validReason := job.Reason == "remove_completed" || job.Reason == "remove_failed" || job.Reason == "remove_rejected"
	validScratch := job.Kind == "scratch" && validPath && validReason && job.CleanupID == ""
	validObject := job.Kind == "storage_object" && job.ScratchPath == "" && job.Reason == "" && jobIDPattern.MatchString(job.CleanupID)
	if job.SchemaVersion != 1 || (!validScratch && !validObject) {
		return CleanupJob{}, errors.New("cleanup job contract is invalid")
	}
	return job, nil
}

func DecodeBackupVerificationJob(reader io.Reader, maxBytes int64) (BackupVerificationJob, error) {
	if maxBytes <= 0 || maxBytes > 4<<10 {
		return BackupVerificationJob{}, errors.New("backup verification job size limit is invalid")
	}
	decoder := json.NewDecoder(io.LimitReader(reader, maxBytes+1))
	decoder.DisallowUnknownFields()
	var job BackupVerificationJob
	if err := decoder.Decode(&job); err != nil {
		return BackupVerificationJob{}, errors.New("backup verification job is invalid")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return BackupVerificationJob{}, errors.New("backup verification job has trailing or oversized data")
	}
	if job.SchemaVersion != 1 || !jobIDPattern.MatchString(job.RunID) || job.ScheduledFor.IsZero() {
		return BackupVerificationJob{}, errors.New("backup verification job contract is invalid")
	}
	return job, nil
}

func DecodeAccountDeletionJob(reader io.Reader, maxBytes int64) (AccountDeletionJob, error) {
	if maxBytes <= 0 || maxBytes > 4<<10 {
		return AccountDeletionJob{}, errors.New("account deletion job size limit is invalid")
	}
	decoder := json.NewDecoder(io.LimitReader(reader, maxBytes+1))
	decoder.DisallowUnknownFields()
	var job AccountDeletionJob
	if err := decoder.Decode(&job); err != nil {
		return AccountDeletionJob{}, errors.New("account deletion job is invalid")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return AccountDeletionJob{}, errors.New("account deletion job has trailing or oversized data")
	}
	if job.SchemaVersion != 1 || !jobIDPattern.MatchString(job.DeletionID) || !jobIDPattern.MatchString(job.UserID) {
		return AccountDeletionJob{}, errors.New("account deletion job contract is invalid")
	}
	return job, nil
}

func DecodePromotionJob(reader io.Reader, maxBytes int64) (PromotionJob, error) {
	if maxBytes <= 0 || maxBytes > 64<<10 {
		return PromotionJob{}, errors.New("promotion job size limit must be between 1 and 65536 bytes")
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxBytes+1))
	if err != nil || int64(len(data)) > maxBytes {
		return PromotionJob{}, errors.New("promotion job is unreadable or oversized")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var job PromotionJob
	if err := decoder.Decode(&job); err != nil {
		return PromotionJob{}, fmt.Errorf("decode promotion job: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return PromotionJob{}, errors.New("promotion job contains trailing data")
	}
	if err := validatePromotionJob(job); err != nil {
		return PromotionJob{}, err
	}
	return job, nil
}

func validatePromotionJob(job PromotionJob) error {
	if job.SchemaVersion != 1 || !jobIDPattern.MatchString(job.PromotionID) || !jobIDPattern.MatchString(job.ReleaseID) {
		return errors.New("promotion identity is invalid")
	}
	if len(job.Artifacts) != 4 {
		return errors.New("promotion must contain the exact four canonical artifacts")
	}
	seen := map[string]bool{}
	for _, artifact := range job.Artifacts {
		if seen[artifact.Role] || !containsRole([]string{"thumbnail", "poster", "preview", "video_default"}, artifact.Role) {
			return errors.New("promotion artifact role is invalid")
		}
		seen[artifact.Role] = true
		if !jobDigestPattern.MatchString(artifact.Digest) || artifact.ByteCount <= 0 || artifact.ByteCount > 2<<30 {
			return errors.New("promotion artifact integrity fields are invalid")
		}
		if artifact.SourceBucket != "processing-private" || artifact.DestinationBucket != "catalog-public" ||
			artifact.SourcePath != artifact.DestinationPath || path.Clean(artifact.SourcePath) != artifact.SourcePath {
			return errors.New("promotion storage boundary is invalid")
		}
		expected, err := storage.ImmutablePath(artifact.Digest, artifact.Role, artifact.SourcePath)
		if err != nil || expected != artifact.SourcePath {
			return errors.New("promotion immutable path is invalid")
		}
		extension := path.Ext(artifact.SourcePath)
		if !validArtifactMediaType(extension, artifact.MediaType) {
			return errors.New("promotion artifact media type is invalid")
		}
	}
	return validateRoles(func() []string {
		roles := make([]string, 0, len(job.Artifacts))
		for _, artifact := range job.Artifacts {
			roles = append(roles, artifact.Role)
		}
		return roles
	}())
}

func containsRole(roles []string, role string) bool {
	for _, candidate := range roles {
		if candidate == role {
			return true
		}
	}
	return false
}

func validArtifactMediaType(extension, mediaType string) bool {
	switch extension {
	case ".jpg":
		return mediaType == "image/jpeg"
	case ".png":
		return mediaType == "image/png"
	case ".mp4":
		return mediaType == "video/mp4"
	default:
		return false
	}
}

func validateJob(job ProcessSubmission) error {
	if job.SchemaVersion != ProcessSubmissionSchemaVersion {
		return fmt.Errorf("unsupported schema_version %d", job.SchemaVersion)
	}
	if !jobIDPattern.MatchString(job.AttemptID) || !jobIDPattern.MatchString(job.SubmissionID) {
		return errors.New("attempt_id and submission_id must be bounded identifiers")
	}
	if job.Generation == 0 {
		return errors.New("generation must be positive")
	}
	if job.Input.Bucket != "uploads-private" || !uploadPathPattern.MatchString(job.Input.Path) ||
		path.Clean(job.Input.Path) != job.Input.Path {
		return errors.New("input must use a service-issued uploads-private path")
	}
	if job.Input.ByteCount <= 0 || job.Input.ByteCount > 1<<30 {
		return errors.New("input byte_count is out of bounds")
	}
	if job.Input.StorageVersion == "" || len(job.Input.StorageVersion) > 128 ||
		strings.ContainsAny(job.Input.StorageVersion, "/\\:\x00\r\n\t ") {
		return errors.New("input storage_version is invalid")
	}
	if !jobDigestPattern.MatchString(job.PolicyDigest) {
		return errors.New("policy_digest must be lowercase SHA-256")
	}
	if job.DeadlineAt.IsZero() {
		return errors.New("deadline_at is required")
	}
	if err := validateRoles(job.ExpectedArtifactRoles); err != nil {
		return err
	}
	if len(job.Extensions) > 16 {
		return errors.New("extensions contains more than 16 entries")
	}
	extensionBytes := 0
	for key, value := range job.Extensions {
		if !extensionKeyPattern.MatchString(key) {
			return fmt.Errorf("extensions key %q is invalid", key)
		}
		if len(value) == 0 || !json.Valid(value) {
			return fmt.Errorf("extensions value %q is invalid JSON", key)
		}
		extensionBytes += len(key) + len(value)
	}
	if extensionBytes > 4096 {
		return errors.New("extensions exceeds 4096 bytes")
	}
	return nil
}

func validateRoles(roles []string) error {
	if len(roles) != 4 {
		return errors.New("expected_artifact_roles must contain exactly the four roles in the active media policy")
	}
	required := []string{"thumbnail", "poster", "preview", "video_default"}
	seen := make(map[string]bool, len(roles))
	for _, role := range roles {
		if seen[role] {
			return errors.New("expected_artifact_roles contains an unknown or duplicate role")
		}
		seen[role] = true
	}
	for _, role := range required {
		if !seen[role] {
			return fmt.Errorf("expected_artifact_roles is missing %s", role)
		}
	}
	return nil
}

type SQLAttemptStore struct {
	database *sql.DB
}

func NewSQLAttemptStore(database *sql.DB) (*SQLAttemptStore, error) {
	if database == nil {
		return nil, errors.New("database is required")
	}
	return &SQLAttemptStore{database: database}, nil
}

func (s *SQLAttemptStore) Begin(ctx context.Context, job ProcessSubmission, lease Lease) (BeginDisposition, error) {
	var disposition string
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_begin_attempt($1, $2, $3, $4, $5)`,
		job.AttemptID, job.SubmissionID, job.Generation, lease.Owner, lease.ExpiresAt,
	).Scan(&disposition)
	if err != nil {
		return 0, err
	}
	switch disposition {
	case "started":
		return BeginStarted, nil
	case "active":
		return BeginAlreadyActive, nil
	case "completed":
		return BeginAlreadyCompleted, nil
	case "stale":
		return BeginStaleGeneration, nil
	default:
		return 0, fmt.Errorf("database returned unknown begin disposition %q", disposition)
	}
}

func (s *SQLAttemptStore) Heartbeat(ctx context.Context, job ProcessSubmission, lease Lease, expiresAt time.Time) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_heartbeat_attempt($1, $2, $3, $4)`,
		job.AttemptID, job.Generation, lease.Owner, expiresAt,
	).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) AuthorizeStagedArtifact(ctx context.Context, job ProcessSubmission, lease Lease, artifact CompletionArtifact) (bool, error) {
	payload, err := json.Marshal(artifact)
	if err != nil {
		return false, err
	}
	var authorized bool
	err = s.database.QueryRowContext(ctx, `select wali.worker_authorize_staged_artifact($1, $2, $3, $4::jsonb)`,
		job.AttemptID, job.Generation, lease.Owner, payload).Scan(&authorized)
	return authorized, err
}

func (s *SQLAttemptStore) Complete(ctx context.Context, job ProcessSubmission, lease Lease, completion Completion) (bool, error) {
	summary, err := json.Marshal(completion)
	if err != nil {
		return false, err
	}
	if len(summary) > 128<<10 {
		return false, errors.New("completion exceeds the bounded database contract")
	}
	var current bool
	err = s.database.QueryRowContext(ctx,
		`select wali.worker_complete_attempt($1, $2, $3, $4::jsonb)`,
		job.AttemptID, job.Generation, lease.Owner, summary,
	).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) Fail(ctx context.Context, job ProcessSubmission, lease Lease, failure Failure) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_fail_attempt($1, $2, $3, $4)`,
		job.AttemptID, job.Generation, lease.Owner, failure.SafeCode,
	).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) ReadClassificationInput(ctx context.Context, job ProcessSubmission, lease Lease) (ClassificationInput, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx, `select wali.worker_read_classification_input($1, $2, $3)`,
		job.AttemptID, job.Generation, lease.Owner).Scan(&payload)
	if err != nil {
		return ClassificationInput{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var input ClassificationInput
	if err := decoder.Decode(&input); err != nil {
		return ClassificationInput{}, errors.New("database returned invalid classification input")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return ClassificationInput{}, errors.New("database returned trailing classification input")
	}
	if len([]rune(input.Title)) < 1 || len([]rune(input.Title)) > 120 || len([]rune(input.Description)) > 2000 ||
		strings.ContainsRune(input.Title, '\x00') || strings.ContainsRune(input.Description, '\x00') {
		return ClassificationInput{}, errors.New("database returned out-of-bounds classification input")
	}
	return input, nil
}

func (s *SQLAttemptStore) BeginExport(ctx context.Context, job ExportJob, lease Lease) (ExportBegin, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_begin_export($1, $2, $3, $4)`,
		job.ExportID, job.UserID, lease.Owner, lease.ExpiresAt,
	).Scan(&payload)
	if err != nil {
		return ExportBegin{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var begin ExportBegin
	if err := decoder.Decode(&begin); err != nil {
		return ExportBegin{}, errors.New("database returned an invalid export lease")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return ExportBegin{}, errors.New("database returned trailing export lease data")
	}
	expectedPath := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	if begin.Path != expectedPath {
		return ExportBegin{}, errors.New("database returned an unexpected export path")
	}
	switch begin.Disposition {
	case "started", "active", "completed", "stale":
		return begin, nil
	default:
		return ExportBegin{}, errors.New("database returned an unknown export disposition")
	}
}

func (s *SQLAttemptStore) ReadExport(ctx context.Context, job ExportJob, lease Lease) (json.RawMessage, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_read_account_export($1, $2, $3)`,
		job.ExportID, job.UserID, lease.Owner,
	).Scan(&payload)
	if err != nil {
		return nil, err
	}
	return append(json.RawMessage(nil), payload...), nil
}

func (s *SQLAttemptStore) CompleteExport(ctx context.Context, job ExportJob, lease Lease, byteCount int64, digest string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_complete_export($1, $2, $3, $4, $5)`,
		job.ExportID, job.UserID, lease.Owner, byteCount, digest,
	).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) FailExport(ctx context.Context, job ExportJob, lease Lease, safeCode string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_fail_export($1, $2, $3, $4)`,
		job.ExportID, job.UserID, lease.Owner, safeCode,
	).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) BeginPromotion(ctx context.Context, job PromotionJob, lease Lease) (PromotionBegin, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx,
		`select wali.worker_begin_promotion($1, $2, $3)`, job.PromotionID, lease.Owner, lease.ExpiresAt,
	).Scan(&payload)
	if err != nil {
		return PromotionBegin{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var begin PromotionBegin
	if err := decoder.Decode(&begin); err != nil {
		return PromotionBegin{}, errors.New("database returned an invalid promotion lease")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return PromotionBegin{}, errors.New("database returned trailing promotion lease data")
	}
	switch begin.Disposition {
	case "started":
		if begin.PromotionID != job.PromotionID || begin.ReleaseID != job.ReleaseID || !promotionArtifactsEqual(begin.Artifacts, job.Artifacts) {
			return PromotionBegin{}, errors.New("database promotion snapshot differs from queued intent")
		}
	case "active", "completed", "stale":
		if begin.PromotionID != "" || begin.ReleaseID != "" || len(begin.Artifacts) != 0 {
			return PromotionBegin{}, errors.New("terminal promotion lease included unexpected data")
		}
	default:
		return PromotionBegin{}, errors.New("database returned an unknown promotion disposition")
	}
	return begin, nil
}

func (s *SQLAttemptStore) CompletePromotion(ctx context.Context, job PromotionJob, lease Lease) (bool, error) {
	artifacts := make([]struct {
		Role      string `json:"role"`
		Digest    string `json:"digest"`
		ByteCount int64  `json:"byte_count"`
	}, 0, len(job.Artifacts))
	for _, artifact := range job.Artifacts {
		artifacts = append(artifacts, struct {
			Role      string `json:"role"`
			Digest    string `json:"digest"`
			ByteCount int64  `json:"byte_count"`
		}{artifact.Role, artifact.Digest, artifact.ByteCount})
	}
	sort.Slice(artifacts, func(i, j int) bool { return artifacts[i].Role < artifacts[j].Role })
	payload, err := json.Marshal(artifacts)
	if err != nil {
		return false, err
	}
	var current bool
	err = s.database.QueryRowContext(ctx, `select wali.worker_complete_promotion($1, $2, $3::jsonb)`,
		job.PromotionID, lease.Owner, payload).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) FailPromotion(ctx context.Context, job PromotionJob, lease Lease, safeCode string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_fail_promotion($1, $2, $3)`,
		job.PromotionID, lease.Owner, safeCode).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) BeginCleanup(ctx context.Context, job CleanupJob, lease Lease) (CleanupBegin, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx, `select wali.worker_begin_cleanup($1, $2, $3)`,
		job.CleanupID, lease.Owner, lease.ExpiresAt).Scan(&payload)
	if err != nil {
		return CleanupBegin{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var begin CleanupBegin
	if err := decoder.Decode(&begin); err != nil {
		return CleanupBegin{}, errors.New("database returned an invalid cleanup lease")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return CleanupBegin{}, errors.New("database returned trailing cleanup lease data")
	}
	switch begin.Disposition {
	case "started":
		if !validCleanupTarget(begin.Bucket, begin.Path) {
			return CleanupBegin{}, errors.New("database returned an invalid cleanup target")
		}
	case "active", "completed", "stale":
		if begin.Bucket != "" || begin.Path != "" {
			return CleanupBegin{}, errors.New("terminal cleanup lease included a target")
		}
	default:
		return CleanupBegin{}, errors.New("database returned an unknown cleanup disposition")
	}
	return begin, nil
}

func (s *SQLAttemptStore) CompleteCleanup(ctx context.Context, job CleanupJob, lease Lease) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_complete_cleanup($1, $2)`, job.CleanupID, lease.Owner).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) FailCleanup(ctx context.Context, job CleanupJob, lease Lease, safeCode string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_fail_cleanup($1, $2, $3)`, job.CleanupID, lease.Owner, safeCode).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) BeginBackupVerification(ctx context.Context, job BackupVerificationJob, lease Lease) (string, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx, `select wali.worker_begin_backup_verification($1, $2, $3)`,
		job.RunID, lease.Owner, lease.ExpiresAt).Scan(&payload)
	if err != nil {
		return "", err
	}
	var begin struct {
		Disposition string `json:"disposition"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&begin); err != nil || begin.Disposition == "" {
		return "", errors.New("database returned an invalid backup verification lease")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return "", errors.New("database returned trailing backup verification lease data")
	}
	switch begin.Disposition {
	case "started", "active", "completed", "stale":
		return begin.Disposition, nil
	default:
		return "", errors.New("database returned an unknown backup verification disposition")
	}
}

func (s *SQLAttemptStore) ReadBackupTargets(ctx context.Context, job BackupVerificationJob, lease Lease, afterPath string, limit int) (BackupTargetPage, error) {
	if limit < 1 || limit > 100 || len(afterPath) > 768 || strings.ContainsRune(afterPath, '\x00') {
		return BackupTargetPage{}, errors.New("backup target cursor or limit is invalid")
	}
	var payload []byte
	err := s.database.QueryRowContext(ctx, `select wali.worker_read_backup_verification_targets($1, $2, $3, $4)`,
		job.RunID, lease.Owner, afterPath, limit).Scan(&payload)
	if err != nil {
		return BackupTargetPage{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var page BackupTargetPage
	if err := decoder.Decode(&page); err != nil {
		return BackupTargetPage{}, errors.New("database returned invalid backup targets")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF || len(page.Items) > limit || len(page.NextCursor) > 768 {
		return BackupTargetPage{}, errors.New("database returned invalid backup target pagination")
	}
	previous := afterPath
	for _, item := range page.Items {
		if item.Bucket != "catalog-public" || !immutablePathPattern.MatchString(item.Path) || !jobDigestPattern.MatchString(item.Digest) || item.ByteCount <= 0 || item.ByteCount > 2<<30 || item.Path <= previous {
			return BackupTargetPage{}, errors.New("database returned an invalid or unsorted backup target")
		}
		previous = item.Path
	}
	if page.NextCursor != "" && (len(page.Items) == 0 || page.NextCursor != previous) {
		return BackupTargetPage{}, errors.New("database returned a non-progressing backup cursor")
	}
	return page, nil
}

func (s *SQLAttemptStore) CompleteBackupVerification(ctx context.Context, job BackupVerificationJob, lease Lease, checked, mismatches int, reportDigest string) (bool, error) {
	if checked < 0 || mismatches < 0 || mismatches > checked || !jobDigestPattern.MatchString(reportDigest) {
		return false, errors.New("backup verification result is invalid")
	}
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_complete_backup_verification($1, $2, $3, $4, $5)`,
		job.RunID, lease.Owner, checked, mismatches, reportDigest).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) FailBackupVerification(ctx context.Context, job BackupVerificationJob, lease Lease, safeCode string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_fail_backup_verification($1, $2, $3)`, job.RunID, lease.Owner, safeCode).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) BeginAccountDeletion(ctx context.Context, job AccountDeletionJob, lease Lease) (string, error) {
	var payload []byte
	err := s.database.QueryRowContext(ctx, `select wali.worker_begin_account_deletion($1, $2, $3, $4)`,
		job.DeletionID, job.UserID, lease.Owner, lease.ExpiresAt).Scan(&payload)
	if err != nil {
		return "", err
	}
	var begin struct {
		Disposition string `json:"disposition"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&begin); err != nil {
		return "", errors.New("database returned an invalid account deletion lease")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return "", errors.New("database returned trailing account deletion lease data")
	}
	switch begin.Disposition {
	case "held", "active", "cleanup_pending", "ready", "completed", "stale":
		return begin.Disposition, nil
	default:
		return "", errors.New("database returned an unknown account deletion disposition")
	}
}

func (s *SQLAttemptStore) CompleteAccountDeletion(ctx context.Context, job AccountDeletionJob, lease Lease) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_complete_account_deletion($1, $2, $3)`,
		job.DeletionID, job.UserID, lease.Owner).Scan(&current)
	return current, err
}

func (s *SQLAttemptStore) FailAccountDeletion(ctx context.Context, job AccountDeletionJob, lease Lease, safeCode string) (bool, error) {
	var current bool
	err := s.database.QueryRowContext(ctx, `select wali.worker_fail_account_deletion($1, $2, $3, $4)`,
		job.DeletionID, job.UserID, lease.Owner, safeCode).Scan(&current)
	return current, err
}

func validCleanupTarget(bucket, objectPath string) bool {
	if objectPath == "" || path.Clean(objectPath) != objectPath || strings.Contains(objectPath, "..") {
		return false
	}
	switch bucket {
	case "uploads-private":
		return uploadPathPattern.MatchString(objectPath)
	case "exports-private":
		parts := strings.Split(objectPath, "/")
		return exportPathPattern.MatchString(objectPath) && len(parts) == 4 && jobIDPattern.MatchString(parts[1]) && jobIDPattern.MatchString(parts[2])
	case "processing-private":
		return immutablePathPattern.MatchString(objectPath)
	case "moderation-private":
		return moderationPathPattern.MatchString(objectPath)
	default:
		return false
	}
}

func promotionArtifactsEqual(left, right []PromotionArtifact) bool {
	if len(left) != len(right) {
		return false
	}
	byRole := make(map[string]PromotionArtifact, len(left))
	for _, artifact := range left {
		byRole[artifact.Role] = artifact
	}
	for _, artifact := range right {
		if byRole[artifact.Role] != artifact {
			return false
		}
	}
	return true
}
