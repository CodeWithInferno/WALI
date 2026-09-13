package jobs_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/claims"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/config"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/health"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/queue"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func validJobJSON() string {
	return `{
      "schema_version":1,
      "attempt_id":"11111111-1111-4111-8111-111111111111",
      "submission_id":"22222222-2222-4222-8222-222222222222",
      "generation":3,
		"input":{"bucket":"uploads-private","path":"60000000-0000-4000-8000-000000000001/70000000-0000-4000-8000-000000000001/source","byte_count":6,"storage_version":"server-version-1"},
      "policy_digest":"` + strings.Repeat("b", 64) + `",
      "expected_artifact_roles":["thumbnail","poster","preview","video_default"],
      "deadline_at":"2030-01-02T03:04:05Z",
      "extensions":{"trace":{"version":1}}
    }`
}

func TestDecodeProcessSubmissionStrictAndBounded(t *testing.T) {
	job, err := jobs.DecodeProcessSubmission(strings.NewReader(validJobJSON()), 16<<10)
	if err != nil {
		t.Fatal(err)
	}
	if job.Generation != 3 || len(job.ExpectedArtifactRoles) != 4 {
		t.Fatalf("unexpected job: %#v", job)
	}

	unknown := strings.Replace(validJobJSON(), `"generation":3`, `"generation":3,"shell":"rm -rf /"`, 1)
	if _, err := jobs.DecodeProcessSubmission(strings.NewReader(unknown), 16<<10); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("expected unknown field rejection, got %v", err)
	}

	var extensionFields strings.Builder
	for index := 0; index < 18; index++ {
		if index > 0 {
			extensionFields.WriteByte(',')
		}
		extensionFields.WriteString(`"x` + strconv.Itoa(index) + `":1`)
	}
	tooManyExtensions := strings.Replace(validJobJSON(), `"trace":{"version":1}`, extensionFields.String(), 1)
	if _, err := jobs.DecodeProcessSubmission(strings.NewReader(tooManyExtensions), 16<<10); err == nil || !strings.Contains(err.Error(), "extensions") {
		t.Fatalf("expected extension bound rejection, got %v", err)
	}

	unexpectedRole := strings.Replace(validJobJSON(), `"video_default"]`, `"video_default","video_2160p"]`, 1)
	if _, err := jobs.DecodeProcessSubmission(strings.NewReader(unexpectedRole), 16<<10); err == nil || !strings.Contains(err.Error(), "exactly") {
		t.Fatalf("expected current policy role-set rejection, got %v", err)
	}
}

type fakeAttempts struct {
	mu                 sync.Mutex
	begin              jobs.BeginDisposition
	heartbeatOK        bool
	completeOK         bool
	failOK             bool
	completed          int
	completion         jobs.Completion
	failed             int
	heartbeats         int
	heartbeatLoseAfter int
}

func (f *fakeAttempts) Begin(context.Context, jobs.ProcessSubmission, jobs.Lease) (jobs.BeginDisposition, error) {
	return f.begin, nil
}
func (f *fakeAttempts) Heartbeat(context.Context, jobs.ProcessSubmission, jobs.Lease, time.Time) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.heartbeats++
	if f.heartbeatLoseAfter > 0 && f.heartbeats > f.heartbeatLoseAfter {
		return false, nil
	}
	return f.heartbeatOK, nil
}
func (f *fakeAttempts) AuthorizeStagedArtifact(context.Context, jobs.ProcessSubmission, jobs.Lease, jobs.CompletionArtifact) (bool, error) {
	return f.heartbeatOK, nil
}
func (f *fakeAttempts) Complete(_ context.Context, _ jobs.ProcessSubmission, _ jobs.Lease, completion jobs.Completion) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.completed++
	f.completion = completion
	return f.completeOK, nil
}
func (f *fakeAttempts) Fail(context.Context, jobs.ProcessSubmission, jobs.Lease, jobs.Failure) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failed++
	return f.failOK, nil
}

type fakeBlobs struct {
	input         []byte
	published     []storage.PublishRequest
	downloadErr   error
	downloads     int
	publishErrAt  int
	deletedBucket string
	deletedPath   string
}

type fakeExportStore struct {
	begin     jobs.ExportBegin
	payload   json.RawMessage
	completed bool
	failed    string
}

func (store *fakeExportStore) BeginExport(context.Context, jobs.ExportJob, jobs.Lease) (jobs.ExportBegin, error) {
	return store.begin, nil
}
func (store *fakeExportStore) ReadExport(context.Context, jobs.ExportJob, jobs.Lease) (json.RawMessage, error) {
	return store.payload, nil
}
func (store *fakeExportStore) CompleteExport(_ context.Context, _ jobs.ExportJob, _ jobs.Lease, _ int64, _ string) (bool, error) {
	store.completed = true
	return true, nil
}
func (store *fakeExportStore) FailExport(_ context.Context, _ jobs.ExportJob, _ jobs.Lease, code string) (bool, error) {
	store.failed = code
	return true, nil
}

type fakePromotionStore struct {
	begin     jobs.PromotionBegin
	completed bool
	failed    string
}

func (store *fakePromotionStore) BeginPromotion(context.Context, jobs.PromotionJob, jobs.Lease) (jobs.PromotionBegin, error) {
	return store.begin, nil
}
func (store *fakePromotionStore) CompletePromotion(context.Context, jobs.PromotionJob, jobs.Lease) (bool, error) {
	store.completed = true
	return true, nil
}
func (store *fakePromotionStore) FailPromotion(_ context.Context, _ jobs.PromotionJob, _ jobs.Lease, code string) (bool, error) {
	store.failed = code
	return true, nil
}

type fakePromotionBlobs struct {
	source    map[string][]byte
	published []storage.PublishRequest
	corrupt   bool
}

func (blobs *fakePromotionBlobs) DownloadVerified(_ context.Context, object storage.ImmutableObjectRef, destination string) error {
	data, ok := blobs.source[object.Path]
	if !ok {
		return os.ErrNotExist
	}
	if blobs.corrupt {
		return storage.ErrObjectIntegrity
	}
	if digest(data) != object.Digest || int64(len(data)) != object.ByteCount {
		return storage.ErrObjectIntegrity
	}
	return os.WriteFile(destination, data, 0o600)
}
func (blobs *fakePromotionBlobs) Publish(_ context.Context, request storage.PublishRequest) error {
	blobs.published = append(blobs.published, request)
	return nil
}

type classifierRunner struct {
	wrongModel bool
	called     bool
}

