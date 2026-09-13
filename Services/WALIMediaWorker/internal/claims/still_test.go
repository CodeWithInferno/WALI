package claims

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func stillFixture() MediaClaim {
	digest := strings.Repeat("a", 64)
	artifacts := []ArtifactClaim{
		{Role: "thumbnail", RelativePath: "artifacts/thumbnail.jpg", Digest: digest, ByteCount: 100, MediaType: "image/jpeg", Width: 512, Height: 512, FrameRateDenominator: 1, Codec: "mjpeg", PixelFormat: "yuvj420p", ColorSpace: "bt470bg"},
		{Role: "poster", RelativePath: "artifacts/poster.jpg", Digest: digest, ByteCount: 200, MediaType: "image/jpeg", Width: 960, Height: 1920, FrameRateDenominator: 1, Codec: "mjpeg", PixelFormat: "yuvj420p", ColorSpace: "bt470bg"},
		{Role: "image_default", RelativePath: "artifacts/image-default.png", Digest: digest, ByteCount: 300, MediaType: "image/png", Width: 2160, Height: 4320, FrameRateDenominator: 1, Codec: "png", PixelFormat: "rgb24", ColorSpace: "srgb"},
	}
	return MediaClaim{SchemaVersion: 2, MediaKind: "still", Kind: "media", AttemptID: "attempt-1", SubmissionID: "submission-1", Generation: 1, PolicyDigest: digest, InputDigest: digest, Artifacts: artifacts, SampleFrames: []FrameClaim{{Ordinal: 1, RelativePath: "frames/frame-001.jpg", Digest: digest, ByteCount: 100, Width: 384, Height: 224}}, EncoderBuild: "ffmpeg-7.1.2-still-v1", SafeCode: "ok"}
}
func stillExpectation() Expectation {
	return Expectation{SchemaVersion: 2, MediaKind: "still", AttemptID: "attempt-1", SubmissionID: "submission-1", Generation: 1, Roles: []string{"thumbnail", "poster", "image_default"}, SampleFrames: 1}
}
func encodeStill(t *testing.T, value MediaClaim) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func TestStillClaimRequiresExplicitVersionAndKindExpectation(t *testing.T) {
	data := encodeStill(t, stillFixture())
	if _, err := NewDecoder(0).DecodeMedia(bytes.NewReader(data), stillExpectation()); err != nil {
		t.Fatal(err)
	}
	if _, err := NewDecoder(0).DecodeMedia(bytes.NewReader(data), Expectation{}); err == nil {
		t.Fatal("legacy caller accepted still claim")
	}
}
func TestStillClaimRejectsMixedRolesTimingAndSamples(t *testing.T) {
	cases := map[string]func(*MediaClaim){
		"video role":         func(c *MediaClaim) { c.Artifacts[2].Role = "video_default" },
		"extra image":        func(c *MediaClaim) { c.Artifacts = append(c.Artifacts, c.Artifacts[2]) },
		"duration":           func(c *MediaClaim) { c.Artifacts[2].DurationMS = 1 },
		"frame rate":         func(c *MediaClaim) { c.Artifacts[2].FrameRateNumerator = 1 },
		"alpha pixel format": func(c *MediaClaim) { c.Artifacts[2].PixelFormat = "rgba" },
		"wrong color":        func(c *MediaClaim) { c.Artifacts[2].ColorSpace = "bt2020nc" },
		"duplicate samples":  func(c *MediaClaim) { c.SampleFrames = append(c.SampleFrames, c.SampleFrames[0]) },
		"oversized pixels":   func(c *MediaClaim) { c.Artifacts[2].Width = 7680; c.Artifacts[2].Height = 7680 },
		"oversized bytes":    func(c *MediaClaim) { c.Artifacts[2].ByteCount = 128<<20 + 1 },
		"wrong filename":     func(c *MediaClaim) { c.Artifacts[2].RelativePath = "artifacts/source.png" },
		"wrong kind":         func(c *MediaClaim) { c.MediaKind = "video" },
		"wrong version":      func(c *MediaClaim) { c.SchemaVersion = 1 },
	}
	for name, edit := range cases {
		t.Run(name, func(t *testing.T) {
			c := stillFixture()
			edit(&c)
			if _, err := NewDecoder(0).DecodeMedia(bytes.NewReader(encodeStill(t, c)), stillExpectation()); err == nil {
				t.Fatal("invalid still claim accepted")
			}
		})
	}
}
func TestStillVerificationBindsKindAndEncoderToOriginalClaim(t *testing.T) {
	media := stillFixture()
	verified := stillFixture()
	verified.Kind = "verification"
	if _, err := NewDecoder(0).DecodeVerification(bytes.NewReader(encodeStill(t, verified)), media); err != nil {
		t.Fatal(err)
	}
	verified.EncoderBuild = "different-encoder"
	if _, err := NewDecoder(0).DecodeVerification(bytes.NewReader(encodeStill(t, verified)), media); err == nil {
		t.Fatal("verification changed provenance")
	}
}
func TestStillClaimRejectsMissingAndDuplicateJSONFields(t *testing.T) {
	data := encodeStill(t, stillFixture())
	duplicate := bytes.Replace(data, []byte(`"media_kind":"still"`), []byte(`"media_kind":"video","media_kind":"still"`), 1)
	missing := bytes.Replace(data, []byte(`"duration_ms":0,`), nil, 1)
	for _, invalid := range [][]byte{duplicate, missing} {
		if _, err := NewDecoder(0).DecodeMedia(bytes.NewReader(invalid), stillExpectation()); err == nil {
			t.Fatal("ambiguous or incomplete claim accepted")
		}
	}
}
