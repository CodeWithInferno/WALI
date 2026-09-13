package jobs

import (
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/sandbox"
	"testing"
)

func TestVideoProfilePreservesVerificationResourceLimits(t *testing.T) {
	for _, c := range []struct {
		name string
		kind string
		mode sandbox.Mode
		cpus string
	}{
		{"legacy video processing", "", sandbox.ModeProcess, "4"}, {"video processing", "video", sandbox.ModeProcess, "4"}, {"video verification", "video", sandbox.ModeVerify, "2"}, {"still processing", "still", sandbox.ModeProcess, "2"}, {"still verification", "still", sandbox.ModeVerify, "2"},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := &Processor{}
			got := p.sandboxSpec(c.mode, ProcessSubmission{MediaKind: c.kind}, "digest", "/input", "/output", "image")
			if got.Limits.CPUs != c.cpus {
				t.Fatalf("CPUs=%s, want %s", got.Limits.CPUs, c.cpus)
			}
			if got.Limits.Memory != "4g" || got.Limits.PIDs != 64 || got.Limits.TmpfsBytes != 1<<30 {
				t.Fatal("non-CPU sandbox limits changed")
			}
		})
	}
}