func (runner *classifierRunner) Run(_ context.Context, spec sandbox.Spec) error {
	runner.called = true
	request, err := os.ReadFile(filepath.Join(spec.InputDirectory, "classification-request.json"))
	if err != nil {
		return err
	}
	var envelope struct {
		AttemptID    string             `json:"attempt_id"`
		SubmissionID string             `json:"submission_id"`
		Generation   uint32             `json:"generation"`
		Frames       []classifier.Frame `json:"frames"`
	}
	if err := json.Unmarshal(request, &envelope); err != nil {
		return err
	}
	joined := ""
	for _, frame := range envelope.Frames {
		joined += frame.Digest
	}
	modelDigest := classifier.ModelDigest
	if runner.wrongModel {
		modelDigest = strings.Repeat("0", 64)
	}
	zeros := make([]float64, 768)
	zeros[0] = 1
	claim := map[string]any{"schema_version": 1, "attempt_id": envelope.AttemptID, "submission_id": envelope.SubmissionID, "generation": envelope.Generation,
		"available": true, "safe_code": "ok", "model_id": classifier.ModelID, "model_revision": classifier.ModelRevision, "model_digest": modelDigest,
		"taxonomy_revision": classifier.TaxonomyRevision, "input_frame_set_digest": digest([]byte(joined)), "visual_embedding": zeros, "text_embedding": zeros, "combined_embedding": zeros,
		"categories": []map[string]any{{"id": "nature", "confidence": 0.9}}, "tags": []map[string]any{{"id": "forest", "confidence": 0.8}}}
	encoded, err := json.Marshal(claim)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(spec.OutputDirectory, "classification-claim.json"), encoded, 0o600)
}

func (f *fakeBlobs) Download(_ context.Context, _ storage.RawObjectRef, destination string) (storage.ObservedObject, error) {
	f.downloads++
	if f.downloadErr != nil {
		return storage.ObservedObject{}, f.downloadErr
	}
	if err := os.WriteFile(destination, f.input, 0o600); err != nil {
		return storage.ObservedObject{}, err
	}
	return storage.ObservedObject{Digest: digest(f.input), ByteCount: int64(len(f.input))}, nil
}
func (f *fakeBlobs) Publish(_ context.Context, request storage.PublishRequest) error {
	f.published = append(f.published, request)
	if f.publishErrAt > 0 && len(f.published) == f.publishErrAt {
		return errors.New("upload unavailable")
	}
	return nil
}
func (f *fakeBlobs) Delete(_ context.Context, bucket, objectPath string) error {
	f.deletedBucket, f.deletedPath = bucket, objectPath
	return nil
}

type fakeSandbox struct {
	crashMode    sandbox.Mode
	corruptClaim bool
	failureCode  string
	delay        time.Duration
}

func (f fakeSandbox) Run(ctx context.Context, spec sandbox.Spec) error {
	if f.delay > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(f.delay):
		}
	}
	if spec.Mode == f.crashMode {
		if f.failureCode != "" {
			failure := `{"schema_version":1,"attempt_id":"11111111-1111-4111-8111-111111111111","submission_id":"22222222-2222-4222-8222-222222222222","generation":3,"safe_code":"` + f.failureCode + `"}`
			if err := os.WriteFile(filepath.Join(spec.OutputDirectory, "failure.json"), []byte(failure), 0o600); err != nil {
				return err
			}
		}
		return sandbox.ErrRuntimeFailed
	}
	if err := os.MkdirAll(filepath.Join(spec.OutputDirectory, "artifacts"), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(spec.OutputDirectory, "frames"), 0o700); err != nil {
		return err
	}
	if spec.Mode == sandbox.ModeProcess {
		artifacts := []struct {
			role, name, media string
			width, height     int
		}{
			{"thumbnail", "thumbnail.jpg", "image/jpeg", 512, 512},
			{"poster", "poster.jpg", "image/jpeg", 1920, 1080},
			{"preview", "preview.mp4", "video/mp4", 1280, 720},
			{"video_default", "video-default.mp4", "video/mp4", 1920, 1080},
		}
		var claim bytes.Buffer
		claim.WriteString(`{"schema_version":1,"kind":"media","attempt_id":"11111111-1111-4111-8111-111111111111","submission_id":"22222222-2222-4222-8222-222222222222","generation":3,"policy_digest":"` + strings.Repeat("b", 64) + `","input_digest":"` + digest([]byte("opaque")) + `","artifacts":[`)
		for i, artifact := range artifacts {
			data := []byte(artifact.role)
			if err := os.WriteFile(filepath.Join(spec.OutputDirectory, "artifacts", artifact.name), data, 0o600); err != nil {
				return err
			}
			if i > 0 {
				claim.WriteByte(',')
			}
			claim.WriteString(`{"role":"` + artifact.role + `","relative_path":"artifacts/` + artifact.name + `","digest":"` + digest(data) + `","byte_count":` + strconv.Itoa(len(data)) + `,"media_type":"` + artifact.media + `","width":`)
			if artifact.width == 512 {
				claim.WriteString("512")
			} else if artifact.width == 1280 {
				claim.WriteString("1280")
			} else {
				claim.WriteString("1920")
			}
			claim.WriteString(`,"height":`)
			if artifact.height == 512 {
				claim.WriteString("512")
			} else if artifact.height == 720 {
				claim.WriteString("720")
			} else {
				claim.WriteString("1080")
			}
			claim.WriteString(`,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":1,"codec":"mjpeg","pixel_format":"yuv420p","color_space":"bt709","has_audio":false}`)
		}
		claim.WriteString(`],"sample_frames":[`)
		for i := 1; i <= 7; i++ {
			frameName := "frame-00" + string(rune('0'+i)) + ".jpg"
			data := []byte{byte(i)}
			if err := os.WriteFile(filepath.Join(spec.OutputDirectory, "frames", frameName), data, 0o600); err != nil {
				return err
			}
			if i > 1 {
				claim.WriteByte(',')
			}
			claim.WriteString(`{"ordinal":` + string(rune('0'+i)) + `,"relative_path":"frames/` + frameName + `","digest":"` + digest(data) + `","byte_count":1,"width":384,"height":224}`)
		}
		claim.WriteString(`],"encoder_build":"test","safe_code":"ok"}`)
		if f.corruptClaim {
			claim.Reset()
			claim.WriteString(`{"safe_code":"malformed"}`)
		}
		return os.WriteFile(filepath.Join(spec.OutputDirectory, "media-claim.json"), claim.Bytes(), 0o600)
	}
	media, err := os.ReadFile(filepath.Join(spec.InputDirectory, "media-claim.json"))
	if err != nil {
		return err
	}
	verified := bytes.Replace(media, []byte(`"kind":"media"`), []byte(`"kind":"verification"`), 1)
	return os.WriteFile(filepath.Join(spec.OutputDirectory, "verification-claim.json"), verified, 0o600)
}

type fakeCleanup struct{ enqueued int }

func (f *fakeCleanup) Enqueue(context.Context, string, string) error { f.enqueued++; return nil }

type failingCleaner struct{}

func (failingCleaner) Remove(string) error { return errors.New("filesystem busy") }

