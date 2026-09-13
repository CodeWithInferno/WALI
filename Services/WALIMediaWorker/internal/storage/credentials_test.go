package storage

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testWorker = "fixture-worker"
const testOrigin = "https://abcdefghijklmnopqrst.supabase.co"

type testClock struct{ seconds atomic.Int64 }

func newTestClock() *testClock               { c := &testClock{}; c.seconds.Store(2_000_000_000); return c }
func (c *testClock) Now() time.Time          { return time.Unix(c.seconds.Load(), 0) }
func (c *testClock) Advance(d time.Duration) { c.seconds.Add(int64(d.Seconds())) }

type testIssuer func(context.Context) (Credential, error)

func (f testIssuer) Issue(ctx context.Context) (Credential, error) { return f(ctx) }
func credentialAt(now time.Time, override map[string]any) Credential {
	claims := map[string]any{"role": "wali_storage_worker", "worker_id": testWorker, "aud": "authenticated",
		"iss": testOrigin + "/auth/v1", "iat": now.Unix(), "exp": now.Add(15 * time.Minute).Unix()}
	for k, v := range override {
		claims[k] = v
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	data, _ := json.Marshal(claims)
	// Synthetic signature shape only; no key or valid provider credential exists.
	token := header + "." + base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	return Credential{AccessToken: token, WorkerID: testWorker, ExpiresAt: now.Add(15 * time.Minute)}
}
func newTestCache(t *testing.T, lifetime context.Context, issuer CredentialIssuer, clock *testClock) *CredentialCache {
	t.Helper()
	cache, err := NewCredentialCache(lifetime, issuer, testWorker, testOrigin, clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	return cache
}
func TestCredentialCacheRefreshesBeforeExpiry(t *testing.T) {
	clock := newTestClock()
	var calls atomic.Int32
	cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) { calls.Add(1); return credentialAt(clock.Now(), nil), nil }), clock)
	first, err := cache.Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(9 * time.Minute)
	still, err := cache.Token(context.Background())
	if err != nil || still != first || calls.Load() != 1 {
		t.Fatal("unexpired credential was not reused")
	}
	clock.Advance(time.Minute)
	second, err := cache.Token(context.Background())
	if err != nil || second == first || calls.Load() != 2 {
		t.Fatal("credential was not renewed with five minutes remaining")
	}
}
func TestCredentialCacheBacksOffAndNeverReturnsExpiredToken(t *testing.T) {
	clock := newTestClock()
	var calls atomic.Int32
	cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) {
		if calls.Add(1) == 1 {
			return credentialAt(clock.Now(), nil), nil
		}
		return Credential{}, errors.New("PRIVATE_ISSUER_DIAGNOSTIC")
	}), clock)
	first, err := cache.Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(10 * time.Minute)
	fallback, err := cache.Token(context.Background())
	if err != nil || fallback != first || calls.Load() != 2 {
		t.Fatal("valid fallback was not retained")
	}
	clock.Advance(20 * time.Second)
	if _, err = cache.Token(context.Background()); err != nil || calls.Load() != 2 {
		t.Fatal("failed issuance ignored backoff")
	}
	clock.Advance(4*time.Minute + 25*time.Second)
	token, err := cache.Token(context.Background())
	if token != "" || !errors.Is(err, ErrCredentialsUnavailable) || strings.Contains(err.Error(), "PRIVATE") {
		t.Fatal("near-expired token or private diagnostic escaped")
	}
	clock.Advance(time.Minute)
	if token, err = cache.Token(context.Background()); token != "" || !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("expired token escaped")
	}
}
func TestCredentialCacheSharesOneConcurrentIssuance(t *testing.T) {
	clock := newTestClock()
	var calls atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	cache := newTestCache(t, context.Background(), testIssuer(func(ctx context.Context) (Credential, error) {
		calls.Add(1)
		close(entered)
		select {
		case <-release:
			return credentialAt(clock.Now(), nil), nil
		case <-ctx.Done():
			return Credential{}, ctx.Err()
		}
	}), clock)
	var wg sync.WaitGroup
	results := make(chan error, 32)
	for range 32 {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := cache.Token(context.Background()); results <- err }()
	}
	<-entered
	close(release)
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("got %d issuer calls", calls.Load())
	}
}
func TestCancelledWaiterDoesNotCancelOtherCallersRefresh(t *testing.T) {
	clock := newTestClock()
	entered, release := make(chan struct{}), make(chan struct{})
	cache := newTestCache(t, context.Background(), testIssuer(func(ctx context.Context) (Credential, error) {
		close(entered)
		select {
		case <-release:
			return credentialAt(clock.Now(), nil), nil
		case <-ctx.Done():
			return Credential{}, ctx.Err()
		}
	}), clock)
	result := make(chan error, 1)
	go func() { _, err := cache.Token(context.Background()); result <- err }()
	<-entered
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := cache.Token(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled waiter did not return promptly")
	}
	close(release)
	if err := <-result; err != nil {
		t.Fatal("another caller's refresh was cancelled")
	}
}
func TestCredentialCacheLifetimeCancellationStopsIssuance(t *testing.T) {
	clock := newTestClock()
	lifetime, cancel := context.WithCancel(context.Background())
	entered := make(chan struct{})
	cache := newTestCache(t, lifetime, testIssuer(func(ctx context.Context) (Credential, error) {
		close(entered)
		<-ctx.Done()
		return Credential{}, ctx.Err()
	}), clock)
	result := make(chan error, 1)
	go func() { _, err := cache.Token(context.Background()); result <- err }()
	<-entered
	cancel()
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("cancelled lifetime returned credential")
		}
	case <-time.After(time.Second):
		t.Fatal("lifetime cancellation blocked")
	}
}
func TestCredentialIssuerGetsBoundedDeadline(t *testing.T) {
	clock := newTestClock()
	cache := newTestCache(t, context.Background(), testIssuer(func(ctx context.Context) (Credential, error) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 10*time.Second {
			t.Error("issuer has no ten-second bound")
		}
		return credentialAt(clock.Now(), nil), nil
	}), clock)
	if _, err := cache.Token(context.Background()); err != nil {
		t.Fatal(err)
	}
}
func TestCredentialCacheRejectsMismatchedOrMalformedClaims(t *testing.T) {
	cases := map[string]map[string]any{"role": {"role": "service_role"}, "worker": {"worker_id": "another-worker"},
		"issuer": {"iss": "https://other.example/auth/v1"}, "audience": {"aud": "service"},
		"long_lifetime": {"exp": int64(2_000_000_901)}, "stale": {"iat": int64(1_999_999_000), "exp": int64(1_999_999_900)},
		"future": {"iat": int64(2_000_000_900), "exp": int64(2_000_001_800)}, "unknown_claim": {"admin": true}}
	for name, override := range cases {
		t.Run(name, func(t *testing.T) {
			clock := newTestClock()
			cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) { return credentialAt(clock.Now(), override), nil }), clock)
			if token, err := cache.Token(context.Background()); token != "" || !errors.Is(err, ErrCredentialsUnavailable) {
				t.Fatal("invalid credential accepted")
			}
		})
	}
}
func TestCredentialCacheRejectsEnvelopeMismatchAndHeaderInjection(t *testing.T) {
	for _, mutation := range []func(*Credential){func(c *Credential) { c.WorkerID = "other" }, func(c *Credential) { c.ExpiresAt = c.ExpiresAt.Add(time.Second) },
		func(c *Credential) { c.AccessToken += "\r\nx-secret: value" }, func(c *Credential) {
			parts := strings.Split(c.AccessToken, ".")
			parts[0] = base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","alg":"HS256","typ":"JWT"}`))
			c.AccessToken = strings.Join(parts, ".")
		}} {
		clock := newTestClock()
		value := credentialAt(clock.Now(), nil)
		mutation(&value)
		cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) { return value, nil }), clock)
		if token, err := cache.Token(context.Background()); token != "" || !errors.Is(err, ErrCredentialsUnavailable) {
			t.Fatal("invalid envelope accepted")
		}
	}
}

