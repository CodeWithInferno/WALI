package maintenance

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type SourceStore interface {
	Open(context.Context, ObjectKey) (io.ReadCloser, error)
}

type ArchiveStore interface {
	PutIfAbsent(context.Context, string, int64, io.Reader) error
	Open(context.Context, string) (io.ReadCloser, error)
}

type Attestor interface {
	SignDigest(context.Context, string) (keyID string, signature []byte, err error)
}

type Runner struct {
	source      SourceStore
	archive     ArchiveStore
	attestor    Attestor
	scratchRoot string
	clock       func() time.Time
}

type ReportEntry struct {
	Bucket      string `json:"bucket"`
	Path        string `json:"path"`
	ArchivePath string `json:"archive_path"`
	Digest      string `json:"digest"`
	ByteCount   int64  `json:"byte_count"`
}

type ReportBody struct {
	SchemaVersion uint16        `json:"schema_version"`
	BackupID      string        `json:"backup_id"`
	CreatedAt     string        `json:"created_at"`
	Status        string        `json:"status"`
	ObjectCount   int           `json:"object_count"`
	VerifiedCount int           `json:"verified_count"`
	Entries       []ReportEntry `json:"entries"`
	Issues        []Issue       `json:"issues"`
}

type SignedReport struct {
	Body          ReportBody `json:"body"`
	BodySHA256    string     `json:"body_sha256"`
	AttestationID string     `json:"attestation_key_id"`
	Signature     string     `json:"signature_base64"`
}

func NewRunner(source SourceStore, archive ArchiveStore, attestor Attestor, scratchRoot string) (*Runner, error) {
	if source == nil || archive == nil || attestor == nil {
		return nil, errors.New("backup dependencies are required")
	}
	if !filepath.IsAbs(scratchRoot) || filepath.Clean(scratchRoot) != scratchRoot || scratchRoot == "/" {
		return nil, errors.New("backup scratch root must be narrow, absolute, and clean")
	}
	return &Runner{source: source, archive: archive, attestor: attestor, scratchRoot: scratchRoot, clock: time.Now}, nil
}

