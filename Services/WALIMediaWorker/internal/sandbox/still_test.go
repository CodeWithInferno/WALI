package sandbox

import (
	"slices"
	"strings"
	"testing"
)

func TestStillRoutingAddsOnlyValidatedKindAndKeepsIsolation(t *testing.T) {
	spec := Spec{Mode: ModeProcess, MediaKind: "still", AttemptID: "attempt-1", SubmissionID: "submission-1", Generation: 1, InputDigest: strings.Repeat("a", 64), Image: "localhost/wali@sha256:" + strings.Repeat("b", 64), InputDirectory: "/var/lib/wali/input/attempt-1", OutputDirectory: "/var/lib/wali/output/attempt-1", PolicyDigest: strings.Repeat("c", 64), Limits: Limits{CPUs: "2", Memory: "4g", PIDs: 64, TmpfsBytes: 1 << 30}}
	args, err := BuildPodmanArgs(spec)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"--env=WALI_MEDIA_KIND=still", "--network=none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges"} {
		if !slices.Contains(args, value) {
			t.Fatalf("missing %s", value)
		}
	}
	spec.MediaKind = ""
	legacy, err := BuildPodmanArgs(spec)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range legacy {
		if strings.Contains(value, "WALI_MEDIA_KIND") {
			t.Fatal("legacy command bytes changed")
		}
	}
	spec.MediaKind = "still --privileged"
	if _, err := BuildPodmanArgs(spec); err == nil {
		t.Fatal("unbounded kind accepted")
	}
}
