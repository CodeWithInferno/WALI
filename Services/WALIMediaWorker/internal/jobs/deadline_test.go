package jobs_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/classifier"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
)

type deadlineAttempts struct {
	*fakeAttempts
	t          *testing.T
	failureErr error
}

func (a *deadlineAttempts) Fail(ctx context.Context, job jobs.ProcessSubmission, lease jobs.Lease, failure jobs.Failure) (bool, error) {
	if ctx.Err() != nil {
		a.t.Error("failure used cancelled execution context")
	}
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > 5*time.Second {
		a.t.Error("failure write has no five-second bound")
	}
	if failure.SafeCode != "processing_timeout" {
		a.t.Error("wrong stable timeout failure")
	}
	if a.failureErr != nil {
		return false, a.failureErr
	}
	return a.fakeAttempts.Fail(ctx, job, lease, failure)
}
func newDeadlineProcessor(t *testing.T, attempts jobs.AttemptStore, runner jobs.SandboxRunner) *jobs.Processor {
	t.Helper()
	p, err := jobs.NewProcessor(jobs.Dependencies{Attempts: attempts, Blobs: &fakeBlobs{input: []byte("opaque")}, Sandbox: runner,
		Classifier: classifier.Noop{}, Cleanup: &fakeCleanup{}, ScratchRoot: t.TempDir(),
		MediaImage: "localhost/wali-media@sha256:" + strings.Repeat("c", 64), VerifierImage: "localhost/wali-verifier@sha256:" + strings.Repeat("d", 64),
		PolicyDigest: strings.Repeat("b", 64), HeartbeatInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func TestExpiredExecutionCommitsOwnedTerminalFailure(t *testing.T) {
	attempts := &deadlineAttempts{fakeAttempts: &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: true}, t: t}
	job := decodeJob(t)
	job.DeadlineAt = time.Now().Add(-time.Second)
	result := newDeadlineProcessor(t, attempts, fakeSandbox{delay: time.Millisecond}).Process(context.Background(), job, jobs.Lease{Owner: "fixture-worker"})
	if result.Action != jobs.ActionAck || result.SafeCode != "processing_timeout" || attempts.failed != 1 || attempts.completed != 0 {
		t.Fatalf("timeout did not commit exactly one terminal failure: result=%#v failures=%d", result, attempts.failed)
	}
}
func TestExpiredExecutionCannotCommitAfterLeaseLoss(t *testing.T) {
	attempts := &deadlineAttempts{fakeAttempts: &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: false}, t: t}
	job := decodeJob(t)
	job.DeadlineAt = time.Now().Add(-time.Second)
	result := newDeadlineProcessor(t, attempts, fakeSandbox{delay: time.Millisecond}).Process(context.Background(), job, jobs.Lease{Owner: "stale-worker"})
	if result.Action != jobs.ActionLeave || result.SafeCode != "lease_lost" || attempts.completed != 0 {
		t.Fatalf("unowned timeout was acknowledged: %#v", result)
	}
}
func TestExpiredExecutionFailureWriteErrorNeverAcknowledges(t *testing.T) {
	attempts := &deadlineAttempts{fakeAttempts: &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: true}, t: t, failureErr: errors.New("fixture unavailable")}
	job := decodeJob(t)
	job.DeadlineAt = time.Now().Add(-time.Second)
	result := newDeadlineProcessor(t, attempts, fakeSandbox{delay: time.Millisecond}).Process(context.Background(), job, jobs.Lease{})
	if result.Action != jobs.ActionNack || result.SafeCode != "timeout_commit_failed" || attempts.completed != 0 {
		t.Fatalf("uncommitted timeout acknowledged: %#v", result)
	}
}
func TestWorkerCancellationDoesNotRecordExecutionTimeout(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: true}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	job := decodeJob(t)
	job.DeadlineAt = time.Now().Add(-time.Second)
	result := newDeadlineProcessor(t, attempts, fakeSandbox{delay: time.Millisecond}).Process(ctx, job, jobs.Lease{})
	if attempts.failed != 0 || attempts.completed != 0 || result.Action == jobs.ActionAck {
		t.Fatalf("worker shutdown mutated terminal state: %#v", result)
	}
}

type deadlineObservingSandbox struct {
	t        *testing.T
	expected time.Time
	called   bool
}

func (s *deadlineObservingSandbox) Run(ctx context.Context, _ sandbox.Spec) error {
	s.called = true
	deadline, ok := ctx.Deadline()
	if !ok || !deadline.Equal(s.expected) {
		s.t.Error("worker reset the supplied absolute execution deadline")
	}
	return errors.New("fixture stopped after deadline observation")
}
func TestProcessorPreservesSuppliedAbsoluteDeadline(t *testing.T) {
	attempts := &fakeAttempts{begin: jobs.BeginStarted, heartbeatOK: true, failOK: true}
	job := decodeJob(t)
	job.DeadlineAt = time.Now().Add(time.Minute)
	runner := &deadlineObservingSandbox{t: t, expected: job.DeadlineAt}
	result := newDeadlineProcessor(t, attempts, runner).Process(context.Background(), job, jobs.Lease{})
	if !runner.called || result.Action != jobs.ActionNack || attempts.failed != 0 || attempts.completed != 0 {
		t.Fatal("absolute deadline fixture did not exercise sandbox boundary")
	}
}