func (runner *Runner) Run(ctx context.Context, backupID string, inventory []InventoryObject) (SignedReport, error) {
	if err := validateBackupID(backupID); err != nil {
		return SignedReport{}, err
	}
	if err := ValidateInventory(inventory); err != nil {
		return SignedReport{}, err
	}
	if err := os.MkdirAll(runner.scratchRoot, 0o700); err != nil {
		return SignedReport{}, errors.New("create backup scratch root")
	}

	body := ReportBody{
		SchemaVersion: 1, BackupID: backupID,
		CreatedAt: runner.clock().UTC().Format(time.RFC3339), Status: "passed",
		ObjectCount: len(inventory), Entries: []ReportEntry{}, Issues: []Issue{},
	}
	for _, object := range sortedInventory(inventory) {
		entry, issue := runner.mirrorOne(ctx, backupID, object)
		if issue != nil {
			body.Issues = append(body.Issues, *issue)
			continue
		}
		body.Entries = append(body.Entries, entry)
		body.VerifiedCount++
	}
	if len(body.Issues) != 0 {
		body.Status = "failed"
		sortIssues(body.Issues)
	}
	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return SignedReport{}, errors.New("encode backup report")
	}
	digestBytes := sha256.Sum256(bodyJSON)
	digest := hex.EncodeToString(digestBytes[:])
	keyID, signature, err := runner.attestor.SignDigest(ctx, digest)
	if err != nil {
		return SignedReport{}, errors.New("attest backup report")
	}
	if !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`).MatchString(keyID) || len(signature) == 0 || len(signature) > 1024 {
		return SignedReport{}, errors.New("backup attestation is invalid")
	}
	return SignedReport{
		Body: body, BodySHA256: digest, AttestationID: keyID,
		Signature: base64.RawStdEncoding.EncodeToString(signature),
	}, nil
}

func (runner *Runner) mirrorOne(ctx context.Context, backupID string, object InventoryObject) (ReportEntry, *Issue) {
	key := ObjectKey{Bucket: object.Bucket, Path: object.Path}
	source, err := runner.source.Open(ctx, key)
	if err != nil {
		return ReportEntry{}, issueFor("source_unavailable", key)
	}
	defer source.Close()

	temporary, err := os.CreateTemp(runner.scratchRoot, "backup-object-*")
	if err != nil {
		return ReportEntry{}, issueFor("scratch_unavailable", key)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return ReportEntry{}, issueFor("scratch_unavailable", key)
	}
	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(temporary, hasher), io.LimitReader(source, object.ByteCount+1))
	closeErr := temporary.Close()
	if copyErr != nil || closeErr != nil || written != object.ByteCount {
		return ReportEntry{}, issueFor("source_size_mismatch", key)
	}
	observedDigest := hex.EncodeToString(hasher.Sum(nil))
	if object.Digest != "" && object.Digest != observedDigest {
		return ReportEntry{}, issueFor("source_digest_mismatch", key)
	}

	archivePath := backupID + "/" + object.Bucket + "/" + object.Path
	staged, err := os.Open(temporaryPath)
	if err != nil {
		return ReportEntry{}, issueFor("scratch_unavailable", key)
	}
	putErr := runner.archive.PutIfAbsent(ctx, archivePath, object.ByteCount, staged)
	closeErr = staged.Close()
	if putErr != nil || closeErr != nil {
		return ReportEntry{}, issueFor("archive_write_failed", key)
	}

	archived, err := runner.archive.Open(ctx, archivePath)
	if err != nil {
		return ReportEntry{}, issueFor("archive_unavailable", key)
	}
	archiveHasher := sha256.New()
	archivedBytes, readErr := io.Copy(archiveHasher, io.LimitReader(archived, object.ByteCount+1))
	closeErr = archived.Close()
	archiveDigest := hex.EncodeToString(archiveHasher.Sum(nil))
	if readErr != nil || closeErr != nil || archivedBytes != object.ByteCount || archiveDigest != observedDigest {
		return ReportEntry{}, issueFor("archive_verification_failed", key)
	}
	return ReportEntry{
		Bucket: object.Bucket, Path: object.Path, ArchivePath: archivePath,
		Digest: observedDigest, ByteCount: object.ByteCount,
	}, nil
}

func issueFor(code string, key ObjectKey) *Issue {
	return &Issue{Code: code, Bucket: key.Bucket, Path: key.Path}
}

func (report SignedReport) JSON() ([]byte, error) {
	data, err := json.Marshal(report)
	if err != nil {
		return nil, fmt.Errorf("encode signed report: %w", err)
	}
	return data, nil
}

const maximumObjectBytes = int64(2 << 30)

var (
	digestPattern   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	uuidPattern     = `[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`
	backupIDPattern = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$`)
	catalogPath     = regexp.MustCompile(`^sha256/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}/[a-z0-9_-]+\.(jpg|jpeg|png|mp4)$`)
	uploadPath      = regexp.MustCompile(`^` + uuidPattern + `/` + uuidPattern + `/source$`)
	rightsPath      = regexp.MustCompile(`^rights/` + uuidPattern + `/` + uuidPattern + `/proof\.[a-z0-9]{2,8}$`)
	copyrightPath   = regexp.MustCompile(`^copyright/` + uuidPattern + `/(notice|counter-notice)\.[a-z0-9]{2,8}$`)
)

type ObjectClass string

const (
	CatalogObject         ObjectClass = "catalog"
	RetainedPrivateObject ObjectClass = "retained_private"
)

type InventoryObject struct {
	Bucket    string      `json:"bucket"`
	Path      string      `json:"path"`
	Digest    string      `json:"digest,omitempty"`
	ByteCount int64       `json:"byte_count"`
	Class     ObjectClass `json:"class"`
}
type ObjectKey struct {
	Bucket string
	Path   string
}
type Issue struct {
	Code   string `json:"code"`
	Bucket string `json:"bucket"`
	Path   string `json:"path"`
}

func ValidateInventory(objects []InventoryObject) error {
	seen := make(map[ObjectKey]struct{}, len(objects))
	for _, object := range objects {
		if err := validateObject(object); err != nil {
			return err
		}
		key := ObjectKey{object.Bucket, object.Path}
		if _, exists := seen[key]; exists {
			return errors.New("inventory contains a duplicate object")
		}
		seen[key] = struct{}{}
	}
	return nil
}

