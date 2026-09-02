package storage_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/maintenance"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func sha(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestDownloadUsesOpaqueURLAndExclusiveVerifiedDestination(t *testing.T) {
	data := []byte("opaque-media")
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.EscapedPath() != "/storage/v1/object/uploads-private/creator%20id/object%23one" {
			t.Errorf("path = %q", request.URL.EscapedPath())
		}
		if request.Header.Get("Authorization") != "Bearer secret" {
			t.Errorf("authorization missing")
		}
		if request.Header.Get("apikey") != "publishable" {
			t.Errorf("publishable apikey missing or confused with worker authorization")
		}
		_, _ = writer.Write(data)
	}))
	defer server.Close()
	client, err := storage.NewClient(server.URL, "publishable", "secret", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "source.bin")
	ref := storage.RawObjectRef{Bucket: "uploads-private", Path: "creator id/object#one", ByteCount: int64(len(data)), StorageVersion: "server-version-1"}
	observed, err := client.Download(context.Background(), ref, destination)
	if err != nil {
		t.Fatal(err)
	}
	if observed.Digest != sha(data) || observed.ByteCount != int64(len(data)) {
		t.Fatalf("observed = %#v", observed)
	}
	got, err := os.ReadFile(destination)
	if err != nil || string(got) != string(data) {
		t.Fatalf("downloaded %q, %v", got, err)
	}
	if _, err := client.Download(context.Background(), ref, destination); err == nil || !strings.Contains(err.Error(), "exclusive") {
		t.Fatalf("expected exclusive destination rejection, got %v", err)
	}
}

func TestDownloadRejectsByteCountMismatchAndRemovesPartialFile(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) { _, _ = writer.Write([]byte("wrong")) }))
	defer server.Close()
	client, _ := storage.NewClient(server.URL, "publishable", "secret", server.Client())
	destination := filepath.Join(t.TempDir(), "source.bin")
	_, err := client.Download(context.Background(), storage.RawObjectRef{Bucket: "uploads-private", Path: "opaque", ByteCount: 4, StorageVersion: "server-version-1"}, destination)
	if err == nil || !strings.Contains(err.Error(), "byte count mismatch") {
		t.Fatalf("expected byte-count mismatch, got %v", err)
	}
	if _, statErr := os.Stat(destination); !os.IsNotExist(statErr) {
		t.Fatalf("partial download remained: %v", statErr)
	}
}

func TestStorageRedirectCannotReceiveWorkerCredentials(t *testing.T) {
	var requests atomic.Int32
	var leaked atomic.Bool
	transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requests.Add(1)
		if request.URL.Host == "attacker.example.test" {
			if request.Header.Get("Authorization") != "" || request.Header.Get("apikey") != "" {
				leaked.Store(true)
			}
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("opaque")), Request: request}, nil
		}
		header := make(http.Header)
		header.Set("Location", "https://attacker.example.test/capture")
		return &http.Response{StatusCode: http.StatusFound, Header: header, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
	})
	client, err := storage.NewClient("https://storage.example.test", "publishable", "secret", &http.Client{Transport: transport})
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Download(context.Background(), storage.RawObjectRef{
		Bucket: "uploads-private", Path: "opaque", ByteCount: 6, StorageVersion: "server-version-1",
	}, filepath.Join(t.TempDir(), "source.bin"))
	if err == nil {
		t.Fatal("expected redirect rejection")
	}
	if leaked.Load() || requests.Load() != 1 {
		t.Fatalf("redirect leaked credentials=%t requests=%d", leaked.Load(), requests.Load())
	}
}

func TestPublishIsCreateOnlyAndReusesOnlyMatchingObject(t *testing.T) {
	data := []byte("artifact")
	var calls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		switch request.Method {
		case http.MethodPost:
			if request.Header.Get("x-upsert") != "false" {
				t.Errorf("x-upsert = %q", request.Header.Get("x-upsert"))
			}
			writer.WriteHeader(http.StatusConflict)
		case http.MethodGet:
			writer.Header().Set("Content-Length", "8")
			writer.Header().Set("x-wali-sha256", sha(data))
			_, _ = writer.Write(data)
		default:
			t.Errorf("method = %s", request.Method)
		}
	}))
	defer server.Close()
	client, _ := storage.NewClient(server.URL, "publishable", "secret", server.Client())
	file := filepath.Join(t.TempDir(), "poster.jpg")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	digest := sha(data)
	err := client.Publish(context.Background(), storage.PublishRequest{LocalPath: file, Bucket: "catalog-public", ObjectPath: "sha256/" + digest[:2] + "/" + digest[2:4] + "/" + digest + "/poster.jpg", Digest: digest, ByteCount: 8, MediaType: "image/jpeg", CreateOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("calls = %d", calls.Load())
	}
}