func newProcessor(t *testing.T, attempts *fakeAttempts, blobs *fakeBlobs, runner fakeSandbox) *jobs.Processor {
	t.Helper()
	p, err := jobs.NewProcessor(jobs.Dependencies{
		Attempts:          attempts,
		Blobs:             blobs,
		Sandbox:           runner,
		Classifier:        classifier.Noop{},
		Cleanup:           &fakeCleanup{},
		ScratchRoot:       t.TempDir(),
		MediaImage:        "localhost/wali-media@sha256:" + strings.Repeat("c", 64),
		VerifierImage:     "localhost/wali-verifier@sha256:" + strings.Repeat("d", 64),
		PolicyDigest:      strings.Repeat("b", 64),
		HeartbeatInterval: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func decodeJob(t *testing.T) jobs.ProcessSubmission {
	t.Helper()
	job, err := jobs.DecodeProcessSubmission(strings.NewReader(validJobJSON()), 16<<10)
	if err != nil {
		t.Fatal(err)
	}
	return job
}

func TestProcessorCommitsBeforeAckAndPublishesEveryVerifiedArtifact(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	result := newProcessor(t, attempts, blobs, fakeSandbox{}).Process(context.Background(), decodeJob(t), jobs.Lease{MessageID: 9, Owner: "worker-1", ExpiresAt: time.Now().Add(time.Minute)})
	if result.Action != jobs.ActionAck || result.SafeCode != "ok" {
		t.Fatalf("result = %#v", result)
	}
	if attempts.completed != 1 {
		t.Fatalf("completions = %d", attempts.completed)
	}
	if blobs.downloads != 1 || attempts.completion.SourceDigest != digest([]byte("opaque")) {
		t.Fatalf("downloads=%d source_digest=%q", blobs.downloads, attempts.completion.SourceDigest)
	}
	for _, artifact := range attempts.completion.Artifacts {
		encoded, err := json.Marshal(artifact)
		if err != nil || bytes.Contains(encoded, []byte("relative_path")) {
			t.Fatalf("completion artifact leaked local path: %s (%v)", encoded, err)
		}
	}
	if len(blobs.published) != 4 {
		t.Fatalf("published = %d", len(blobs.published))
	}
	for _, publication := range blobs.published {
		if publication.Bucket != "processing-private" || !strings.HasPrefix(publication.ObjectPath, "sha256/") || publication.CreateOnly != true {
			t.Fatalf("unsafe publication: %#v", publication)
		}
	}
}

func TestProcessorAcksCompletedDuplicateWithoutRunning(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginAlreadyCompleted}
	blobs := &fakeBlobs{}
	result := newProcessor(t, attempts, blobs, fakeSandbox{}).Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionAck || len(blobs.published) != 0 || attempts.completed != 0 {
		t.Fatalf("duplicate result=%#v published=%d complete=%d", result, len(blobs.published), attempts.completed)
	}
}

func TestProcessorLeavesStaleCompletionUnacknowledged(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: false, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	result := newProcessor(t, attempts, blobs, fakeSandbox{}).Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionLeave || result.SafeCode != "stale_completion" || attempts.completed != 1 {
		t.Fatalf("result=%#v completed=%d", result, attempts.completed)
	}
}

func TestProcessorLeavesStaleLeaseUnacknowledged(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: false}
	blobs := &fakeBlobs{input: []byte("opaque")}
	result := newProcessor(t, attempts, blobs, fakeSandbox{}).Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionLeave || result.SafeCode != "lease_lost" {
		t.Fatalf("result = %#v", result)
	}
}

func TestProcessorRejectsUnreviewedPolicyBeforeDownloadOrSandbox(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	processor := newProcessor(t, attempts, blobs, fakeSandbox{})
	job := decodeJob(t)
	job.PolicyDigest = strings.Repeat("a", 64)
	result := processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"})
	if result.Action != jobs.ActionAck || result.SafeCode != "policy_mismatch" || attempts.failed != 1 || blobs.downloads != 0 {
		t.Fatalf("result=%#v failed=%d downloads=%d", result, attempts.failed, blobs.downloads)
	}
}

func TestProcessorRetriesRuntimeCrashAndPartialUpload(t *testing.T) {
	for _, tc := range []struct {
		name   string
		runner fakeSandbox
		blobs  *fakeBlobs
	}{
		{"runtime crash", fakeSandbox{crashMode: sandbox.ModeProcess}, &fakeBlobs{input: []byte("opaque")}},
		{"partial upload", fakeSandbox{}, &fakeBlobs{input: []byte("opaque"), publishErrAt: 2}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
			result := newProcessor(t, attempts, tc.blobs, tc.runner).Process(context.Background(), decodeJob(t), jobs.Lease{})
			if result.Action != jobs.ActionNack {
				t.Fatalf("result = %#v", result)
			}
			if attempts.completed != 0 {
				t.Fatal("transient failure committed completion")
			}
		})
	}
}

func TestProcessorCommitsPermanentClaimFailureBeforeAck(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	p := newProcessor(t, attempts, blobs, fakeSandbox{corruptClaim: true})
	result := p.Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionAck || result.SafeCode != "invalid_media_claim" || attempts.failed != 1 {
		t.Fatalf("result=%#v failed=%d", result, attempts.failed)
	}
}

func TestProcessorCommitsDeclaredPermanentMediaPolicyFailureBeforeAck(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	p := newProcessor(t, attempts, blobs, fakeSandbox{crashMode: sandbox.ModeProcess, failureCode: "unsupported_codec"})
	result := p.Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionAck || result.SafeCode != "unsupported_codec" || attempts.failed != 1 {
		t.Fatalf("result=%#v failed=%d", result, attempts.failed)
	}
}

func TestProcessorRetriesRuntimeFailureEvenWhenFailureFileIsUntrusted(t *testing.T) {
	for _, code := range []string{"internal_error", "run_any_command"} {
		t.Run(code, func(t *testing.T) {
			attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
			blobs := &fakeBlobs{input: []byte("opaque")}
			p := newProcessor(t, attempts, blobs, fakeSandbox{crashMode: sandbox.ModeProcess, failureCode: code})
			result := p.Process(context.Background(), decodeJob(t), jobs.Lease{})
			if result.Action != jobs.ActionNack || result.SafeCode != "media_runtime_failed" || attempts.failed != 0 {
				t.Fatalf("result=%#v failed=%d", result, attempts.failed)
			}
		})
	}
}

