package config

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var (
	identifierPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)
	imagePattern      = regexp.MustCompile(`^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$`)
)

const (
	WorkerDatabaseRole         = "wali_worker"
	StorageAuthStatic          = "static"
	StorageAuthDatabaseRenewal = "database_renewal"
)

type Config struct {
	DatabaseURL           string
	StorageURL            string
	StoragePublishableKey string
	StorageWorkerToken    string
	StorageAuthMode       string
	WorkerID              string
	QueueName             string
	ScratchRoot           string
	PodmanPath            string
	MediaImage            string
	VerifierImage         string
	ClassifierImage       string
	MediaPolicyDigest     string
	StillPolicyDigest     string
	HealthSocket          string
	VisibilityTimeout     time.Duration
	RetryDelay            time.Duration
	IdleDelay             time.Duration
	HeartbeatInterval     time.Duration
	LeaseDuration         time.Duration
}

func Load(getenv func(string) string) (Config, error) {
	if getenv == nil {
		return Config{}, errors.New("environment reader is required")
	}
	required := []string{
		"WALI_DATABASE_URL", "WALI_STORAGE_URL", "WALI_STORAGE_PUBLISHABLE_KEY",
		"WALI_WORKER_ID", "WALI_QUEUE_NAME", "WALI_SCRATCH_ROOT",
		"WALI_PODMAN_PATH", "WALI_MEDIA_IMAGE", "WALI_VERIFIER_IMAGE", "WALI_MEDIA_POLICY_DIGEST",
		"WALI_HEALTH_SOCKET",
	}
	authMode := getenv("WALI_STORAGE_AUTH_MODE")
	if authMode == "" {
		authMode = StorageAuthStatic
	}
	switch authMode {
	case StorageAuthStatic:
		required = append(required, "WALI_STORAGE_WORKER_TOKEN")
	case StorageAuthDatabaseRenewal:
		if getenv("WALI_STORAGE_WORKER_TOKEN") != "" {
			return Config{}, errors.New("database renewal cannot be mixed with a static Storage token")
		}
	default:
		return Config{}, errors.New("WALI_STORAGE_AUTH_MODE is invalid")
	}
	values := make(map[string]string, len(required))
	for _, key := range required {
		value := getenv(key)
		if value == "" {
			return Config{}, fmt.Errorf("required setting %s is missing", key)
		}
		if strings.ContainsAny(value, "\x00\r\n") {
			return Config{}, fmt.Errorf("required setting %s contains forbidden control characters", key)
		}
		values[key] = value
	}

	if err := validateDatabaseURL(values["WALI_DATABASE_URL"]); err != nil {
		return Config{}, fmt.Errorf("WALI_DATABASE_URL is invalid: %w", err)
	}
	if err := validateStorageURL(values["WALI_STORAGE_URL"]); err != nil {
		return Config{}, fmt.Errorf("WALI_STORAGE_URL is invalid: %w", err)
	}
	if authMode == StorageAuthStatic {
		if _, err := NewStaticMediaAdmission(values["WALI_STORAGE_WORKER_TOKEN"], values["WALI_WORKER_ID"], time.Now); err != nil {
			return Config{}, fmt.Errorf("WALI_STORAGE_WORKER_TOKEN is invalid: %w", err)
		}
	}
	if len(values["WALI_STORAGE_PUBLISHABLE_KEY"]) > 2048 || strings.ContainsAny(values["WALI_STORAGE_PUBLISHABLE_KEY"], " \t") {
		return Config{}, errors.New("WALI_STORAGE_PUBLISHABLE_KEY is invalid")
	}
	if !identifierPattern.MatchString(values["WALI_WORKER_ID"]) {
		return Config{}, errors.New("WALI_WORKER_ID is invalid")
	}
	if values["WALI_QUEUE_NAME"] != "wali_media_processing" {
		return Config{}, errors.New("WALI_QUEUE_NAME must be wali_media_processing")
	}
	if err := validateNarrowAbsolutePath(values["WALI_SCRATCH_ROOT"]); err != nil {
		return Config{}, fmt.Errorf("WALI_SCRATCH_ROOT is invalid: %w", err)
	}
	if !filepath.IsAbs(values["WALI_PODMAN_PATH"]) || filepath.Clean(values["WALI_PODMAN_PATH"]) != values["WALI_PODMAN_PATH"] || filepath.Base(values["WALI_PODMAN_PATH"]) != "podman" {
		return Config{}, errors.New("WALI_PODMAN_PATH must be an absolute path ending in podman")
	}
	for _, key := range []string{"WALI_MEDIA_IMAGE", "WALI_VERIFIER_IMAGE"} {
		if !imagePattern.MatchString(values[key]) {
			return Config{}, fmt.Errorf("%s must be an immutable named sha256 image", key)
		}
	}
	if !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(values["WALI_MEDIA_POLICY_DIGEST"]) {
		return Config{}, errors.New("WALI_MEDIA_POLICY_DIGEST must be lowercase SHA-256")
	}
	stillPolicyDigest := getenv("WALI_STILL_POLICY_DIGEST")
	if stillPolicyDigest != "" && !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(stillPolicyDigest) {
		return Config{}, errors.New("WALI_STILL_POLICY_DIGEST must be empty or lowercase SHA-256")
	}
	classifierImage := getenv("WALI_CLASSIFIER_IMAGE")
	if classifierImage != "" && !imagePattern.MatchString(classifierImage) {
		return Config{}, errors.New("WALI_CLASSIFIER_IMAGE must be empty or an immutable named sha256 image")
	}
	healthSocket := values["WALI_HEALTH_SOCKET"]
	if err := validateNarrowAbsolutePath(healthSocket); err != nil || filepath.Ext(healthSocket) != ".sock" || !strings.HasPrefix(healthSocket, "/run/wali-media-worker/") {
		return Config{}, errors.New("WALI_HEALTH_SOCKET must be a .sock path below /run/wali-media-worker")
	}

	return Config{
		DatabaseURL: values["WALI_DATABASE_URL"], StorageURL: values["WALI_STORAGE_URL"], StoragePublishableKey: values["WALI_STORAGE_PUBLISHABLE_KEY"],
		StorageWorkerToken: values["WALI_STORAGE_WORKER_TOKEN"], StorageAuthMode: authMode, WorkerID: values["WALI_WORKER_ID"],
		QueueName: values["WALI_QUEUE_NAME"], ScratchRoot: values["WALI_SCRATCH_ROOT"],
		PodmanPath: values["WALI_PODMAN_PATH"], MediaImage: values["WALI_MEDIA_IMAGE"],
		VerifierImage: values["WALI_VERIFIER_IMAGE"], ClassifierImage: classifierImage, MediaPolicyDigest: values["WALI_MEDIA_POLICY_DIGEST"], StillPolicyDigest: stillPolicyDigest,
		HealthSocket:      healthSocket,
		VisibilityTimeout: 5 * time.Minute, RetryDelay: 30 * time.Second,
		IdleDelay: time.Second, HeartbeatInterval: 30 * time.Second, LeaseDuration: 2 * time.Minute,
	}, nil
}

