package config

import (
	"strings"
	"testing"
)

func TestStillPolicyIsOptionalAndStrict(t *testing.T) {
	for _, value := range []string{"", strings.Repeat("a", 64), "invalid", strings.Repeat("A", 64), strings.Repeat("a", 64) + "\n"} {
		env := renewalEnvironment()
		env["WALI_STILL_POLICY_DIGEST"] = value
		cfg, err := Load(func(k string) string { return env[k] })
		valid := value == "" || value == strings.Repeat("a", 64)
		if valid && (err != nil || cfg.StillPolicyDigest != value) || !valid && err == nil {
			t.Fatalf("unexpected validation for %q: %v", value, err)
		}
	}
}
