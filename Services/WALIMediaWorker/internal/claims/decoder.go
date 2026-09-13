package claims

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"slices"
	"strings"
)

const (
	SchemaVersion        = 1
	StillSchemaVersion   = 2
	maximumArtifacts     = 7
	maximumArtifactBytes = int64(2 << 30)
	maximumDurationMS    = int64(10 * 60 * 1000)
	maximumWidth         = 7680
	maximumHeight        = 4320
	maximumFrameRate     = 120
	requiredSampleFrames = 7
)

var (
	digestPattern     = regexp.MustCompile(`^[a-f0-9]{64}$`)
	identifierPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	roleSet           = map[string]struct{}{
		"thumbnail": {}, "poster": {}, "preview": {}, "video_1080p": {},
		"video_1440p": {}, "video_2160p": {}, "video_default": {},
	}
)

type Decoder struct {
	maxBytes int64
}

type Expectation struct {
	SchemaVersion uint16
	MediaKind     string
	AttemptID     string
	SubmissionID  string
	Generation    uint32
	PolicyDigest  string
	InputDigest   string
	Roles         []string
	SampleFrames  int
}

type FailureExpectation struct {
	AttemptID    string
	SubmissionID string
	Generation   uint32
	SafeCodes    []string
}

type FailureClaim struct {
	SchemaVersion uint16 `json:"schema_version"`
	AttemptID     string `json:"attempt_id"`
	SubmissionID  string `json:"submission_id"`
	Generation    uint32 `json:"generation"`
	SafeCode      string `json:"safe_code"`
}

type MediaClaim struct {
	MediaKind     string          `json:"media_kind,omitempty"`
	SchemaVersion uint16          `json:"schema_version"`
	Kind          string          `json:"kind"`
	AttemptID     string          `json:"attempt_id"`
	SubmissionID  string          `json:"submission_id"`
	Generation    uint32          `json:"generation"`
	PolicyDigest  string          `json:"policy_digest"`
	InputDigest   string          `json:"input_digest"`
	Artifacts     []ArtifactClaim `json:"artifacts"`
	SampleFrames  []FrameClaim    `json:"sample_frames"`
	EncoderBuild  string          `json:"encoder_build"`
	SafeCode      string          `json:"safe_code"`
}