func TestPublishConflictRehashesExistingObjectInsteadOfTrustingMetadata(t *testing.T) {
	wanted := []byte("artifact")
	wrong := []byte("attacker")
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.Method {
		case http.MethodPost:
			writer.WriteHeader(http.StatusConflict)
		case http.MethodGet:
			writer.Header().Set("Content-Length", "8")
			writer.Header().Set("x-wali-sha256", sha(wanted))
			_, _ = writer.Write(wrong)
		default:
			t.Errorf("method = %s", request.Method)
		}
	}))
	defer server.Close()
	client, _ := storage.NewClient(server.URL, "publishable", "secret", server.Client())
	file := filepath.Join(t.TempDir(), "poster.jpg")
	if err := os.WriteFile(file, wanted, 0o600); err != nil {
		t.Fatal(err)
	}
	digest := sha(wanted)
	err := client.Publish(context.Background(), storage.PublishRequest{
		LocalPath: file, Bucket: "catalog-public", ObjectPath: "sha256/" + digest[:2] + "/" + digest[2:4] + "/" + digest + "/poster.jpg",
		Digest: digest, ByteCount: 8, MediaType: "image/jpeg", CreateOnly: true,
	})
	if !errors.Is(err, storage.ErrObjectIntegrity) {
		t.Fatalf("expected actual existing bytes to be rejected, got %v", err)
	}
}

func TestPublishSuccessRehashesStoredObjectInsteadOfTrustingUploadResponse(t *testing.T) {
	wanted := []byte("artifact")
	wrong := []byte("attacker")
	var calls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		switch request.Method {
		case http.MethodPost:
			writer.WriteHeader(http.StatusCreated)
		case http.MethodGet:
			writer.Header().Set("x-wali-sha256", sha(wanted))
			_, _ = writer.Write(wrong)
		default:
			t.Errorf("method = %s", request.Method)
		}
	}))
	defer server.Close()
	client, _ := storage.NewClient(server.URL, "publishable", "secret", server.Client())
	file := filepath.Join(t.TempDir(), "poster.jpg")
	if err := os.WriteFile(file, wanted, 0o600); err != nil {
		t.Fatal(err)
	}
	digest := sha(wanted)
	err := client.Publish(context.Background(), storage.PublishRequest{
		LocalPath: file, Bucket: "processing-private", ObjectPath: "sha256/" + digest[:2] + "/" + digest[2:4] + "/" + digest + "/poster.jpg",
		Digest: digest, ByteCount: int64(len(wanted)), MediaType: "image/jpeg", CreateOnly: true,
	})
	if !errors.Is(err, storage.ErrObjectIntegrity) || calls.Load() != 2 {
		t.Fatalf("expected post-write byte verification, calls=%d err=%v", calls.Load(), err)
	}
}

