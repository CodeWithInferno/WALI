package storage

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	credentialLifetime        = 15 * time.Minute
	credentialRefreshMargin   = 5 * time.Minute
	credentialMinimumValidity = 30 * time.Second
	credentialRefreshBackoff  = 30 * time.Second
	credentialRefreshTimeout  = 10 * time.Second
	maximumCredentialBytes    = 4096
)

var ErrCredentialsUnavailable = errors.New("storage credentials unavailable")
var credentialWorkerPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)

// Credential is an in-memory result from an authenticated issuer. Never log it.
type Credential struct {
	AccessToken string
	ExpiresAt   time.Time
	WorkerID    string
}

// CredentialIssuer must honor cancellation and must not expose issuer keys.
type CredentialIssuer interface {
	Issue(context.Context) (Credential, error)
}

type TokenSource interface {
	Token(context.Context) (string, error)
}

type credentialFlight struct {
	done chan struct{}
	ctx  context.Context
}

// CredentialCache shares one bounded refresh across callers. Cancelling an
// individual request does not cancel another request's refresh; its owning
// worker lifetime does. No credentials are persisted and no polling is started.
type CredentialCache struct {
	lifetime       context.Context
	issuer         CredentialIssuer
	workerID       string
	issuerURL      string
	now            func() time.Time
	refreshTimeout time.Duration
	mu             sync.Mutex
	cached         Credential
	retryAfter     time.Time
	flight         *credentialFlight
}

func NewCredentialCache(lifetime context.Context, issuer CredentialIssuer, workerID, storageOrigin string, now func() time.Time) (*CredentialCache, error) {
	origin, err := url.Parse(storageOrigin)
	if lifetime == nil || issuer == nil || now == nil || !credentialWorkerPattern.MatchString(workerID) || err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.Opaque != "" || origin.RawQuery != "" || origin.Fragment != "" || origin.RawPath != "" || (origin.Path != "" && origin.Path != "/") {
		return nil, ErrCredentialsUnavailable
	}
	origin.Path = "/auth/v1"
	return &CredentialCache{lifetime: lifetime, issuer: issuer, workerID: workerID, issuerURL: origin.String(), now: now, refreshTimeout: credentialRefreshTimeout}, nil
}

// Ready shares the same bounded refresh as HTTP without exposing the token.
func (c *CredentialCache) Ready(ctx context.Context) error {
	_, err := c.Token(ctx)
	return err
}

func (c *CredentialCache) Token(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := c.lifetime.Err(); err != nil {
		return "", err
	}
	c.mu.Lock()
	now := c.now()
	if c.cached.ExpiresAt.After(now.Add(credentialRefreshMargin)) {
		token := c.cached.AccessToken
		c.mu.Unlock()
		return token, nil
	}
	if c.flight == nil && !now.Before(c.retryAfter) {
		refreshContext, cancel := context.WithTimeout(c.lifetime, c.refreshTimeout)
		c.flight = &credentialFlight{done: make(chan struct{}), ctx: refreshContext}
		go c.refresh(c.flight, cancel)
	}
	flight := c.flight
	c.mu.Unlock()
	if flight != nil {
		select {
		case <-flight.done:
		case <-flight.ctx.Done():
			// A broken issuer cannot indefinitely block HTTP or spawn repeated refresh
			// goroutines. Its flight remains occupied until that issuer actually exits.
		case <-ctx.Done():
			return "", ctx.Err()
		case <-c.lifetime.Done():
			return "", c.lifetime.Err()
		}
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := c.lifetime.Err(); err != nil {
		return "", err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached.ExpiresAt.After(c.now().Add(credentialMinimumValidity)) {
		return c.cached.AccessToken, nil
	}
	return "", ErrCredentialsUnavailable
}

func (c *CredentialCache) refresh(flight *credentialFlight, cancel context.CancelFunc) {
	defer cancel()
	credential, err := c.issuer.Issue(flight.ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if err == nil && flight.ctx.Err() == nil && c.validCredential(credential, now) {
		c.cached = credential
		c.retryAfter = time.Time{}
	} else {
		c.retryAfter = now.Add(credentialRefreshBackoff)
	}
	c.flight = nil
	close(flight.done)
}

// This validates the response contract, not the HMAC: the worker has no issuer
// secret. The authenticated issuer transport supplies the credential and the
// Storage provider verifies its signature before applying existing object RLS.
func (c *CredentialCache) validCredential(value Credential, now time.Time) bool {
	if value.WorkerID != c.workerID || !safeCredentialHeader(value.AccessToken) {
		return false
	}
	parts := strings.Split(value.AccessToken, ".")
	if len(parts) != 3 {
		return false
	}
	headerBytes, err := base64.RawURLEncoding.Strict().DecodeString(parts[0])
	if err != nil {
		return false
	}
	header, ok := credentialObject(headerBytes, "alg", "typ")
	if !ok {
		return false
	}
	var algorithm, kind string
	if json.Unmarshal(header["alg"], &algorithm) != nil || json.Unmarshal(header["typ"], &kind) != nil || algorithm != "HS256" || kind != "JWT" {
		return false
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || len(signature) != 32 {
		return false
	}
	claimsBytes, err := base64.RawURLEncoding.Strict().DecodeString(parts[1])
	if err != nil {
		return false
	}
	claims, ok := credentialObject(claimsBytes, "role", "worker_id", "aud", "iss", "iat", "exp")
	if !ok {
		return false
	}
	var role, worker, audience, issuer string
	var issued, expires int64
	if json.Unmarshal(claims["role"], &role) != nil || json.Unmarshal(claims["worker_id"], &worker) != nil || json.Unmarshal(claims["aud"], &audience) != nil || json.Unmarshal(claims["iss"], &issuer) != nil || json.Unmarshal(claims["iat"], &issued) != nil || json.Unmarshal(claims["exp"], &expires) != nil {
		return false
	}
	if role != "wali_storage_worker" || worker != c.workerID || audience != "authenticated" || issuer != c.issuerURL {
		return false
	}
	// Bound timestamps before subtraction so malicious integers cannot overflow.
	if issued < now.Add(-time.Minute).Unix() || issued > now.Add(30*time.Second).Unix() || expires < issued || expires-issued != int64(credentialLifetime/time.Second) {
		return false
	}
	return value.ExpiresAt.Equal(time.Unix(expires, 0)) && value.ExpiresAt.After(now.Add(credentialRefreshMargin))
}

func safeCredentialHeader(token string) bool {
	if len(token) == 0 || len(token) > maximumCredentialBytes {
		return false
	}
	for _, b := range []byte(token) {
		if b <= 32 || b >= 127 {
			return false
		}
	}
	return true
}

func credentialObject(data []byte, keys ...string) (map[string]json.RawMessage, bool) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, false
	}
	values := make(map[string]json.RawMessage, len(keys))
	for decoder.More() {
		token, err = decoder.Token()
		if err != nil {
			return nil, false
		}
		key, ok := token.(string)
		if !ok {
			return nil, false
		}
		if _, duplicate := values[key]; duplicate {
			return nil, false
		}
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, false
		}
		values[key] = value
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, false
	}
	if _, err = decoder.Token(); err != io.EOF || len(values) != len(keys) {
		return nil, false
	}
	for _, key := range keys {
		if _, exists := values[key]; !exists {
			return nil, false
		}
	}
	return values, true
}