func TestCredentialCacheBoundsAnIssuerThatIgnoresCancellation(t *testing.T) {
	clock := newTestClock()
	release := make(chan struct{})
	var calls atomic.Int32
	cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) {
		if calls.Add(1) == 1 {
			<-release
		}
		return credentialAt(clock.Now(), nil), nil
	}), clock)
	cache.refreshTimeout = 20 * time.Millisecond
	result := make(chan error, 1)
	go func() { _, err := cache.Token(context.Background()); result <- err }()
	select {
	case err := <-result:
		if !errors.Is(err, ErrCredentialsUnavailable) {
			t.Fatal("timed-out issuer supplied a credential")
		}
	case <-time.After(time.Second):
		t.Fatal("issuer blocked request indefinitely")
	}
	if token, err := cache.Token(context.Background()); token != "" || !errors.Is(err, ErrCredentialsUnavailable) || calls.Load() != 1 {
		t.Fatal("hung issuer started duplicate refresh")
	}
	cache.mu.Lock()
	done := cache.flight.done
	cache.mu.Unlock()
	close(release)
	<-done
	if token, err := cache.Token(context.Background()); token != "" || !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("late issuer response was accepted")
	}
	clock.Advance(31 * time.Second)
	if _, err := cache.Token(context.Background()); err != nil || calls.Load() != 2 {
		t.Fatal("issuer did not recover after bounded failure")
	}
}