func validateDatabaseURL(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || (parsed.Scheme != "postgres" && parsed.Scheme != "postgresql") || parsed.Host == "" || parsed.User == nil {
		return errors.New("must be a PostgreSQL connection URL with host and worker identity")
	}
	local := parsed.Hostname() == "localhost" || parsed.Hostname() == "127.0.0.1" || parsed.Hostname() == "::1"
	sslMode := parsed.Query().Get("sslmode")
	if parsed.Fragment != "" || parsed.RawQuery == "" || len(parsed.Query()) != 1 ||
		(!local && sslMode != "verify-full") || (local && sslMode != "verify-full" && sslMode != "disable") {
		return errors.New("database URL requires only sslmode=verify-full except disable on loopback")
	}
	username := parsed.User.Username()
	if username == "" || username == "postgres" || username == "supabase_admin" || username == "service_role" || username == WorkerDatabaseRole {
		return errors.New("database URL must use a dedicated non-administrator login")
	}
	return nil
}

func validateWorkerToken(value, workerID string, now time.Time) error {
	_, err := workerTokenExpiry(value, workerID, now)
	return err
}

func workerTokenExpiry(value, workerID string, now time.Time) (time.Time, error) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 || len(parts[2]) < 16 {
		return time.Time{}, errors.New("must be a signed JWT")
	}
	decode := func(part string, target any) error {
		data, err := base64.RawURLEncoding.DecodeString(part)
		if err != nil || len(data) == 0 || len(data) > 4096 {
			return errors.New("contains invalid JWT data")
		}
		decoder := json.NewDecoder(strings.NewReader(string(data)))
		return decoder.Decode(target)
	}
	var header struct {
		Algorithm string `json:"alg"`
		Type      string `json:"typ"`
	}
	if err := decode(parts[0], &header); err != nil || (header.Algorithm != "HS256" && header.Algorithm != "ES256" && header.Algorithm != "RS256") || header.Type != "JWT" {
		return time.Time{}, errors.New("uses an unsupported JWT header")
	}
	var claims struct {
		Role      string `json:"role"`
		WorkerID  string `json:"worker_id"`
		Audience  string `json:"aud"`
		IssuedAt  int64  `json:"iat"`
		ExpiresAt int64  `json:"exp"`
	}
	if err := decode(parts[1], &claims); err != nil {
		return time.Time{}, errors.New("contains invalid JWT claims")
	}
	if claims.Role != "wali_storage_worker" || claims.Role == "service_role" || claims.Role == "wali_worker" {
		return time.Time{}, errors.New("role must be wali_storage_worker")
	}
	if claims.WorkerID != workerID || !identifierPattern.MatchString(claims.WorkerID) {
		return time.Time{}, errors.New("worker_id must match WALI_WORKER_ID")
	}
	if claims.Audience != "authenticated" {
		return time.Time{}, errors.New("audience must be authenticated")
	}
	issuedAt, expiresAt := time.Unix(claims.IssuedAt, 0), time.Unix(claims.ExpiresAt, 0)
	if issuedAt.After(now.Add(5*time.Minute)) || issuedAt.Before(now.Add(-90*24*time.Hour)) || expiresAt.Before(now.Add(5*time.Minute)) || expiresAt.After(now.Add(90*24*time.Hour)) || !expiresAt.After(issuedAt) {
		return time.Time{}, errors.New("lifetime must be current and at most 90 days")
	}
	return expiresAt, nil
}

func validateStorageURL(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("must be an origin-only HTTPS URL")
	}
	return nil
}

func validateNarrowAbsolutePath(value string) error {
	if !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return errors.New("must be an absolute clean path")
	}
	for _, broad := range []string{"/", "/var", "/tmp", "/home", "/Users"} {
		if value == broad {
			return errors.New("path is too broad")
		}
	}
	if strings.ContainsAny(value, ",:\x00\r\n") {
		return errors.New("path contains a reserved mount character")
	}
	return nil
}
