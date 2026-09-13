package config

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func staticTestToken(now time.Time, expiry time.Time, role, worker, audience string) string {
	header, _ := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{"role": role, "worker_id": worker, "aud": audience, "iat": now.Add(-time.Minute).Unix(), "exp": expiry.Unix()})
	return base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims) + "." + strings.Repeat("s", 32)
}
func TestStaticStartupRejectsInsufficientWholeAttemptLifetime(t *testing.T) {
	env := renewalEnvironment()
	env["WALI_STORAGE_AUTH_MODE"] = "static"
	now := time.Now()
	env["WALI_STORAGE_WORKER_TOKEN"] = staticTestToken(now, now.Add(90*time.Minute), "wali_storage_worker", "worker-1", "authenticated")
	if _, err := Load(func(k string) string { return env[k] }); err == nil {
		t.Fatal("static startup accepted a token that cannot cover the90-minute attempt and5-minute margin")
	}
}

func TestStaticMediaAdmissionRechecksExpiryWithoutRenewal(t *testing.T) {
	now := time.Unix(2000000000, 0).UTC()
	token := staticTestToken(now, now.Add(96*time.Minute), "wali_storage_worker", "worker-1", "authenticated")
	ready, err := NewStaticMediaAdmission(token, "worker-1", func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	if err := ready(context.Background()); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute)
	if err := ready(context.Background()); err == nil {
		t.Fatal("exact95-minute threshold admitted another attempt")
	}
	now = now.Add(time.Minute)
	if err := ready(context.Background()); err == nil {
		t.Fatal("aging credential admitted another attempt")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if !errors.Is(ready(ctx), context.Canceled) {
		t.Fatal("cancellation was hidden")
	}
}
func TestStaticMediaAdmissionLifetimeBoundariesAndIdentity(t *testing.T) {
	now := time.Unix(2000000000, 0).UTC()
	for _, c := range []struct {
		name                   string
		remaining              time.Duration
		role, worker, audience string
		valid                  bool
	}{
		{"above budget", 95*time.Minute + time.Second, "wali_storage_worker", "worker-1", "authenticated", true},
		{"at budget", 95 * time.Minute, "wali_storage_worker", "worker-1", "authenticated", false},
		{"below budget", 95*time.Minute - time.Second, "wali_storage_worker", "worker-1", "authenticated", false},
		{"expired", -time.Second, "wali_storage_worker", "worker-1", "authenticated", false},
		{"wrong role", 2 * time.Hour, "authenticated", "worker-1", "authenticated", false},
		{"wrong worker", 2 * time.Hour, "wali_storage_worker", "other-worker", "authenticated", false},
		{"wrong audience", 2 * time.Hour, "wali_storage_worker", "worker-1", "other", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			token := staticTestToken(now, now.Add(c.remaining), c.role, c.worker, c.audience)
			ready, err := NewStaticMediaAdmission(token, "worker-1", func() time.Time { return now })
			if (err == nil) != c.valid {
				t.Fatalf("valid=%v, error=%v", c.valid, err)
			}
			if err != nil && strings.Contains(err.Error(), token) {
				t.Fatal("credential leaked in error")
			}
			if c.valid && ready(context.Background()) != nil {
				t.Fatal("usable static credential rejected")
			}
		})
	}
	if _, err := NewStaticMediaAdmission("synthetic", "worker-1", nil); err == nil {
		t.Fatal("nil clock accepted")
	}
}
func TestStaticStartupAcceptsSufficientWholeAttemptLifetime(t *testing.T) {
	env := renewalEnvironment()
	env["WALI_STORAGE_AUTH_MODE"] = "static"
	now := time.Now()
	env["WALI_STORAGE_WORKER_TOKEN"] = staticTestToken(now, now.Add(96*time.Minute), "wali_storage_worker", "worker-1", "authenticated")
	if _, err := Load(func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
}
