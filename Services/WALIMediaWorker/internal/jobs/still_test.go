package jobs_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/claims"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
)

func stillJobJSON() string {
	return strings.Replace(strings.Replace(validJobJSON(), `"schema_version":1`, `"schema_version":2,"media_kind":"still"`, 1), `"thumbnail","poster","preview","video_default"`, `"thumbnail","poster","image_default"`, 1)
}
func TestStillJobRequiresVersionKindExactRolesAndBounds(t *testing.T) {
	if _, err := jobs.DecodeProcessSubmission(strings.NewReader(stillJobJSON()), 16<<10); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"legacy with kind": strings.Replace(stillJobJSON(), `"schema_version":2`, `"schema_version":1`, 1),
		"missing kind":     strings.Replace(stillJobJSON(), `,"media_kind":"still"`, "", 1),
		"wrong kind":       strings.Replace(stillJobJSON(), `"media_kind":"still"`, `"media_kind":"video"`, 1),
		"video role":       strings.Replace(stillJobJSON(), `"image_default"`, `"video_default"`, 1),
		"excess size":      strings.Replace(stillJobJSON(), `"byte_count":6`, `"byte_count":134217729`, 1),
		"unknown kind":     strings.Replace(stillJobJSON(), `"still"`, `"animated"`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := jobs.DecodeProcessSubmission(strings.NewReader(body), 16<<10); err == nil {
				t.Fatal("invalid still job admitted")
			}
		})
	}
	if _, err := jobs.DecodeProcessSubmission(strings.NewReader(validJobJSON()), 16<<10); err != nil {
		t.Fatal("legacy video job rejected", err)
	}
}
func TestStillPromotionRequiresVersionKindAndExactThreeObjects(t *testing.T) {
	job, _ := validPromotion(t)
	data, _ := json.Marshal(job)
	var value map[string]any
	json.Unmarshal(data, &value)
	value["schema_version"] = 2
	value["media_kind"] = "still"
	artifacts := value["artifacts"].([]any)
	value["artifacts"] = artifacts[:3]
	art := artifacts[2].(map[string]any)
	art["role"] = "image_default"
	art["media_type"] = "image/png"
	for _, key := range []string{"source_path", "destination_path"} {
		path := art[key].(string)
		path = path[:strings.LastIndex(path, "/")+1] + "image-default.png"
		art[key] = path
	}
	data, _ = json.Marshal(value)
	if _, err := jobs.DecodePromotionJob(strings.NewReader(string(data)), 64<<10); err != nil {
		t.Fatal(err)
	}
	// Equal 512px poster/thumbnail bytes share one DB content-addressed path.
	first := artifacts[0].(map[string]any)
	second := artifacts[1].(map[string]any)
	first["digest"] = second["digest"]
	first["source_path"] = second["source_path"]
	first["destination_path"] = second["destination_path"]
	first["byte_count"] = second["byte_count"]
	aliasData, _ := json.Marshal(value)
	if _, err := jobs.DecodePromotionJob(strings.NewReader(string(aliasData)), 64<<10); err != nil {
		t.Fatal("same-byte still roles rejected", err)
	}
	value["schema_version"] = 1
	data, _ = json.Marshal(value)
	if _, err := jobs.DecodePromotionJob(strings.NewReader(string(data)), 64<<10); err == nil {
		t.Fatal("legacy promotion admitted still")
	}
}

type stillSandbox struct {
	calls    int
	mismatch bool
}