func TestDeleteUsesSeparatedAuthAndVerifiesObjectIsGone(t *testing.T) {
	const objectPath = "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/source"
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests++
		if request.Header.Get("Authorization") != "Bearer worker-jwt" || request.Header.Get("apikey") != "publishable" {
			t.Errorf("credentials were missing or confused")
		}
		switch request.Method {
		case http.MethodDelete:
			var body struct {
				Prefixes []string `json:"prefixes"`
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil || !reflect.DeepEqual(body.Prefixes, []string{objectPath}) {
				t.Errorf("delete body=%#v err=%v", body, err)
			}
			writer.WriteHeader(http.StatusOK)
		case http.MethodGet:
			writer.WriteHeader(http.StatusNotFound)
		default:
			t.Errorf("method=%s", request.Method)
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer server.Close()
	client, err := storage.NewClient(server.URL, "publishable", "worker-jwt", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Delete(context.Background(), "uploads-private", objectPath); err != nil {
		t.Fatal(err)
	}
	if requests != 2 {
		t.Fatalf("requests=%d", requests)
	}
	if err := client.Delete(context.Background(), "uploads-private", "../source"); err == nil {
		t.Fatal("unsafe delete path accepted")
	}
}

func TestImmutablePathRejectsRoleAndExtensionInjection(t *testing.T) {
	digest := strings.Repeat("a", 64)
	if _, err := storage.ImmutablePath(digest, "poster/../../x", "poster.jpg"); err == nil {
		t.Fatal("expected role rejection")
	}
	if _, err := storage.ImmutablePath(digest, "poster", "poster.svg"); err == nil {
		t.Fatal("expected extension rejection")
	}
	if _, err := storage.ImmutablePath("aaBB"+strings.Repeat("a", 60), "poster", "poster.jpg"); err == nil {
		t.Fatal("expected non-lowercase digest rejection")
	}
	got, err := storage.ImmutablePath(digest, "poster", "artifacts/poster.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if got != "sha256/aa/aa/"+digest+"/poster.jpg" {
		t.Fatalf("path = %q", got)
	}
}

type memorySource map[maintenance.ObjectKey][]byte

func (source memorySource) Open(_ context.Context, key maintenance.ObjectKey) (io.ReadCloser, error) {
	data, exists := source[key]
	if !exists {
		return nil, os.ErrNotExist
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}

type memoryArchive struct {
	objects map[string][]byte
	corrupt bool
}

func (archive *memoryArchive) PutIfAbsent(_ context.Context, key string, byteCount int64, body io.Reader) error {
	if _, exists := archive.objects[key]; exists {
		return os.ErrExist
	}
	data, err := io.ReadAll(io.LimitReader(body, byteCount+1))
	if err != nil || int64(len(data)) != byteCount {
		return errors.New("size mismatch")
	}
	archive.objects[key] = data
	return nil
}

func (archive *memoryArchive) Open(_ context.Context, key string) (io.ReadCloser, error) {
	data, exists := archive.objects[key]
	if !exists {
		return nil, os.ErrNotExist
	}
	copyData := append([]byte(nil), data...)
	if archive.corrupt && len(copyData) > 0 {
		copyData[0] ^= 0xff
	}
	return io.NopCloser(bytes.NewReader(copyData)), nil
}

type digestAttestor struct{}

func (digestAttestor) SignDigest(_ context.Context, digest string) (string, []byte, error) {
	return "backup-attestor-test", []byte(digest), nil
}

func TestBackupRunnerStreamsVerifiesSortsAndAttests(t *testing.T) {
	privateData := []byte("rights-proof")
	catalogData := []byte("poster")
	catalogDigest := sha(catalogData)
	catalogPath := "sha256/" + catalogDigest[:2] + "/" + catalogDigest[2:4] + "/" + catalogDigest + "/poster.jpg"
	privatePath := "rights/70000000-0000-4000-8000-000000000001/71000000-0000-4000-8000-000000000001/proof.pdf"
	source := memorySource{
		{Bucket: "catalog-public", Path: catalogPath}:     catalogData,
		{Bucket: "moderation-private", Path: privatePath}: privateData,
	}
	archive := &memoryArchive{objects: map[string][]byte{}}
	runner, err := maintenance.NewRunner(source, archive, digestAttestor{}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	report, err := runner.Run(context.Background(), "20260901T180000Z-a1b2c3d4e5f6", []maintenance.InventoryObject{
		{Bucket: "moderation-private", Path: privatePath, ByteCount: int64(len(privateData)), Class: maintenance.RetainedPrivateObject},
		{Bucket: "catalog-public", Path: catalogPath, Digest: catalogDigest, ByteCount: int64(len(catalogData)), Class: maintenance.CatalogObject},
	})
	if err != nil {
		t.Fatal(err)
	}
	if report.Body.Status != "passed" || report.Body.VerifiedCount != 2 || len(report.Body.Issues) != 0 {
		t.Fatalf("report = %#v", report)
	}
	if report.Body.Entries[0].Bucket != "catalog-public" || report.Body.Entries[1].Digest != sha(privateData) {
		t.Fatalf("entries are not deterministic or verified: %#v", report.Body.Entries)
	}
	body, _ := json.Marshal(report.Body)
	if report.BodySHA256 != sha(body) || report.Signature == "" || report.AttestationID != "backup-attestor-test" {
		t.Fatalf("attestation = %#v", report)
	}
}

func TestBackupRunnerReportsIndependentArchiveCorruption(t *testing.T) {
	data := []byte("poster")
	digest := sha(data)
	objectPath := "sha256/" + digest[:2] + "/" + digest[2:4] + "/" + digest + "/poster.jpg"
	runner, _ := maintenance.NewRunner(
		memorySource{{Bucket: "catalog-public", Path: objectPath}: data},
		&memoryArchive{objects: map[string][]byte{}, corrupt: true}, digestAttestor{}, t.TempDir(),
	)
	report, err := runner.Run(context.Background(), "20260901T180000Z-a1b2c3d4e5f6", []maintenance.InventoryObject{{
		Bucket: "catalog-public", Path: objectPath, Digest: digest,
		ByteCount: int64(len(data)), Class: maintenance.CatalogObject,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if report.Body.Status != "failed" || len(report.Body.Issues) != 1 || report.Body.Issues[0].Code != "archive_verification_failed" {
		t.Fatalf("report = %#v", report.Body)
	}
}

func TestReconcileReportsMissingCorruptAndUnreferencedObjects(t *testing.T) {
	expected := []maintenance.InventoryObject{
		{Bucket: "uploads-private", Path: "uploads/a/source", Digest: strings.Repeat("a", 64), ByteCount: 4, Class: maintenance.RetainedPrivateObject},
		{Bucket: "uploads-private", Path: "uploads/b/source", Digest: strings.Repeat("b", 64), ByteCount: 5, Class: maintenance.RetainedPrivateObject},
	}
	observed := []maintenance.InventoryObject{
		{Bucket: "uploads-private", Path: "uploads/a/source", Digest: strings.Repeat("c", 64), ByteCount: 6, Class: maintenance.RetainedPrivateObject},
		{Bucket: "uploads-private", Path: "uploads/c/source", Digest: strings.Repeat("d", 64), ByteCount: 7, Class: maintenance.RetainedPrivateObject},
	}
	issues := maintenance.Reconcile(expected, observed)
	codes := make([]string, 0, len(issues))
	for _, issue := range issues {
		codes = append(codes, issue.Code)
	}
	if strings.Join(codes, ",") != "byte_count_mismatch,digest_mismatch,missing_object,unreferenced_object" {
		t.Fatalf("issues = %#v", issues)
	}
}