type ArtifactClaim struct {
	Role                 string `json:"role"`
	RelativePath         string `json:"relative_path"`
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

type FrameClaim struct {
	Ordinal      int    `json:"ordinal"`
	RelativePath string `json:"relative_path"`
	Digest       string `json:"digest"`
	ByteCount    int64  `json:"byte_count"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
}

func NewDecoder(maxBytes int64) Decoder {
	if maxBytes <= 0 {
		maxBytes = 1 << 20
	}
	return Decoder{maxBytes: maxBytes}
}

func (d Decoder) DecodeMedia(reader io.Reader, expected Expectation) (MediaClaim, error) {
	claim, err := d.decode(reader)
	if err != nil {
		return MediaClaim{}, err
	}
	if claim.Kind != "media" {
		return MediaClaim{}, fmt.Errorf("kind must be media")
	}
	if err := validateClaim(claim, expected); err != nil {
		return MediaClaim{}, err
	}
	return claim, nil
}

func (d Decoder) DecodeVerification(reader io.Reader, media MediaClaim) (MediaClaim, error) {
	claim, err := d.decode(reader)
	if err != nil {
		return MediaClaim{}, err
	}
	if claim.Kind != "verification" {
		return MediaClaim{}, fmt.Errorf("kind must be verification")
	}
	expected := Expectation{
		SchemaVersion: media.SchemaVersion, MediaKind: media.MediaKind,
		AttemptID: media.AttemptID, SubmissionID: media.SubmissionID,
		Generation: media.Generation, PolicyDigest: media.PolicyDigest,
		InputDigest: media.InputDigest, Roles: artifactRoles(media.Artifacts),
		SampleFrames: len(media.SampleFrames),
	}
	if err := validateClaim(claim, expected); err != nil {
		return MediaClaim{}, err
	}
	if claim.EncoderBuild != media.EncoderBuild || !slices.Equal(claim.Artifacts, media.Artifacts) || !slices.Equal(claim.SampleFrames, media.SampleFrames) {
		return MediaClaim{}, errors.New("verification claim does not match media claim")
	}
	return claim, nil
}

func (d Decoder) DecodeFailure(reader io.Reader, expected FailureExpectation) (FailureClaim, error) {
	limited := io.LimitReader(reader, d.maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return FailureClaim{}, fmt.Errorf("read failure claim: %w", err)
	}
	if int64(len(data)) > d.maxBytes {
		return FailureClaim{}, fmt.Errorf("failure claim too large: limit is %d bytes", d.maxBytes)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var claim FailureClaim
	if err := decoder.Decode(&claim); err != nil {
		return FailureClaim{}, fmt.Errorf("decode failure claim: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return FailureClaim{}, errors.New("failure claim contains trailing JSON data")
	}
	if claim.SchemaVersion != SchemaVersion || claim.Generation == 0 ||
		!identifierPattern.MatchString(claim.AttemptID) || !identifierPattern.MatchString(claim.SubmissionID) ||
		!identifierPattern.MatchString(claim.SafeCode) {
		return FailureClaim{}, errors.New("failure claim contains invalid bounded fields")
	}
	if claim.AttemptID != expected.AttemptID || claim.SubmissionID != expected.SubmissionID || claim.Generation != expected.Generation {
		return FailureClaim{}, errors.New("failure claim does not match the active attempt")
	}
	if !slices.Contains(expected.SafeCodes, claim.SafeCode) {
		return FailureClaim{}, errors.New("failure claim safe_code is not allowed for this stage")
	}
	return claim, nil
}

func (d Decoder) decode(reader io.Reader) (MediaClaim, error) {
	limited := io.LimitReader(reader, d.maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return MediaClaim{}, fmt.Errorf("read claim: %w", err)
	}
	if int64(len(data)) > d.maxBytes {
		return MediaClaim{}, fmt.Errorf("claim too large: limit is %d bytes", d.maxBytes)
	}
	if err := validateMediaJSON(data); err != nil {
		return MediaClaim{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var claim MediaClaim
	if err := decoder.Decode(&claim); err != nil {
		return MediaClaim{}, fmt.Errorf("decode claim: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return MediaClaim{}, errors.New("trailing JSON data")
		}
		return MediaClaim{}, fmt.Errorf("trailing JSON data: %w", err)
	}
	return claim, nil
}

func validateClaim(claim MediaClaim, expected Expectation) error {
	schema := expected.SchemaVersion
	if schema == 0 {
		schema = SchemaVersion
	}
	if claim.SchemaVersion != schema || (schema != SchemaVersion && schema != StillSchemaVersion) {
		return fmt.Errorf("unsupported or unexpected schema_version %d", claim.SchemaVersion)
	}
	isStill := schema == StillSchemaVersion
	if (isStill && (claim.MediaKind != "still" || expected.MediaKind != "still")) ||
		(!isStill && (claim.MediaKind != "" || (expected.MediaKind != "" && expected.MediaKind != "video"))) {
		return errors.New("media kind does not match the declared contract")
	}
	samples := requiredSampleFrames
	if isStill {
		samples = 1
	}
	if !identifierPattern.MatchString(claim.AttemptID) || !identifierPattern.MatchString(claim.SubmissionID) {
		return errors.New("attempt_id and submission_id must be bounded identifiers")
	}
	if claim.Generation == 0 {
		return errors.New("generation must be positive")
	}
	if !digestPattern.MatchString(claim.PolicyDigest) || !digestPattern.MatchString(claim.InputDigest) {
		return errors.New("policy_digest and input_digest must be lowercase SHA-256")
	}
	if claim.SafeCode != "ok" || !identifierPattern.MatchString(claim.EncoderBuild) {
		return errors.New("successful claim must have safe_code ok and a bounded encoder_build")
	}
	if len(claim.Artifacts) == 0 || len(claim.Artifacts) > maximumArtifacts {
		return fmt.Errorf("artifact count must be 1..%d", maximumArtifacts)
	}
	if len(claim.SampleFrames) != samples {
		return fmt.Errorf("sample frame count must be %d", samples)
	}
	if expected.SampleFrames > 0 && len(claim.SampleFrames) != expected.SampleFrames {
		return fmt.Errorf("sample frame count does not match expected %d", expected.SampleFrames)
	}
	if err := matchExpected(claim, expected); err != nil {
		return err
	}

	if isStill {
		roles := artifactRoles(claim.Artifacts)
		slices.Sort(roles)
		if !slices.Equal(roles, []string{"image_default", "poster", "thumbnail"}) {
			return errors.New("still artifacts must have the exact image role set")
		}
	}
	seenRoles := make(map[string]struct{}, len(claim.Artifacts))
	seenPaths := make(map[string]struct{}, len(claim.Artifacts)+len(claim.SampleFrames))
	for _, artifact := range claim.Artifacts {
		if _, ok := roleSet[artifact.Role]; !ok && !(isStill && artifact.Role == "image_default") {
			return fmt.Errorf("unsupported artifact role %q", artifact.Role)
		}
		if _, ok := seenRoles[artifact.Role]; ok {
			return errors.New("artifact roles must be unique and exact")
		}
		seenRoles[artifact.Role] = struct{}{}
		if err := validateRelativePath(artifact.RelativePath, "artifacts/"); err != nil {
			return fmt.Errorf("artifact relative_path: %w", err)
		}
		if _, ok := seenPaths[artifact.RelativePath]; ok {
			return errors.New("relative_path values must be unique")
		}
		seenPaths[artifact.RelativePath] = struct{}{}
		if !digestPattern.MatchString(artifact.Digest) {
			return fmt.Errorf("artifact %s digest is not lowercase SHA-256", artifact.Role)
		}
		if artifact.ByteCount <= 0 || artifact.ByteCount > maximumArtifactBytes {
			return fmt.Errorf("artifact %s byte_count is out of bounds", artifact.Role)
		}
		if artifact.Width <= 0 || artifact.Width > maximumWidth {
			return fmt.Errorf("artifact %s width is out of bounds", artifact.Role)
		}
		heightLimit := maximumHeight
		if isStill {
			heightLimit = maximumWidth
		}
		if artifact.Height <= 0 || artifact.Height > heightLimit {
			return fmt.Errorf("artifact %s height is out of bounds", artifact.Role)
		}
		if artifact.DurationMS < 0 || artifact.DurationMS > maximumDurationMS {
			return fmt.Errorf("artifact %s duration_ms is out of bounds", artifact.Role)
		}
		if artifact.FrameRateNumerator < 0 || artifact.FrameRateDenominator <= 0 ||
			artifact.FrameRateNumerator > maximumFrameRate*artifact.FrameRateDenominator {
			return fmt.Errorf("artifact %s frame rate is out of bounds", artifact.Role)
		}
		if artifact.HasAudio {
			return fmt.Errorf("artifact %s must not have audio", artifact.Role)
		}
		if isStill {
			if err := validateStillArtifact(artifact); err != nil {
				return err
			}
		}
		for field, value := range map[string]string{
			"media_type": artifact.MediaType, "codec": artifact.Codec,
			"pixel_format": artifact.PixelFormat, "color_space": artifact.ColorSpace,
		} {
			if !identifierPattern.MatchString(strings.ReplaceAll(value, "/", "_")) {
				return fmt.Errorf("artifact %s %s is not a safe token", artifact.Role, field)
			}
		}
	}

	for index, frame := range claim.SampleFrames {
		if frame.Ordinal != index+1 {
			return errors.New("sample frame ordinals must be contiguous from one")
		}
		if err := validateRelativePath(frame.RelativePath, "frames/"); err != nil {
			return fmt.Errorf("frame relative_path: %w", err)
		}
		if _, ok := seenPaths[frame.RelativePath]; ok {
			return errors.New("relative_path values must be unique")
		}
		seenPaths[frame.RelativePath] = struct{}{}
		if !digestPattern.MatchString(frame.Digest) || frame.ByteCount <= 0 || frame.ByteCount > 16<<20 {
			return fmt.Errorf("sample frame %d digest or byte_count is invalid", frame.Ordinal)
		}
		if isStill && (frame.RelativePath != "frames/frame-001.jpg" || frame.Width != 384 || frame.Height != 224) {
			return errors.New("still classifier sample must have the canonical path and dimensions")
		}
		if frame.Width <= 0 || frame.Width > 1024 || frame.Height <= 0 || frame.Height > 1024 {
			return fmt.Errorf("sample frame %d dimensions are invalid", frame.Ordinal)
		}
	}
	return nil
}

func matchExpected(claim MediaClaim, expected Expectation) error {
	checks := []struct{ name, actual, wanted string }{
		{"attempt_id", claim.AttemptID, expected.AttemptID},
		{"submission_id", claim.SubmissionID, expected.SubmissionID},
		{"policy_digest", claim.PolicyDigest, expected.PolicyDigest},
		{"input_digest", claim.InputDigest, expected.InputDigest},
	}
	for _, check := range checks {
		if check.wanted != "" && check.actual != check.wanted {
			return fmt.Errorf("%s does not match expected value", check.name)
		}
	}
	if expected.Generation != 0 && claim.Generation != expected.Generation {
		return errors.New("generation does not match expected value")
	}
	if len(expected.Roles) > 0 {
		actual := artifactRoles(claim.Artifacts)
		wanted := append([]string(nil), expected.Roles...)
		slices.Sort(actual)
		slices.Sort(wanted)
		if !slices.Equal(actual, wanted) {
			return errors.New("artifact roles do not match expected roles")
		}
	}
	return nil
}

func artifactRoles(artifacts []ArtifactClaim) []string {
	roles := make([]string, len(artifacts))
	for index, artifact := range artifacts {
		roles[index] = artifact.Role
	}
	return roles
}

func validateRelativePath(value, prefix string) error {
	if value == "" || path.IsAbs(value) || path.Clean(value) != value || !strings.HasPrefix(value, prefix) {
		return errors.New("must be a clean project-owned relative path")
	}
	if strings.ContainsAny(value, `\,:`+"\x00\r\n") || strings.Contains(value, "../") {
		return errors.New("contains a reserved character or traversal")
	}
	return nil
}

func validateStillArtifact(a ArtifactClaim) error {
	if a.DurationMS != 0 || a.FrameRateNumerator != 0 || a.FrameRateDenominator != 1 ||
		a.Width*a.Height > 7680*4320 {
		return errors.New("still artifact contains motion or oversized raster metadata")
	}
	if a.Role == "image_default" {
		if a.RelativePath != "artifacts/image-default.png" || a.MediaType != "image/png" ||
			a.Codec != "png" || a.PixelFormat != "rgb24" || a.ColorSpace != "srgb" || a.ByteCount > 128<<20 {
			return errors.New("still master is not canonical opaque sRGB PNG")
		}
		return nil
	}
	if a.RelativePath != "artifacts/"+a.Role+".jpg" || a.MediaType != "image/jpeg" ||
		a.Codec != "mjpeg" || a.PixelFormat != "yuvj420p" || a.ColorSpace != "bt470bg" || a.ByteCount > 16<<20 {
		return errors.New("still derivative is not canonical JPEG")
	}
	if a.Role == "thumbnail" && (a.Width != 512 || a.Height != 512) {
		return errors.New("still thumbnail must be 512 square")
	}
	if a.Role == "poster" && (a.Width > 1920 || a.Height > 1920) {
		return errors.New("still poster exceeds the preview bounds")
	}
	return nil
}

func validateMediaJSON(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := rejectDuplicateJSON(decoder, 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("trailing claim data")
	}
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil {
		return errors.New("claim must be an object")
	}
	var version uint16
	if json.Unmarshal(object["schema_version"], &version) != nil {
		return errors.New("invalid claim version")
	}
	keys := []string{"schema_version", "kind", "attempt_id", "submission_id", "generation", "policy_digest", "input_digest", "artifacts", "sample_frames", "encoder_build", "safe_code"}
	if version == StillSchemaVersion {
		keys = append(keys, "media_kind")
	}
	if !exactKeys(object, keys) {
		return errors.New("claim keys do not match its version")
	}
	for field, keys := range map[string][]string{
		"artifacts":     {"role", "relative_path", "digest", "byte_count", "media_type", "width", "height", "duration_ms", "frame_rate_numerator", "frame_rate_denominator", "codec", "pixel_format", "color_space", "has_audio"},
		"sample_frames": {"ordinal", "relative_path", "digest", "byte_count", "width", "height"},
	} {
		var records []map[string]json.RawMessage
		if json.Unmarshal(object[field], &records) != nil {
			return errors.New("invalid claim collection")
		}
		for _, record := range records {
			if !exactKeys(record, keys) {
				return errors.New("incomplete claim record")
			}
		}
	}
	return nil
}
func exactKeys(object map[string]json.RawMessage, keys []string) bool {
	if len(object) != len(keys) {
		return false
	}
	for _, key := range keys {
		if value, ok := object[key]; !ok || bytes.Equal(value, []byte("null")) {
			return false
		}
	}
	return true
}
func rejectDuplicateJSON(decoder *json.Decoder, depth int) error {
	if depth > 16 {
		return errors.New("claim nesting exceeds bound")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			raw, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := raw.(string)
			if !ok || seen[key] {
				return errors.New("duplicate claim key")
			}
			seen[key] = true
			if err := rejectDuplicateJSON(decoder, depth+1); err != nil {
				return err
			}
		}
		if end, err := decoder.Token(); err != nil || end != json.Delim('}') {
			return errors.New("invalid claim object")
		}
	case '[':
		for decoder.More() {
			if err := rejectDuplicateJSON(decoder, depth+1); err != nil {
				return err
			}
		}
		if end, err := decoder.Token(); err != nil || end != json.Delim(']') {
			return errors.New("invalid claim array")
		}
	default:
		return errors.New("invalid claim delimiter")
	}
	return nil
}