func Reconcile(expected, observed []InventoryObject) []Issue {
	issues := []Issue{}
	wanted := map[ObjectKey]InventoryObject{}
	actual := map[ObjectKey]InventoryObject{}
	for _, object := range expected {
		key := ObjectKey{object.Bucket, object.Path}
		if _, exists := wanted[key]; exists {
			issues = append(issues, Issue{"duplicate_reference", key.Bucket, key.Path})
		} else {
			wanted[key] = object
		}
	}
	for _, object := range observed {
		key := ObjectKey{object.Bucket, object.Path}
		if _, exists := actual[key]; exists {
			issues = append(issues, Issue{"duplicate_observation", key.Bucket, key.Path})
		} else {
			actual[key] = object
		}
	}
	for key, expectedObject := range wanted {
		observedObject, exists := actual[key]
		if !exists {
			issues = append(issues, Issue{"missing_object", key.Bucket, key.Path})
			continue
		}
		if expectedObject.ByteCount != observedObject.ByteCount {
			issues = append(issues, Issue{"byte_count_mismatch", key.Bucket, key.Path})
		}
		if expectedObject.Digest != "" && expectedObject.Digest != observedObject.Digest {
			issues = append(issues, Issue{"digest_mismatch", key.Bucket, key.Path})
		}
	}
	for key := range actual {
		if _, exists := wanted[key]; !exists {
			issues = append(issues, Issue{"unreferenced_object", key.Bucket, key.Path})
		}
	}
	sortIssues(issues)
	return issues
}

func validateBackupID(value string) error {
	if !backupIDPattern.MatchString(value) {
		return errors.New("backup ID is invalid")
	}
	return nil
}
func validateObject(object InventoryObject) error {
	if object.ByteCount <= 0 || object.ByteCount > maximumObjectBytes {
		return errors.New("inventory byte count is out of bounds")
	}
	if object.Path == "" || path.IsAbs(object.Path) || path.Clean(object.Path) != object.Path || strings.Contains(object.Path, "../") || strings.ContainsAny(object.Path, "\\\x00\r\n") {
		return errors.New("inventory path is unsafe")
	}
	if object.Digest != "" {
		if !digestPattern.MatchString(object.Digest) {
			return errors.New("inventory digest is invalid")
		}
		if _, err := hex.DecodeString(object.Digest); err != nil {
			return errors.New("inventory digest is invalid")
		}
	}
	switch object.Class {
	case CatalogObject:
		if object.Bucket != "catalog-public" || object.Digest == "" || !contentAddressMatches(object) {
			return errors.New("catalog object is not content addressed")
		}
	case RetainedPrivateObject:
		allowed := object.Bucket == "uploads-private" && uploadPath.MatchString(object.Path)
		allowed = allowed || object.Bucket == "processing-private" && object.Digest != "" && contentAddressMatches(object)
		allowed = allowed || object.Bucket == "moderation-private" && (rightsPath.MatchString(object.Path) || copyrightPath.MatchString(object.Path))
		if !allowed {
			return errors.New("retained private object bucket is not allowed")
		}
	default:
		return errors.New("inventory object class is invalid")
	}
	return nil
}
func contentAddressMatches(object InventoryObject) bool {
	return catalogPath.MatchString(object.Path) && strings.HasPrefix(object.Path, "sha256/"+object.Digest[:2]+"/"+object.Digest[2:4]+"/"+object.Digest+"/")
}
func sortedInventory(objects []InventoryObject) []InventoryObject {
	result := append([]InventoryObject(nil), objects...)
	sort.Slice(result, func(i, j int) bool {
		if result[i].Bucket == result[j].Bucket {
			return result[i].Path < result[j].Path
		}
		return result[i].Bucket < result[j].Bucket
	})
	return result
}
func sortIssues(issues []Issue) {
	sort.Slice(issues, func(i, j int) bool {
		if issues[i].Bucket != issues[j].Bucket {
			return issues[i].Bucket < issues[j].Bucket
		}
		if issues[i].Path != issues[j].Path {
			return issues[i].Path < issues[j].Path
		}
		return issues[i].Code < issues[j].Code
	})
}