func TestProcessorEnqueuesCleanupWhenScratchRemovalFails(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
	blobs := &fakeBlobs{input: []byte("opaque")}
	cleanup := &fakeCleanup{}
	p, err := jobs.NewProcessor(jobs.Dependencies{
		Attempts: attempts, Blobs: blobs, Sandbox: fakeSandbox{}, Classifier: classifier.Noop{},
		Cleanup: cleanup, Cleaner: failingCleaner{}, ScratchRoot: t.TempDir(),
		MediaImage:        "localhost/wali-media@sha256:" + strings.Repeat("c", 64),
		VerifierImage:     "localhost/wali-verifier@sha256:" + strings.Repeat("d", 64),
		PolicyDigest:      strings.Repeat("b", 64),
		HeartbeatInterval: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	result := p.Process(context.Background(), decodeJob(t), jobs.Lease{})
	if result.Action != jobs.ActionAck || cleanup.enqueued != 1 {
		t.Fatalf("result=%#v cleanup enqueued=%d", result, cleanup.enqueued)
	}
}

func TestProcessorStopsWithoutAckWhenLeaseExpiresDuringSandbox(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true, heartbeatLoseAfter: 2}
	blobs := &fakeBlobs{input: []byte("opaque")}
	p, err := jobs.NewProcessor(jobs.Dependencies{
		Attempts: attempts, Blobs: blobs, Sandbox: fakeSandbox{delay: 100 * time.Millisecond},
		Classifier: classifier.Noop{}, Cleanup: &fakeCleanup{}, ScratchRoot: t.TempDir(),
		MediaImage:        "localhost/wali-media@sha256:" + strings.Repeat("c", 64),
		VerifierImage:     "localhost/wali-verifier@sha256:" + strings.Repeat("d", 64),
		PolicyDigest:      strings.Repeat("b", 64),
		HeartbeatInterval: 5 * time.Millisecond, LeaseDuration: 20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	result := p.Process(context.Background(), decodeJob(t), jobs.Lease{})
	elapsed := time.Since(started)
	if result.Action != jobs.ActionLeave || result.SafeCode != "lease_lost" || attempts.completed != 0 {
		t.Fatalf("result=%#v heartbeats=%d complete=%d", result, attempts.heartbeats, attempts.completed)
	}
	if elapsed >= 75*time.Millisecond {
		t.Fatalf("sandbox was not cancelled promptly after lease loss: %s", elapsed)
	}
}

func TestNoopClassifierNeverFabricatesTags(t *testing.T) {
	result, err := (classifier.Noop{}).Classify(context.Background(), classifier.Request{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Available || result.SafeCode != "classifier_unavailable" || len(result.Categories) != 0 || len(result.Tags) != 0 {
		t.Fatalf("result = %#v", result)
	}
}

func TestExportProcessorWritesOnlyBoundedCanonicalProjection(t *testing.T) {
	job := jobs.ExportJob{SchemaVersion: 1, ExportID: "11111111-1111-4111-8111-111111111111", UserID: "22222222-2222-4222-8222-222222222222"}
	path := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	identity := `"account_identity":{"email":"owner@example.test","providers":["email","google"],"created_at":"2029-01-01T00:00:00Z","last_sign_in_at":null}`
	payload := `{"schema_version":1,"export_id":"` + job.ExportID + `","user_id":"` + job.UserID + `","exported_at":"2030-01-01T00:00:00Z",` + identity + `,"profile":{},"creator_profile":null,"preferences":{},"terms_acceptances":[],"favorites":[],"saved_wallpapers":[],"creator_follows":[],"install_receipts":[],"engagement_events":[],"upload_sessions":[],"submissions":[],"rights_declarations":[],"reports":[]}`
	store := &fakeExportStore{begin: jobs.ExportBegin{Disposition: "started", Path: path}, payload: json.RawMessage(payload)}
	blobs := &fakeBlobs{}
	processor, err := jobs.NewExportProcessor(store, blobs, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	result := processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"})
	if result.Action != jobs.ActionAck || !store.completed || len(blobs.published) != 1 || blobs.published[0].Bucket != "exports-private" || blobs.published[0].ObjectPath != path {
		t.Fatalf("result=%#v completed=%v publications=%#v", result, store.completed, blobs.published)
	}
	nullableIdentity := strings.Replace(payload, `"email":"owner@example.test"`, `"email":null`, 1)
	nullableIdentity = strings.Replace(nullableIdentity, `"created_at":"2029-01-01T00:00:00Z"`, `"created_at":null`, 1)
	store = &fakeExportStore{begin: jobs.ExportBegin{Disposition: "started", Path: path}, payload: json.RawMessage(nullableIdentity)}
	processor, _ = jobs.NewExportProcessor(store, &fakeBlobs{}, t.TempDir())
	if result = processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"}); result.Action != jobs.ActionAck || !store.completed {
		t.Fatalf("nullable account identity was rejected: result=%#v failed=%q", result, store.failed)
	}
	invalidPayloads := map[string]string{
		"email outside allowlist":       strings.Replace(payload, `"profile":{}`, `"profile":{"email":"leak@example.test"}`, 1),
		"provider ID outside allowlist": strings.Replace(payload, `"profile":{}`, `"profile":{"provider_id":"subject"}`, 1),
		"missing identity":              strings.Replace(payload, identity+`,`, "", 1),
		"extra identity key":            strings.Replace(payload, `"last_sign_in_at":null`, `"last_sign_in_at":null,"provider_id":"subject"`, 1),
		"identity token":                strings.Replace(payload, `"last_sign_in_at":null`, `"last_sign_in_at":null,"access_token":"secret"`, 1),
		"unknown provider":              strings.Replace(payload, `["email","google"]`, `["email","made_up"]`, 1),
		"duplicate provider":            strings.Replace(payload, `["email","google"]`, `["email","email"]`, 1),
		"unsorted providers":            strings.Replace(payload, `["email","google"]`, `["google","email"]`, 1),
		"too many providers":            strings.Replace(payload, `["email","google"]`, `["anonymous","apple","azure","bitbucket","discord","email","facebook","figma","fly"]`, 1),
		"fractional timestamp":          strings.Replace(payload, `2029-01-01T00:00:00Z`, `2029-01-01T00:00:00.123Z`, 1),
		"identity claim elsewhere":      strings.Replace(payload, `"preferences":{}`, `"preferences":{"auth_claims":{"sub":"subject"}}`, 1),
		"oversized email":               strings.Replace(payload, `owner@example.test`, strings.Repeat("a", 321), 1),
		"control email":                 strings.Replace(payload, `owner@example.test`, `owner\n@example.test`, 1),
	}
	for name, invalidPayload := range invalidPayloads {
		store = &fakeExportStore{begin: jobs.ExportBegin{Disposition: "started", Path: path}, payload: json.RawMessage(invalidPayload)}
		processor, _ = jobs.NewExportProcessor(store, &fakeBlobs{}, t.TempDir())
		result = processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"})
		if result.Action != jobs.ActionAck || store.failed != "export_projection_invalid" {
			t.Fatalf("%s projection result=%#v failed=%q", name, result, store.failed)
		}
	}
}

func validPromotion(t *testing.T) (jobs.PromotionJob, map[string][]byte) {
	t.Helper()
	job := jobs.PromotionJob{SchemaVersion: 1, PromotionID: "11111111-1111-4111-8111-111111111111", ReleaseID: "22222222-2222-4222-8222-222222222222"}
	source := map[string][]byte{}
	for _, spec := range []struct{ role, extension, media string }{{"thumbnail", ".jpg", "image/jpeg"}, {"poster", ".jpg", "image/jpeg"}, {"preview", ".mp4", "video/mp4"}, {"video_default", ".mp4", "video/mp4"}} {
		data := []byte(spec.role)
		sum := digest(data)
		objectPath, err := storage.ImmutablePath(sum, spec.role, spec.role+spec.extension)
		if err != nil {
			t.Fatal(err)
		}
		job.Artifacts = append(job.Artifacts, jobs.PromotionArtifact{Role: spec.role, Digest: sum, ByteCount: int64(len(data)), MediaType: spec.media, SourceBucket: "processing-private", SourcePath: objectPath, DestinationBucket: "catalog-public", DestinationPath: objectPath})
		source[objectPath] = data
	}
	return job, source
}

func TestPromotionProcessorReverifiesPrivateBytesBeforePublicCreate(t *testing.T) {
	job, source := validPromotion(t)
	store := &fakePromotionStore{begin: jobs.PromotionBegin{Disposition: "started", PromotionID: job.PromotionID, ReleaseID: job.ReleaseID, Artifacts: job.Artifacts}}
	blobs := &fakePromotionBlobs{source: source}
	processor, err := jobs.NewPromotionProcessor(store, blobs, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	result := processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"})
	if result.Action != jobs.ActionAck || !store.completed || len(blobs.published) != 4 {
		t.Fatalf("result=%#v completed=%v published=%d", result, store.completed, len(blobs.published))
	}
	for _, publication := range blobs.published {
		if publication.Bucket != "catalog-public" || !publication.CreateOnly {
			t.Fatalf("publication=%#v", publication)
		}
	}
	blobs = &fakePromotionBlobs{source: source, corrupt: true}
	store = &fakePromotionStore{begin: store.begin}
	processor, _ = jobs.NewPromotionProcessor(store, blobs, t.TempDir())
	result = processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-1"})
	if result.Action != jobs.ActionAck || store.failed != "promotion_source_invalid" || len(blobs.published) != 0 {
		t.Fatalf("corrupt result=%#v failed=%q", result, store.failed)
	}
}

func TestSandboxedClassifierBindsFramesModelAndTaxonomy(t *testing.T) {
	input := t.TempDir()
	framesDirectory := filepath.Join(input, "frames")
	if err := os.Mkdir(framesDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	frames := make([]classifier.Frame, 0, 7)
	for index := 1; index <= 7; index++ {
		data := []byte{byte(index)}
		if err := os.WriteFile(filepath.Join(framesDirectory, "frame-00"+strconv.Itoa(index)+".jpg"), data, 0o600); err != nil {
			t.Fatal(err)
		}
		frames = append(frames, classifier.Frame{Ordinal: index, Digest: digest(data), ByteCount: 1, Width: 1, Height: 1})
	}
	runner := &classifierRunner{}
	value, err := classifier.NewSandboxed(runner, "localhost/wali-classifier@sha256:"+strings.Repeat("e", 64))
	if err != nil {
		t.Fatal(err)
	}
	request := classifier.Request{AttemptID: "11111111-1111-4111-8111-111111111111", SubmissionID: "22222222-2222-4222-8222-222222222222", Generation: 1,
		InputDirectory: input, OutputDirectory: filepath.Join(t.TempDir(), "output"), Title: "Forest", Description: "", Frames: frames, PolicyDigest: strings.Repeat("b", 64)}
	result, err := value.Classify(context.Background(), request)
	if err != nil || !runner.called || !result.Available || len(result.Categories) != 1 || len(result.VisualEmbedding) != 768 || len(result.TextEmbedding) != 768 || len(result.CombinedEmbedding) != 768 {
		t.Fatalf("result=%#v called=%v err=%v", result, runner.called, err)
	}
	runner = &classifierRunner{wrongModel: true}
	value, _ = classifier.NewSandboxed(runner, "localhost/wali-classifier@sha256:"+strings.Repeat("e", 64))
	request.OutputDirectory = filepath.Join(t.TempDir(), "output")
	if _, err := value.Classify(context.Background(), request); err == nil || !strings.Contains(err.Error(), "identity") {
		t.Fatalf("expected wrong model rejection, got %v", err)
	}
}

func TestMaximumClassifierResultFitsBoundedCompletionContract(t *testing.T) {
	embedding := make([]float64, 768)
	embedding[0] = 1
	scores := func(count int, prefix string) []classifier.Score {
		result := make([]classifier.Score, count)
		for index := range result {
			result[index] = classifier.Score{ID: fmt.Sprintf("%s_%03d", prefix, index), Confidence: 0.5}
		}
		return result
	}
	completion := jobs.Completion{SourceDigest: strings.Repeat("a", 64), Classification: classifier.Result{
		Available: true, SafeCode: "ok", ModelID: classifier.ModelID, ModelRevision: classifier.ModelRevision,
		ModelDigest: classifier.ModelDigest, TaxonomyRevision: classifier.TaxonomyRevision, InputFrameSetDigest: strings.Repeat("b", 64),
		VisualEmbedding: embedding, TextEmbedding: embedding, CombinedEmbedding: embedding,
		Categories: scores(64, "category"), Tags: scores(256, "tag"),
	}}
	encoded, err := json.Marshal(completion)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > 128<<10 {
		t.Fatalf("maximum completion is %d bytes", len(encoded))
	}
	noop, err := (classifier.Noop{}).Classify(context.Background(), classifier.Request{})
	if err != nil || noop.Available || noop.SafeCode != "classifier_unavailable" || len(noop.VisualEmbedding)+len(noop.TextEmbedding)+len(noop.CombinedEmbedding) != 0 {
		t.Fatalf("noop=%#v err=%v", noop, err)
	}
}

func TestCleanupProcessorResolvesOnlyOneChildOfFixedScratchRoot(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "attempt-1")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	store := &fakeCleanupStore{}
	processor, err := jobs.NewCleanupProcessor(root, &fakeBlobs{}, store)
	if err != nil {
		t.Fatal(err)
	}
	result := processor.Process(context.Background(), jobs.CleanupJob{SchemaVersion: 1, Kind: "scratch", ScratchPath: "scratch/attempt-1", Reason: "remove_failed"}, jobs.Lease{})
	if result.Action != jobs.ActionAck {
		t.Fatalf("result=%#v", result)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("target remains: %v", err)
	}
	if _, err := jobs.DecodeCleanupJob(strings.NewReader(`{"schema_version":1,"kind":"scratch","scratch_path":"scratch/../outside","reason":"remove_failed"}`), 4096); err == nil {
		t.Fatal("traversal cleanup was accepted")
	}
	blobs := &fakeBlobs{}
	store.begin = jobs.CleanupBegin{Disposition: "started", Bucket: "uploads-private", Path: "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/source"}
	processor, err = jobs.NewCleanupProcessor(root, blobs, store)
	if err != nil {
		t.Fatal(err)
	}
	const objectTarget = "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/source"
	objectJob, err := jobs.DecodeCleanupJob(strings.NewReader(`{"schema_version":1,"kind":"storage_object","cleanup_id":"44444444-4444-4444-8444-444444444444"}`), 4096)
	if err != nil {
		t.Fatal(err)
	}
	if result := processor.Process(context.Background(), objectJob, jobs.Lease{}); result.Action != jobs.ActionAck {
		t.Fatalf("object cleanup result=%#v", result)
	}
	if blobs.deletedBucket != "uploads-private" || blobs.deletedPath != objectTarget || !store.completed {
		t.Fatalf("delete target=%s/%s", blobs.deletedBucket, blobs.deletedPath)
	}
	for _, invalid := range []string{
		`{"schema_version":1,"kind":"storage_object","cleanup_id":"not-a-uuid"}`,
		`{"schema_version":1,"kind":"storage_object","cleanup_id":"44444444-4444-4444-8444-444444444444","storage_path":"../source"}`,
		`{"schema_version":1,"kind":"scratch","scratch_path":"scratch/a","reason":"unknown"}`,
	} {
		if _, err := jobs.DecodeCleanupJob(strings.NewReader(invalid), 4096); err == nil {
			t.Fatalf("unsafe object cleanup accepted: %s", invalid)
		}
	}
}

type fakeCleanupStore struct {
	begin     jobs.CleanupBegin
	completed bool
}

func (store *fakeCleanupStore) BeginCleanup(context.Context, jobs.CleanupJob, jobs.Lease) (jobs.CleanupBegin, error) {
	return store.begin, nil
}
func (store *fakeCleanupStore) CompleteCleanup(context.Context, jobs.CleanupJob, jobs.Lease) (bool, error) {
	store.completed = true
	return true, nil
}
func (*fakeCleanupStore) FailCleanup(context.Context, jobs.CleanupJob, jobs.Lease, string) (bool, error) {
	return true, nil
}

type fakeBackupStore struct {
	pages      []jobs.BackupTargetPage
	completed  bool
	checked    int
	mismatches int
	digest     string
}

func (*fakeBackupStore) BeginBackupVerification(context.Context, jobs.BackupVerificationJob, jobs.Lease) (string, error) {
	return "started", nil
}
func (store *fakeBackupStore) ReadBackupTargets(context.Context, jobs.BackupVerificationJob, jobs.Lease, string, int) (jobs.BackupTargetPage, error) {
	page := store.pages[0]
	store.pages = store.pages[1:]
	return page, nil
}
func (store *fakeBackupStore) CompleteBackupVerification(_ context.Context, _ jobs.BackupVerificationJob, _ jobs.Lease, checked, mismatches int, digest string) (bool, error) {
	store.completed, store.checked, store.mismatches, store.digest = true, checked, mismatches, digest
	return true, nil
}
func (*fakeBackupStore) FailBackupVerification(context.Context, jobs.BackupVerificationJob, jobs.Lease, string) (bool, error) {
	return true, nil
}

type fakeImmutableDownloader struct{ failedPath string }

func (downloader fakeImmutableDownloader) DownloadVerified(_ context.Context, object storage.ImmutableObjectRef, destination string) error {
	if object.Path == downloader.failedPath {
		return storage.ErrObjectIntegrity
	}
	return os.WriteFile(destination, []byte("verified"), 0o600)
}

func TestBackupVerificationProcessorPagesDeterministicallyAndRecordsMismatches(t *testing.T) {
	digest := strings.Repeat("a", 64)
	pathA := "sha256/aa/aa/" + digest + "/poster.jpg"
	pathB := "sha256/aa/aa/" + digest + "/video_default.mp4"
	store := &fakeBackupStore{pages: []jobs.BackupTargetPage{
		{Items: []jobs.BackupTarget{{Bucket: "catalog-public", Path: pathA, Digest: digest, ByteCount: 8}}, NextCursor: pathA},
		{Items: []jobs.BackupTarget{{Bucket: "catalog-public", Path: pathB, Digest: digest, ByteCount: 8}}},
	}}
	processor, err := jobs.NewBackupVerificationProcessor(store, fakeImmutableDownloader{failedPath: pathB}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	job, err := jobs.DecodeBackupVerificationJob(strings.NewReader(`{"schema_version":1,"run_id":"55555555-5555-4555-8555-555555555555","scheduled_for":"2030-01-02T03:04:05Z"}`), 4096)
	if err != nil {
		t.Fatal(err)
	}
	result := processor.Process(context.Background(), job, jobs.Lease{})
	if result.Action != jobs.ActionAck || !store.completed || store.checked != 2 || store.mismatches != 1 || len(store.digest) != 64 {
		t.Fatalf("result=%#v store=%#v", result, store)
	}
}

type fakeAccountDeletionStore struct {
	disposition string
	completed   bool
	failed      string
}

func (store *fakeAccountDeletionStore) BeginAccountDeletion(context.Context, jobs.AccountDeletionJob, jobs.Lease) (string, error) {
	return store.disposition, nil
}
func (store *fakeAccountDeletionStore) CompleteAccountDeletion(context.Context, jobs.AccountDeletionJob, jobs.Lease) (bool, error) {
	store.completed = true
	return true, nil
}
func (store *fakeAccountDeletionStore) FailAccountDeletion(_ context.Context, _ jobs.AccountDeletionJob, _ jobs.Lease, code string) (bool, error) {
	store.failed = code
	return true, nil
}

func TestAccountDeletionProcessorWaitsForCleanupAndCompletesOnlyReadyLease(t *testing.T) {
	job, err := jobs.DecodeAccountDeletionJob(strings.NewReader(`{"schema_version":1,"deletion_id":"66666666-6666-4666-8666-666666666666","user_id":"77777777-7777-4777-8777-777777777777"}`), 4096)
	if err != nil {
		t.Fatal(err)
	}
	store := &fakeAccountDeletionStore{disposition: "cleanup_pending"}
	processor, _ := jobs.NewAccountDeletionProcessor(store)
	if result := processor.Process(context.Background(), job, jobs.Lease{}); result.Action != jobs.ActionNack || store.completed {
		t.Fatalf("pending result=%#v", result)
	}
	store.disposition = "ready"
	if result := processor.Process(context.Background(), job, jobs.Lease{}); result.Action != jobs.ActionAck || !store.completed {
		t.Fatalf("ready result=%#v", result)
	}
	if _, err := jobs.DecodeAccountDeletionJob(strings.NewReader(`{"schema_version":1,"deletion_id":"66666666-6666-4666-8666-666666666666","user_id":"77777777-7777-4777-8777-777777777777","path":"/tmp"}`), 4096); err == nil {
		t.Fatal("caller-controlled deletion path accepted")
	}
}

func validSandboxSpec() sandbox.Spec {
	return sandbox.Spec{Mode: sandbox.ModeProcess, AttemptID: "11111111-1111-4111-8111-111111111111", SubmissionID: "22222222-2222-4222-8222-222222222222", Generation: 3, InputDigest: strings.Repeat("c", 64), Image: "localhost/wali-media@sha256:" + strings.Repeat("a", 64), InputDirectory: "/var/lib/wali/attempts/111/input", OutputDirectory: "/var/lib/wali/attempts/111/output", PolicyDigest: strings.Repeat("b", 64), Limits: sandbox.Limits{CPUs: "2", Memory: "4g", PIDs: 64, TmpfsBytes: 1 << 30}}
}
func TestSandboxArgsAreFixedNetworklessAndInjectionSafe(t *testing.T) {
	args, err := sandbox.BuildPodmanArgs(validSandboxSpec())
	if err != nil {
		t.Fatal(err)
	}
	prefix := []string{"run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges"}
	if !reflect.DeepEqual(args[:len(prefix)], prefix) {
		t.Fatalf("prefix=%#v", args[:len(prefix)])
	}
	for _, edit := range []func(*sandbox.Spec){func(value *sandbox.Spec) { value.Image = "wali:latest" }, func(value *sandbox.Spec) { value.InputDirectory = "/tmp/x,ro=false" }, func(value *sandbox.Spec) { value.AttemptID = "--privileged" }} {
		value := validSandboxSpec()
		edit(&value)
		if _, err := sandbox.BuildPodmanArgs(value); err == nil {
			t.Fatal("sandbox injection was accepted")
		}
	}
}

type recordingExecutor struct {
	path string
	args []string
	err  error
}

func (executor *recordingExecutor) Run(_ context.Context, path string, args ...string) error {
	executor.path = path
	executor.args = append([]string(nil), args...)
	return executor.err
}
func TestSandboxRunnerUsesAbsolutePodmanAndSurfacesCrash(t *testing.T) {
	executor := &recordingExecutor{err: errors.New("exit 125")}
	runner, err := sandbox.NewRunner("/usr/bin/podman", executor)
	if err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(context.Background(), validSandboxSpec()); !errors.Is(err, sandbox.ErrRuntimeFailed) || executor.path != "/usr/bin/podman" {
		t.Fatalf("path=%q err=%v", executor.path, err)
	}
}

func validEnvironmentTest(role, sslMode string) map[string]string {
	now := time.Now()
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"role":"%s","worker_id":"worker-1","aud":"authenticated","iat":%d,"exp":%d}`, role, now.Add(-time.Minute).Unix(), now.Add(2*time.Hour).Unix())))
	return map[string]string{
		"WALI_DATABASE_URL": "postgresql://worker:secret@db.example.test:5432/postgres?sslmode=" + sslMode,
		"WALI_STORAGE_URL":  "https://project.supabase.co", "WALI_STORAGE_PUBLISHABLE_KEY": "sb_publishable_test",
		"WALI_STORAGE_WORKER_TOKEN": header + "." + payload + ".0123456789abcdef0123456789abcdef",
		"WALI_WORKER_ID":            "worker-1", "WALI_QUEUE_NAME": "wali_media_processing", "WALI_SCRATCH_ROOT": "/var/lib/wali/attempts",
		"WALI_PODMAN_PATH": "/usr/bin/podman", "WALI_MEDIA_IMAGE": "registry.example.test/wali/media@sha256:" + strings.Repeat("a", 64),
		"WALI_VERIFIER_IMAGE": "registry.example.test/wali/media@sha256:" + strings.Repeat("b", 64), "WALI_MEDIA_POLICY_DIGEST": strings.Repeat("c", 64),
		"WALI_HEALTH_SOCKET": "/run/wali-media-worker/health.sock",
	}
}

func TestConfigurationBoundaryRejectsPrivilegeTLSMutableImagesAndBroadSockets(t *testing.T) {
	valid := validEnvironmentTest("wali_storage_worker", "verify-full")
	if _, err := config.Load(func(key string) string { return valid[key] }); err != nil {
		t.Fatal(err)
	}
	for name, environment := range map[string]map[string]string{
		"service role":            validEnvironmentTest("service_role", "verify-full"),
		"plaintext database":      validEnvironmentTest("wali_storage_worker", "disable"),
		"no-login database role":  validEnvironmentTest("wali_storage_worker", "verify-full"),
		"missing publishable key": validEnvironmentTest("wali_storage_worker", "verify-full"),
		"mutable image":           validEnvironmentTest("wali_storage_worker", "verify-full"),
		"broad socket":            validEnvironmentTest("wali_storage_worker", "verify-full"),
	} {
		switch name {
		case "no-login database role":
			environment["WALI_DATABASE_URL"] = "postgresql://wali_worker:secret@db.example.test:5432/postgres?sslmode=verify-full"
		case "missing publishable key":
			delete(environment, "WALI_STORAGE_PUBLISHABLE_KEY")
		case "mutable image":
			environment["WALI_MEDIA_IMAGE"] = "registry.example.test/wali/media:latest"
		case "broad socket":
			environment["WALI_HEALTH_SOCKET"] = "/health.sock"
		}
		if _, err := config.Load(func(key string) string { return environment[key] }); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

type databaseRoleRow struct {
	currentUser, sessionUser        string
	loginRestricted, roleRestricted bool
	err                             error
}

func (row databaseRoleRow) Scan(destinations ...any) error {
	if row.err != nil {
		return row.err
	}
	if len(destinations) != 4 {
		return errors.New("unexpected scan arity")
	}
	*(destinations[0].(*string)) = row.currentUser
	*(destinations[1].(*string)) = row.sessionUser
	*(destinations[2].(*bool)) = row.loginRestricted
	*(destinations[3].(*bool)) = row.roleRestricted
	return nil
}

type databaseRoleSession struct {
	execSQL, querySQL string
	execErr           error
	row               databaseRoleRow
}

func (session *databaseRoleSession) Exec(_ context.Context, sql string, arguments ...any) (pgconn.CommandTag, error) {
	session.execSQL = sql
	if len(arguments) != 0 {
		return pgconn.CommandTag{}, errors.New("unexpected role arguments")
	}
	return pgconn.NewCommandTag("SET"), session.execErr
}

func (session *databaseRoleSession) QueryRow(_ context.Context, sql string, arguments ...any) pgx.Row {
	session.querySQL = sql
	if len(arguments) != 0 {
		return databaseRoleRow{err: errors.New("unexpected identity arguments")}
	}
	return session.row
}

func TestWorkerDatabaseRoleActivationIsFixedAndVerified(t *testing.T) {
	session := &databaseRoleSession{row: databaseRoleRow{currentUser: "wali_worker", sessionUser: "wali_worker_runtime", loginRestricted: true, roleRestricted: true}}
	if err := queue.ActivateWorkerDatabaseRole(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	expectedQuery := "select current_user::text, session_user::text, " +
		"coalesce((select rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb and not rolcreaterole and not rolreplication and not rolbypassrls from pg_catalog.pg_roles where rolname = session_user), false), " +
		"coalesce((select not rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb and not rolcreaterole and not rolreplication and not rolbypassrls from pg_catalog.pg_roles where rolname = current_user), false)"
	if session.execSQL != "set role wali_worker" || session.querySQL != expectedQuery {
		t.Fatalf("unexpected fixed SQL: exec=%q query=%q", session.execSQL, session.querySQL)
	}

	for name, invalid := range map[string]*databaseRoleSession{
		"set role denied":       {execErr: errors.New("permission denied")},
		"wrong current role":    {row: databaseRoleRow{currentUser: "wali_worker_runtime", sessionUser: "wali_worker_runtime", loginRestricted: true, roleRestricted: true}},
		"no separate login":     {row: databaseRoleRow{currentUser: "wali_worker", sessionUser: "wali_worker", loginRestricted: true, roleRestricted: true}},
		"privileged login":      {row: databaseRoleRow{currentUser: "wali_worker", sessionUser: "wali_worker_runtime", roleRestricted: true}},
		"privileged group role": {row: databaseRoleRow{currentUser: "wali_worker", sessionUser: "wali_worker_runtime", loginRestricted: true}},
		"identity read failed":  {row: databaseRoleRow{err: errors.New("connection lost")}},
	} {
		if err := queue.ActivateWorkerDatabaseRole(context.Background(), invalid); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

func TestClaimBoundaryRejectsUnknownTrailingPathsAndVerifierMismatch(t *testing.T) {
	output := t.TempDir()
	spec := sandbox.Spec{Mode: sandbox.ModeProcess, OutputDirectory: output}
	if err := (fakeSandbox{}).Run(context.Background(), spec); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(output, "media-claim.json"))
	if err != nil {
		t.Fatal(err)
	}
	decoder := claims.NewDecoder(1 << 20)
	expectation := claims.Expectation{AttemptID: "11111111-1111-4111-8111-111111111111", SubmissionID: "22222222-2222-4222-8222-222222222222", Generation: 3, PolicyDigest: strings.Repeat("b", 64), InputDigest: digest([]byte("opaque")), Roles: []string{"thumbnail", "poster", "preview", "video_default"}, SampleFrames: 7}
	media, err := decoder.DecodeMedia(bytes.NewReader(data), expectation)
	if err != nil {
		t.Fatal(err)
	}
	verification := bytes.Replace(data, []byte(`"kind":"media"`), []byte(`"kind":"verification"`), 1)
	if _, err := decoder.DecodeVerification(bytes.NewReader(verification), media); err != nil {
		t.Fatal(err)
	}
	for name, invalid := range map[string][]byte{
		"unknown":        bytes.Replace(data, []byte(`"safe_code":"ok"`), []byte(`"safe_code":"ok","command":"x"`), 1),
		"trailing":       append(append([]byte(nil), data...), []byte(` {}`)...),
		"traversal":      bytes.Replace(data, []byte("artifacts/thumbnail.jpg"), []byte("../thumbnail.jpg"), 1),
		"duplicate role": bytes.Replace(data, []byte(`"role":"thumbnail"`), []byte(`"role":"poster"`), 1),
	} {
		if _, err := decoder.DecodeMedia(bytes.NewReader(invalid), expectation); err == nil {
			t.Fatalf("%s claim accepted", name)
		}
	}
	failure := `{"schema_version":1,"attempt_id":"11111111-1111-4111-8111-111111111111","submission_id":"22222222-2222-4222-8222-222222222222","generation":3,"safe_code":"invalid_container"}`
	if _, err := decoder.DecodeFailure(strings.NewReader(failure), claims.FailureExpectation{AttemptID: expectation.AttemptID, SubmissionID: expectation.SubmissionID, Generation: 3, SafeCodes: []string{"invalid_container"}}); err != nil {
		t.Fatal(err)
	}
}

type readinessTest func(context.Context) error

func (function readinessTest) Ready(ctx context.Context) error { return function(ctx) }

func TestHealthBoundaryIsAggregatePrivateAndUnixOnly(t *testing.T) {
	metrics := health.NewMetrics()
	metrics.Record("ok", time.Millisecond)
	handler, err := health.NewHandler(metrics, readinessTest(func(context.Context) error { return nil }))
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "http://unix/metrics", nil))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "wali_worker_jobs_total 1") || strings.Contains(response.Body.String(), "attempt_id") {
		t.Fatalf("unsafe metrics: %q", response.Body.String())
	}
	directory, err := os.MkdirTemp("/tmp", "wali-health.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	path := filepath.Join(directory, "health.sock")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- health.ServeUnix(ctx, path, handler) }()
	for deadline := time.Now().Add(time.Second); ; {
		info, statErr := os.Stat(path)
		if statErr == nil {
			if info.Mode().Perm() != 0o600 {
				t.Fatalf("mode=%o", info.Mode().Perm())
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("socket unavailable")
		}
		time.Sleep(time.Millisecond)
	}
	client := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", path)
	}}}
	got, err := client.Get("http://unix/healthz")
	if err != nil || got.StatusCode != http.StatusOK {
		t.Fatalf("response=%v err=%v", got, err)
	}
	_ = got.Body.Close()
	cancel()
	<-done
	failing, _ := health.NewHandler(health.NewMetrics(), readinessTest(func(context.Context) error { return errors.New("secret database error") }))
	response = httptest.NewRecorder()
	failing.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "http://unix/healthz", nil))
	if response.Code != http.StatusServiceUnavailable || strings.Contains(response.Body.String(), "secret") {
		t.Fatal("readiness detail leaked")
	}
}

type queueBackendTest struct {
	message                 queue.Message
	found                   bool
	readErr                 error
	acked, nacked, rejected int
}

func (backend *queueBackendTest) Read(context.Context, string, time.Duration) (queue.Message, bool, error) {
	return backend.message, backend.found, backend.readErr
}
func (backend *queueBackendTest) Ack(context.Context, string, int64) error {
	backend.acked++
	return nil
}
func (backend *queueBackendTest) Nack(context.Context, string, int64, time.Duration) error {
	backend.nacked++
	return nil
}
func (backend *queueBackendTest) Reject(context.Context, string, int64, string) error {
	backend.rejected++
	return nil
}

type queueHandlerTest struct {
	result jobs.Result
	called int
}

func (handler *queueHandlerTest) Process(context.Context, jobs.ProcessSubmission, jobs.Lease) jobs.Result {
	handler.called++
	return handler.result
}

func TestQueueBoundaryMapsDecisionsAndRejectsMalformedInput(t *testing.T) {
	for _, action := range []jobs.Action{jobs.ActionAck, jobs.ActionNack, jobs.ActionLeave} {
		backend := &queueBackendTest{found: true, message: queue.Message{ID: 9, Body: []byte(validJobJSON()), VisibleUntil: time.Now().Add(time.Minute)}}
		handler := &queueHandlerTest{result: jobs.Result{Action: action}}
		consumer, err := queue.NewConsumer(backend, handler, "wali_media_processing", "worker-1", time.Minute, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if processed, err := consumer.RunOnce(context.Background()); err != nil || !processed || handler.called != 1 {
			t.Fatalf("action=%v processed=%v err=%v", action, processed, err)
		}
		if action == jobs.ActionAck && backend.acked != 1 || action == jobs.ActionNack && backend.nacked != 1 || action == jobs.ActionLeave && backend.acked+backend.nacked != 0 {
			t.Fatalf("wrong mutation for %v", action)
		}
	}
	backend := &queueBackendTest{found: true, message: queue.Message{ID: 10, Body: []byte(`{"schema_version":99}`)}}
	handler := &queueHandlerTest{}
	consumer, _ := queue.NewConsumer(backend, handler, "wali_media_processing", "worker-1", time.Minute, time.Second)
	_, _ = consumer.RunOnce(context.Background())
	if backend.rejected != 1 || handler.called != 0 {
		t.Fatal("malformed envelope reached processor")
	}
	backend = &queueBackendTest{readErr: errors.New("database unavailable")}
	consumer, _ = queue.NewConsumer(backend, handler, "wali_media_processing", "worker-1", time.Minute, time.Second)
	if _, err := consumer.RunOnce(context.Background()); err == nil || backend.acked+backend.nacked+backend.rejected != 0 {
		t.Fatal("read failure mutated queue")
	}
}
