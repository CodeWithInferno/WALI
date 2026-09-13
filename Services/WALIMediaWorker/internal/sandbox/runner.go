package sandbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type Mode string

const (
	ModeProcess  Mode = "process"
	ModeVerify   Mode = "verify"
	ModeClassify Mode = "classify"
)

var (
	ErrRuntimeFailed = errors.New("sandbox runtime failed")
	imagePattern     = regexp.MustCompile(`^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$`)
	idPattern        = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}$`)
	digestPattern    = regexp.MustCompile(`^[a-f0-9]{64}$`)
	cpuPattern       = regexp.MustCompile(`^[1-9][0-9]*(\.[0-9]{1,2})?$`)
	memoryPattern    = regexp.MustCompile(`^[1-9][0-9]{0,4}[mMgG]$`)
)

type Limits struct {
	CPUs       string
	Memory     string
	PIDs       int
	TmpfsBytes int64
}

type Spec struct {
	MediaKind       string
	Mode            Mode
	AttemptID       string
	SubmissionID    string
	Generation      uint32
	InputDigest     string
	Image           string
	InputDirectory  string
	OutputDirectory string
	PolicyDigest    string
	Limits          Limits
}

type Executor interface {
	Run(context.Context, string, ...string) error
}

type Runner struct {
	binary   string
	executor Executor
}

func NewRunner(binary string, executor Executor) (*Runner, error) {
	if !filepath.IsAbs(binary) || filepath.Clean(binary) != binary || filepath.Base(binary) != "podman" {
		return nil, errors.New("podman binary must be an absolute clean path ending in podman")
	}
	if executor == nil {
		executor = osExecutor{}
	}
	return &Runner{binary: binary, executor: executor}, nil
}

func (r *Runner) Run(ctx context.Context, spec Spec) error {
	args, err := BuildPodmanArgs(spec)
	if err != nil {
		return err
	}
	if err := r.executor.Run(ctx, r.binary, args...); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %v", ErrRuntimeFailed, err)
	}
	return nil
}

func BuildPodmanArgs(spec Spec) ([]string, error) {
	if spec.MediaKind != "" && spec.MediaKind != "video" && spec.MediaKind != "still" {
		return nil, errors.New("unsupported sandbox media kind")
	}
	command, suffix, err := modeCommand(spec.Mode)
	if err != nil {
		return nil, err
	}
	if !idPattern.MatchString(spec.AttemptID) || !idPattern.MatchString(spec.SubmissionID) || strings.HasPrefix(spec.AttemptID, "-") || strings.HasPrefix(spec.SubmissionID, "-") {
		return nil, errors.New("attempt and submission IDs must be safe bounded identifiers")
	}
	if spec.Generation == 0 {
		return nil, errors.New("generation must be positive")
	}
	if !imagePattern.MatchString(spec.Image) {
		return nil, errors.New("image must be a named immutable sha256 reference")
	}
	if !digestPattern.MatchString(spec.PolicyDigest) {
		return nil, errors.New("policy digest must be lowercase SHA-256")
	}
	if !digestPattern.MatchString(spec.InputDigest) {
		return nil, errors.New("input digest must be lowercase SHA-256")
	}
	if err := validateMountSource(spec.InputDirectory); err != nil {
		return nil, fmt.Errorf("input directory: %w", err)
	}
	if err := validateMountSource(spec.OutputDirectory); err != nil {
		return nil, fmt.Errorf("output directory: %w", err)
	}
	if spec.InputDirectory == spec.OutputDirectory {
		return nil, errors.New("input and output directories must differ")
	}
	if !cpuPattern.MatchString(spec.Limits.CPUs) || !memoryPattern.MatchString(spec.Limits.Memory) {
		return nil, errors.New("CPU or memory limit is invalid")
	}
	if spec.Limits.PIDs < 8 || spec.Limits.PIDs > 256 {
		return nil, errors.New("PID limit must be between 8 and 256")
	}
	if spec.Limits.TmpfsBytes < 64<<20 || spec.Limits.TmpfsBytes > 4<<30 {
		return nil, errors.New("tmpfs limit must be between 64 MiB and 4 GiB")
	}

	name := "wali-" + suffix + "-" + strings.ToLower(spec.AttemptID)
	args := []string{
		"run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
		"--security-opt=no-new-privileges", "--userns=keep-id",
		"--user=" + strconv.Itoa(os.Getuid()) + ":" + strconv.Itoa(os.Getgid()),
		"--pids-limit=" + strconv.Itoa(spec.Limits.PIDs),
		"--cpus=" + spec.Limits.CPUs,
		"--memory=" + strings.ToLower(spec.Limits.Memory),
		"--memory-swap=" + strings.ToLower(spec.Limits.Memory),
		"--name=" + name,
		"--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=" + strconv.FormatInt(spec.Limits.TmpfsBytes, 10),
		"--mount=type=bind,src=" + spec.InputDirectory + ",dst=/work/input,ro=true",
		"--mount=type=bind,src=" + spec.OutputDirectory + ",dst=/work/output,rw=true",
		"--env=WALI_POLICY_DIGEST=" + spec.PolicyDigest,
		"--env=WALI_ATTEMPT_ID=" + spec.AttemptID,
		"--env=WALI_SUBMISSION_ID=" + spec.SubmissionID,
		"--env=WALI_GENERATION=" + strconv.FormatUint(uint64(spec.Generation), 10),
		"--env=WALI_INPUT_DIGEST=" + spec.InputDigest,
		"--env=HOME=/nonexistent",
		"--env=TMPDIR=/tmp",
		"--env=HF_HUB_OFFLINE=1",
		"--env=TRANSFORMERS_OFFLINE=1",
		"--env=HF_HUB_DISABLE_TELEMETRY=1",
		"--env=DO_NOT_TRACK=1",
	}
	if spec.MediaKind == "still" {
		args = append(args, "--env=WALI_MEDIA_KIND=still")
	}
	args = append(args, spec.Image)
	if command != "" {
		args = append(args, command)
	}
	return args, nil
}

func modeCommand(mode Mode) (string, string, error) {
	switch mode {
	case ModeProcess:
		return "/opt/wali/bin/process-media", "process", nil
	case ModeVerify:
		return "/opt/wali/bin/verify-media", "verify", nil
	case ModeClassify:
		return "", "classify", nil
	default:
		return "", "", fmt.Errorf("unsupported sandbox mode %q", mode)
	}
}

func validateMountSource(value string) error {
	if !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return errors.New("must be an absolute clean path")
	}
	if value == "/" || value == "/var" || value == "/tmp" || value == "/Users" || value == "/home" {
		return errors.New("mount source is too broad")
	}
	if strings.ContainsAny(value, ",:\x00\r\n") {
		return errors.New("contains a reserved mount character")
	}
	return nil
}

type osExecutor struct{}

func (osExecutor) Run(ctx context.Context, path string, args ...string) error {
	command := exec.CommandContext(ctx, path, args...)
	command.Stdin = nil
	command.Stdout = nil
	command.Stderr = nil
	return command.Run()
}
