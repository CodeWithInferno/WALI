package classifier

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func stillRequest() Request {
	return Request{MediaKind: "still", AttemptID: "attempt-1", SubmissionID: "submission-1", Generation: 1, Title: "Still", InputDirectory: "/work/input", OutputDirectory: "/work/output", Frames: []Frame{{Ordinal: 1, Digest: strings.Repeat("a", 64), ByteCount: 100, Width: 384, Height: 224}}}
}
func stillClaim(request Request) claim {
	vector := make([]float64, 768)
	vector[0] = 1
	return claim{SchemaVersion: 2, MediaKind: "still", AttemptID: request.AttemptID, SubmissionID: request.SubmissionID, Generation: request.Generation, Available: true, SafeCode: "ok", ModelID: ModelID, ModelRevision: ModelRevision, ModelDigest: ModelDigest, TaxonomyRevision: TaxonomyRevision, InputFrameSetDigest: frameSetDigest(request.Frames), VisualEmbedding: vector, TextEmbedding: vector, CombinedEmbedding: vector, Categories: []Score{}, Tags: []Score{}}
}
func TestStillClassifierBindsOneFrameAndVersion(t *testing.T) {
	request := stillRequest()
	if err := validateRequest(request); err != nil {
		t.Fatal(err)
	}
	value := stillClaim(request)
	encoded, _ := json.Marshal(value)
	if _, err := decodeClaim(bytes.NewReader(encoded), request); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"", "video", "animated"} {
		bad := request
		bad.MediaKind = kind
		if err := validateRequest(bad); err == nil {
			t.Fatalf("accepted one frame for %q", kind)
		}
	}
	request.Frames = append(request.Frames, request.Frames[0])
	if err := validateRequest(request); err == nil {
		t.Fatal("accepted duplicated still sample")
	}
}
func TestClassifierRejectsChangedStillKindAndClaimShape(t *testing.T) {
	request := stillRequest()
	for _, mutate := range []func(map[string]any){
		func(v map[string]any) { v["schema_version"] = 1 }, func(v map[string]any) { v["media_kind"] = "video" }, func(v map[string]any) { delete(v, "media_kind") }, func(v map[string]any) { delete(v, "categories") }, func(v map[string]any) { v["input_frame_set_digest"] = strings.Repeat("b", 64) },
	} {
		encoded, _ := json.Marshal(stillClaim(request))
		var value map[string]any
		json.Unmarshal(encoded, &value)
		mutate(value)
		encoded, _ = json.Marshal(value)
		if _, err := decodeClaim(bytes.NewReader(encoded), request); err == nil {
			t.Fatal("accepted changed claim")
		}
	}
	encoded, _ := json.Marshal(stillClaim(request))
	encoded = append([]byte(`{"media_kind":"video",`), encoded[1:]...)
	if _, err := decodeClaim(bytes.NewReader(encoded), request); err == nil {
		t.Fatal("accepted duplicate kind")
	}
}
func TestLegacyClassifierRetainsSevenFrameShape(t *testing.T) {
	request := stillRequest()
	request.MediaKind = ""
	for len(request.Frames) < 7 {
		next := request.Frames[0]
		next.Ordinal = len(request.Frames) + 1
		request.Frames = append(request.Frames, next)
	}
	if err := validateRequest(request); err != nil {
		t.Fatal(err)
	}
	value := stillClaim(request)
	value.SchemaVersion = 1
	value.MediaKind = ""
	encoded, _ := json.Marshal(value)
	if bytes.Contains(encoded, []byte("media_kind")) {
		t.Fatal("legacy emitted kind")
	}
	if _, err := decodeClaim(bytes.NewReader(encoded), request); err != nil {
		t.Fatal(err)
	}
}
