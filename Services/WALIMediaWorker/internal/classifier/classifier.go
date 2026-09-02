package classifier

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
)

const (
	TaxonomyRevision = "wali-taxonomy-v1"
	ModelID          = "google/siglip-base-patch16-224"
	ModelRevision    = "7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed"
	ModelDigest      = "2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877"
)

var tokenPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{1,47}$`)

type Frame struct {
	Ordinal   int    `json:"ordinal"`
	Digest    string `json:"digest"`
	ByteCount int64  `json:"byte_count"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
}

type Request struct {
	AttemptID       string
	InputDirectory  string
	OutputDirectory string
	Title           string
	Description     string
	SubmissionID    string
	Generation      uint32
	Frames          []Frame
	PolicyDigest    string
}

type Score struct {
	ID         string  `json:"id"`
	Confidence float64 `json:"confidence"`
}

type Result struct {
	Available           bool      `json:"available"`
	SafeCode            string    `json:"safe_code"`
	ModelID             string    `json:"model_id"`
	ModelRevision       string    `json:"model_revision"`
	ModelDigest         string    `json:"model_digest"`
	TaxonomyRevision    string    `json:"taxonomy_revision"`
	InputFrameSetDigest string    `json:"input_frame_set_digest"`
	VisualEmbedding     []float64 `json:"visual_embedding"`
	TextEmbedding       []float64 `json:"text_embedding"`
	CombinedEmbedding   []float64 `json:"combined_embedding"`
	Categories          []Score   `json:"categories"`
	Tags                []Score   `json:"tags"`
}

type Classifier interface {
	Classify(context.Context, Request) (Result, error)
	Enabled() bool
}

// Noop keeps self-hosted and development workers functional when reviewed
// model weights have not been provisioned. It deliberately emits no guesses.
type Noop struct{}

func (Noop) Enabled() bool { return false }

func (Noop) Classify(context.Context, Request) (Result, error) {
	return Result{
		Available: false, SafeCode: "classifier_unavailable",
		ModelID: "", ModelRevision: "", ModelDigest: "", TaxonomyRevision: "", InputFrameSetDigest: "",
		VisualEmbedding: []float64{}, TextEmbedding: []float64{}, CombinedEmbedding: []float64{},
		Categories: []Score{}, Tags: []Score{},
	}, nil
}

type Runner interface {
	Run(context.Context, sandbox.Spec) error
}

type Sandboxed struct {
	runner Runner
	image  string
}

func NewSandboxed(runner Runner, image string) (*Sandboxed, error) {
	if runner == nil || image == "" {
		return nil, errors.New("classifier runner and immutable image are required")
	}
	return &Sandboxed{runner: runner, image: image}, nil
}

func (*Sandboxed) Enabled() bool { return true }

func (classifier *Sandboxed) Classify(ctx context.Context, request Request) (Result, error) {
	if err := validateRequest(request); err != nil {
		return Result{}, err
	}
	if err := os.Mkdir(request.OutputDirectory, 0o700); err != nil {
		return Result{}, err
	}
	payload := struct {
		SchemaVersion    uint16  `json:"schema_version"`
		AttemptID        string  `json:"attempt_id"`
		SubmissionID     string  `json:"submission_id"`
		Generation       uint32  `json:"generation"`
		Title            string  `json:"title"`
		Description      string  `json:"description"`
		TaxonomyRevision string  `json:"taxonomy_revision"`
		Frames           []Frame `json:"frames"`
	}{1, request.AttemptID, request.SubmissionID, request.Generation, request.Title, request.Description, TaxonomyRevision, request.Frames}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return Result{}, err
	}
	requestPath := filepath.Join(request.InputDirectory, "classification-request.json")
	if err := os.WriteFile(requestPath, append(encoded, '\n'), 0o600); err != nil {
		return Result{}, err
	}
	if err := classifier.runner.Run(ctx, sandbox.Spec{
		Mode: sandbox.ModeClassify, AttemptID: request.AttemptID, SubmissionID: request.SubmissionID,
		Generation: request.Generation, InputDigest: frameSetDigest(request.Frames), Image: classifier.image,
		InputDirectory: request.InputDirectory, OutputDirectory: request.OutputDirectory,
		PolicyDigest: request.PolicyDigest, Limits: sandbox.Limits{CPUs: "2", Memory: "4g", PIDs: 64, TmpfsBytes: 1 << 30},
	}); err != nil {
		return Result{}, err
	}
	claimFile, err := os.Open(filepath.Join(request.OutputDirectory, "classification-claim.json"))
	if err != nil {
		return Result{}, err
	}
	defer claimFile.Close()
	return decodeClaim(claimFile, request)
}