func TestCredentialCacheRejectsCancelledContextEvenWithCachedToken(t *testing.T) {
	clock := newTestClock()
	lifetime, stop := context.WithCancel(context.Background())
	defer stop()
	cache := newTestCache(t, lifetime, testIssuer(func(context.Context) (Credential, error) { return credentialAt(clock.Now(), nil), nil }), clock)
	if _, err := cache.Token(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if token, err := cache.Token(ctx); token != "" || !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled caller used cached credentials")
	}
	stop()
	if token, err := cache.Token(context.Background()); token != "" || !errors.Is(err, context.Canceled) {
		t.Fatal("stopped worker used cached credentials")
	}
}

func TestCredentialCacheRejectsInvalidConfiguration(t *testing.T) {
	clock := newTestClock()
	issuer := testIssuer(func(context.Context) (Credential, error) { return credentialAt(clock.Now(), nil), nil })
	for _, origin := range []string{"http://example.test", "https://example.test/path", "https://user@example.test", "https://example.test?q=x", "https://example.test#x", "invalid"} {
		if _, err := NewCredentialCache(context.Background(), issuer, testWorker, origin, clock.Now); !errors.Is(err, ErrCredentialsUnavailable) {
			t.Fatal("invalid issuer origin accepted")
		}
	}
	if _, err := NewCredentialCache(context.Background(), issuer, "different worker", testOrigin, clock.Now); !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("invalid worker identity accepted")
	}
	if _, err := NewCredentialCache(context.Background(), nil, testWorker, testOrigin, clock.Now); !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("missing issuer accepted")
	}
}

func TestCredentialReadinessSharesRefreshAndFailsSafely(t *testing.T) {
	clock := newTestClock()
	var calls atomic.Int32
	cache := newTestCache(t, context.Background(), testIssuer(func(context.Context) (Credential, error) {
		if calls.Add(1) > 1 {
			return Credential{}, errors.New("private diagnostic")
		}
		return credentialAt(clock.Now(), nil), nil
	}), clock)
	if err := cache.Ready(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Token(context.Background()); err != nil || calls.Load() != 1 {
		t.Fatal("readiness and HTTP did not share cache")
	}
	clock.Advance(15 * time.Minute)
	if err := cache.Ready(context.Background()); !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("expired credentials remained ready")
	}
}