func (f *stillSandbox) Run(_ context.Context, spec sandbox.Spec) error {
	if spec.MediaKind != "still" {
		return fmt.Errorf("missing still routing")
	}
	f.calls++
	if spec.Mode == sandbox.ModeVerify {
		b, err := os.ReadFile(filepath.Join(spec.InputDirectory, "media-claim.json"))
		if err != nil {
			return err
		}
		b = bytes.Replace(b, []byte(`"kind":"media"`), []byte(`"kind":"verification"`), 1)
		if f.mismatch {
			b = bytes.Replace(b, []byte(`"media_kind":"still"`), []byte(`"media_kind":"video"`), 1)
		}
		return os.WriteFile(filepath.Join(spec.OutputDirectory, "verification-claim.json"), b, 0600)
	}
	c := claims.MediaClaim{SchemaVersion: 2, MediaKind: "still", Kind: "media", AttemptID: spec.AttemptID, SubmissionID: spec.SubmissionID, Generation: spec.Generation, PolicyDigest: spec.PolicyDigest, InputDigest: spec.InputDigest, EncoderBuild: "test", SafeCode: "ok"}
	for _, role := range []string{"thumbnail", "poster", "image_default"} {
		name, media, codec, pixel, color, w, h := role+".jpg", "image/jpeg", "mjpeg", "yuvj420p", "bt470bg", 512, 512
		if role == "image_default" {
			name = "image-default.png"
			media = "image/png"
			codec = "png"
			pixel = "rgb24"
			color = "srgb"
			w = 2160
			h = 4320
		}
		data := []byte(role)
		relative := "artifacts/" + name
		if err := os.MkdirAll(filepath.Join(spec.OutputDirectory, "artifacts"), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(spec.OutputDirectory, relative), data, 0600); err != nil {
			return err
		}
		c.Artifacts = append(c.Artifacts, claims.ArtifactClaim{Role: role, RelativePath: relative, Digest: digest(data), ByteCount: int64(len(data)), MediaType: media, Width: w, Height: h, FrameRateDenominator: 1, Codec: codec, PixelFormat: pixel, ColorSpace: color})
	}
	frame := []byte("frame")
	if err := os.MkdirAll(filepath.Join(spec.OutputDirectory, "frames"), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(spec.OutputDirectory, "frames/frame-001.jpg"), frame, 0600); err != nil {
		return err
	}
	c.SampleFrames = []claims.FrameClaim{{Ordinal: 1, RelativePath: "frames/frame-001.jpg", Digest: digest(frame), ByteCount: int64(len(frame)), Width: 384, Height: 224}}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(spec.OutputDirectory, "media-claim.json"), b, 0600)
}
func TestStillProcessorVerifiesThreeObjectsAndCommitsTaggedCompletion(t *testing.T) {
	for _, tc := range []struct {
		name              string
		enabled, mismatch bool
	}{{"verified", true, false}, {"disabled", false, false}, {"verification mismatch", true, true}} {
		t.Run(tc.name, func(t *testing.T) {
			attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, completeOK: true, failOK: true}
			blobs := &fakeBlobs{input: []byte("opaque")}
			runner := &stillSandbox{mismatch: tc.mismatch}
			deps := jobs.Dependencies{Attempts: attempts, Blobs: blobs, Sandbox: runner, Classifier: classifier.Noop{}, Cleanup: &fakeCleanup{}, ScratchRoot: t.TempDir(), MediaImage: "localhost/media@sha256:" + strings.Repeat("c", 64), VerifierImage: "localhost/verify@sha256:" + strings.Repeat("d", 64), PolicyDigest: strings.Repeat("a", 64), HeartbeatInterval: time.Hour}
			if tc.enabled {
				deps.StillPolicyDigest = strings.Repeat("b", 64)
			}
			p, err := jobs.NewProcessor(deps)
			if err != nil {
				t.Fatal(err)
			}
			job, err := jobs.DecodeProcessSubmission(strings.NewReader(stillJobJSON()), 16<<10)
			if err != nil {
				t.Fatal(err)
			}
			result := p.Process(context.Background(), job, jobs.Lease{MessageID: 9, Owner: "worker-1", ExpiresAt: time.Now().Add(time.Minute)})
			if !tc.enabled || tc.mismatch {
				if attempts.completed != 0 || len(blobs.published) != 0 {
					t.Fatal("unverified still published")
				}
				return
			}
			if result.Action != jobs.ActionAck || result.SafeCode != "ok" || runner.calls != 2 || len(blobs.published) != 3 || attempts.completed != 1 {
				t.Fatalf("unexpected result %+v, runs%d objects%d completions%d", result, runner.calls, len(blobs.published), attempts.completed)
			}
			if attempts.completion.SchemaVersion != 2 || attempts.completion.MediaKind != "still" || len(attempts.completion.Artifacts) != 3 {
				t.Fatal("completion lost kind binding")
			}
		})
	}
}