type claim struct {
	SchemaVersion       uint16    `json:"schema_version"`
	AttemptID           string    `json:"attempt_id"`
	SubmissionID        string    `json:"submission_id"`
	Generation          uint32    `json:"generation"`
	Available           bool      `json:"available"`
	SafeCode            string    `json:"safe_code"`
	ModelID             string    `json:"model_id"`
	ModelRevision       string    `json:"model_revision"`
	ModelDigest         string    `json:"model_digest"`
	TaxonomyRevision    string    `json:"taxonomy_revision"`
	InputFrameSetDigest string    `json:"input_frame_set_digest"`
	VisualEmbedding     []float64 `json:"visual_embedding"`
	TextEmbedding       []float64 `json:"text_embedding"`
	CombinedEmbedding   []float64 `json:"combined_embedding"`
	Categories          []Score   `json:"categories"`
	Tags                []Score   `json:"tags"`
}

func decodeClaim(reader io.Reader, request Request) (Result, error) {
	data, err := io.ReadAll(io.LimitReader(reader, 128<<10+1))
	if err != nil || len(data) > 128<<10 {
		return Result{}, errors.New("classifier claim is unreadable or oversized")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var value claim
	if err := decoder.Decode(&value); err != nil {
		return Result{}, errors.New("classifier claim is invalid")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return Result{}, errors.New("classifier claim has trailing data")
	}
	if value.SchemaVersion != 1 || value.AttemptID != request.AttemptID || value.SubmissionID != request.SubmissionID || value.Generation != request.Generation ||
		!value.Available || value.SafeCode != "ok" || value.ModelID != ModelID || value.ModelRevision != ModelRevision || value.ModelDigest != ModelDigest ||
		value.TaxonomyRevision != TaxonomyRevision || value.InputFrameSetDigest != frameSetDigest(request.Frames) {
		return Result{}, errors.New("classifier claim identity is invalid")
	}
	for _, embedding := range [][]float64{value.VisualEmbedding, value.TextEmbedding, value.CombinedEmbedding} {
		if len(embedding) != 768 {
			return Result{}, errors.New("classifier embedding dimension is invalid")
		}
		norm := 0.0
		for _, number := range embedding {
			if math.IsNaN(number) || math.IsInf(number, 0) {
				return Result{}, errors.New("classifier embedding is invalid")
			}
			norm += number * number
		}
		if norm < 0.98 || norm > 1.02 {
			return Result{}, errors.New("classifier embedding is not normalized")
		}
	}
	if err := validateScores(value.Categories, 64); err != nil {
		return Result{}, err
	}
	if err := validateScores(value.Tags, 256); err != nil {
		return Result{}, err
	}
	return Result{
		Available: true, SafeCode: "ok", ModelID: value.ModelID, ModelRevision: value.ModelRevision,
		ModelDigest: value.ModelDigest, TaxonomyRevision: value.TaxonomyRevision,
		InputFrameSetDigest: value.InputFrameSetDigest,
		VisualEmbedding:     value.VisualEmbedding, TextEmbedding: value.TextEmbedding, CombinedEmbedding: value.CombinedEmbedding,
		Categories: value.Categories, Tags: value.Tags,
	}, nil
}

func validateScores(scores []Score, maximum int) error {
	if len(scores) > maximum {
		return errors.New("classifier suggestions exceed the taxonomy bound")
	}
	seen := map[string]bool{}
	for index, score := range scores {
		if !tokenPattern.MatchString(score.ID) || seen[score.ID] || math.IsNaN(score.Confidence) || math.IsInf(score.Confidence, 0) || score.Confidence < 0 || score.Confidence > 1 {
			return errors.New("classifier suggestion is invalid")
		}
		seen[score.ID] = true
		if index > 0 && (scores[index-1].Confidence < score.Confidence || (scores[index-1].Confidence == score.Confidence && scores[index-1].ID > score.ID)) {
			return errors.New("classifier suggestions are not deterministic")
		}
	}
	return nil
}

func validateRequest(request Request) error {
	if request.AttemptID == "" || request.SubmissionID == "" || request.Generation == 0 || len([]rune(request.Title)) < 1 || len([]rune(request.Title)) > 120 || len([]rune(request.Description)) > 2000 || len(request.Frames) != 7 {
		return errors.New("classifier request is invalid")
	}
	if filepath.Clean(request.InputDirectory) != request.InputDirectory || filepath.Clean(request.OutputDirectory) != request.OutputDirectory || !filepath.IsAbs(request.InputDirectory) || !filepath.IsAbs(request.OutputDirectory) {
		return errors.New("classifier directories are invalid")
	}
	for index, frame := range request.Frames {
		if frame.Ordinal != index+1 || len(frame.Digest) != 64 || frame.ByteCount <= 0 || frame.ByteCount > 16<<20 || frame.Width <= 0 || frame.Width > 1024 || frame.Height <= 0 || frame.Height > 1024 {
			return errors.New("classifier frame set is invalid")
		}
	}
	return nil
}

func frameSetDigest(frames []Frame) string {
	digests := make([]string, len(frames))
	for index, frame := range frames {
		digests[index] = frame.Digest
	}
	hasher := sha256.New()
	_, _ = io.Copy(hasher, strings.NewReader(strings.Join(digests, "")))
	return hex.EncodeToString(hasher.Sum(nil))
}
