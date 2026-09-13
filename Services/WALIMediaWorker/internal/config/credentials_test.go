package config

import (
	"strings"
	"testing"
)

func renewalEnvironment() map[string]string {
	return map[string]string{
		"WALI_DATABASE_URL": "postgresql://worker:synthetic@db.example.test/postgres?sslmode=verify-full",
		"WALI_STORAGE_URL":  "https://project.supabase.co", "WALI_STORAGE_PUBLISHABLE_KEY": "sb_publishable_synthetic",
		"WALI_WORKER_ID": "worker-1", "WALI_QUEUE_NAME": "wali_media_processing", "WALI_SCRATCH_ROOT": "/var/lib/wali/attempts",
		"WALI_PODMAN_PATH": "/usr/bin/podman", "WALI_MEDIA_IMAGE": "registry.example.test/media@sha256:" + strings.Repeat("a", 64),
		"WALI_VERIFIER_IMAGE": "registry.example.test/media@sha256:" + strings.Repeat("b", 64), "WALI_MEDIA_POLICY_DIGEST": strings.Repeat("c", 64),
		"WALI_HEALTH_SOCKET": "/run/wali-media-worker/health.sock", "WALI_STORAGE_AUTH_MODE": "database_renewal",
	}
}
func TestDatabaseRenewalDoesNotRequirePersistedToken(t *testing.T) {
	env := renewalEnvironment()
	if _, err := Load(func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
}
func TestStorageAuthModesFailClosed(t *testing.T) {
	for _, tc := range []struct{ name, mode, token string }{
		{"mixed credentials", "database_renewal", "secret-must-not-appear"},
		{"unknown mode", "automatic", ""}, {"whitespace mode", "database_renewal ", ""},
		{"static needs token", "static", ""}, {"default remains static", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := renewalEnvironment()
			env["WALI_STORAGE_AUTH_MODE"] = tc.mode
			env["WALI_STORAGE_WORKER_TOKEN"] = tc.token
			_, err := Load(func(k string) string { return env[k] })
			if err == nil {
				t.Fatal("invalid auth mode accepted")
			}
			if strings.Contains(err.Error(), "secret-must-not-appear") {
				t.Fatal("secret in error")
			}
		})
	}
}
