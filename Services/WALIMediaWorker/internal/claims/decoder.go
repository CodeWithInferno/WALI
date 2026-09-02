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
	AttemptID    string
	SubmissionID string
	Generation   uint32
	PolicyDigest string
	InputDigest  string
	Roles        []string
	SampleFrames int
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
		AttemptID: media.AttemptID, SubmissionID: media.SubmissionID,
		Generation: media.Generation, PolicyDigest: media.PolicyDigest,
		InputDigest: media.InputDigest, Roles: artifactRoles(media.Artifacts),
		SampleFrames: len(media.SampleFrames),
	}
	if err := validateClaim(claim, expected); err != nil {
		return MediaClaim{}, err
	}
	if !slices.Equal(claim.Artifacts, media.Artifacts) || !slices.Equal(claim.SampleFrames, media.SampleFrames) {
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
	if claim.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported schema_version %d", claim.SchemaVersion)
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
	if len(claim.SampleFrames) != requiredSampleFrames {
		return fmt.Errorf("sample frame count must be %d", requiredSampleFrames)
	}
	if expected.SampleFrames > 0 && len(claim.SampleFrames) != expected.SampleFrames {
		return fmt.Errorf("sample frame count does not match expected %d", expected.SampleFrames)
	}
	if err := matchExpected(claim, expected); err != nil {
		return err
	}

	seenRoles := make(map[string]struct{}, len(claim.Artifacts))
	seenPaths := make(map[string]struct{}, len(claim.Artifacts)+len(claim.SampleFrames))
	for _, artifact := range claim.Artifacts {
		if _, ok := roleSet[artifact.Role]; !ok {
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
		if artifact.Height <= 0 || artifact.Height > maximumHeight {
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
