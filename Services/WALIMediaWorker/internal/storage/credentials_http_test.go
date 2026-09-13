package storage_test

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
)

type tokenSourceFunc func(context.Context) (string, error)

func (f tokenSourceFunc) Token(ctx context.Context) (string, error) { return f(ctx) }

func TestStorageRequestsResolveCurrentCredential(t *testing.T) {
	var calls atomic.Int32
	source := tokenSourceFunc(func(context.Context) (string, error) {
		if calls.Add(1) == 1 {
			return "first-fixture", nil
		}
		return "second-fixture", nil
	})
	var headers []string
	transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		headers = append(headers, request.Header.Get("Authorization"))
		if request.Header.Get("apikey") != "publishable" {
			t.Error("publishable key is missing")
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("data")), Request: request}, nil
	})
	client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: transport})
	if err != nil {
		t.Fatal(err)
	}
	ref := storage.RawObjectRef{Bucket: "uploads-private", Path: "fixture", ByteCount: 4, StorageVersion: "v1"}
	for range 2 {
		if _, err = client.Download(context.Background(), ref, filepath.Join(t.TempDir(), "source")); err != nil {
			t.Fatal(err)
		}
	}
	if len(headers) != 2 || headers[0] != "Bearer first-fixture" || headers[1] != "Bearer second-fixture" {
		t.Fatal("HTTP requests did not use the current credential")
	}
}

func TestUnavailableCredentialPreventsEveryStorageOperation(t *testing.T) {
	data := []byte("data")
	file := filepath.Join(t.TempDir(), "artifact")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"download", "immutable_download", "publish", "delete"} {
		t.Run(name, func(t *testing.T) {
			var requests atomic.Int32
			transport := roundTripFunc(func(*http.Request) (*http.Response, error) {
				requests.Add(1)
				return nil, errors.New("unexpected request")
			})
			source := tokenSourceFunc(func(context.Context) (string, error) { return "", errors.New("PRIVATE_ISSUER_DIAGNOSTIC") })
			client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: transport})
			if err != nil {
				t.Fatal(err)
			}
			destination := filepath.Join(t.TempDir(), "source")
			switch name {
			case "download":
				_, err = client.Download(context.Background(), storage.RawObjectRef{Bucket: "uploads-private", Path: "fixture", ByteCount: 4, StorageVersion: "v1"}, destination)
			case "immutable_download":
				err = client.DownloadVerified(context.Background(), storage.ImmutableObjectRef{Bucket: "catalog-public", Path: "fixture", Digest: sha(data), ByteCount: 4}, destination)
			case "publish":
				err = client.Publish(context.Background(), storage.PublishRequest{LocalPath: file, Bucket: "catalog-public", ObjectPath: "fixture", Digest: sha(data), ByteCount: 4, MediaType: "image/jpeg", CreateOnly: true})
			case "delete":
				err = client.Delete(context.Background(), "uploads-private", "fixture")
			}
			if !errors.Is(err, storage.ErrCredentialsUnavailable) || strings.Contains(err.Error(), "PRIVATE") || requests.Load() != 0 {
				t.Fatal("unavailable credential did not safely block HTTP")
			}
			if _, err = os.Stat(destination); !os.IsNotExist(err) {
				t.Fatal("failed authorization created download file")
			}
		})
	}
}

func TestStorageRejectsInvalidDynamicCredential(t *testing.T) {
	for _, token := range []string{"", "token\r\nx-secret: fixture", "white space", strings.Repeat("x", 4097)} {
		t.Run("invalid", func(t *testing.T) {
			var requests atomic.Int32
			client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", tokenSourceFunc(func(context.Context) (string, error) { return token, nil }), &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
				requests.Add(1)
				return nil, errors.New("unexpected request")
			})})
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.Download(context.Background(), storage.RawObjectRef{Bucket: "uploads-private", Path: "fixture", ByteCount: 4, StorageVersion: "v1"}, filepath.Join(t.TempDir(), "source"))
			if !errors.Is(err, storage.ErrCredentialsUnavailable) || requests.Load() != 0 {
				t.Fatal("invalid credential reached HTTP")
			}
		})
	}
}

func TestStoragePublicationVerificationRefreshesCredential(t *testing.T) {
	data := []byte("data")
	file := filepath.Join(t.TempDir(), "artifact")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	source := tokenSourceFunc(func(context.Context) (string, error) {
		if calls.Add(1) == 1 {
			return "post-fixture", nil
		}
		return "verification-fixture", nil
	})
	transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method == http.MethodPost {
			if request.Header.Get("Authorization") != "Bearer post-fixture" {
				t.Error("wrong upload credential")
			}
			return &http.Response{StatusCode: http.StatusCreated, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
		}
		if request.Method != http.MethodGet || request.Header.Get("Authorization") != "Bearer verification-fixture" {
			t.Error("verification reused the upload credential")
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("data")), Request: request}, nil
	})
	client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: transport})
	if err != nil {
		t.Fatal(err)
	}
	if err = client.Publish(context.Background(), storage.PublishRequest{LocalPath: file, Bucket: "catalog-public", ObjectPath: "fixture", Digest: sha(data), ByteCount: 4, MediaType: "image/jpeg", CreateOnly: true}); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("publication verification skipped current credential lookup")
	}
}

func TestStorageDoesNotReplayRejectedOrAmbiguousMutations(t *testing.T) {
	data := []byte("data")
	file := filepath.Join(t.TempDir(), "artifact")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodPost, http.MethodDelete} {
		for _, status := range []int{http.StatusUnauthorized, 0} {
			t.Run(method, func(t *testing.T) {
				var requests, credentials atomic.Int32
				source := tokenSourceFunc(func(context.Context) (string, error) { credentials.Add(1); return "fixture-token", nil })
				transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
					requests.Add(1)
					if status == 0 {
						return nil, errors.New("ambiguous transport failure")
					}
					return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
				})
				client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: transport})
				if err != nil {
					t.Fatal(err)
				}
				if method == http.MethodPost {
					err = client.Publish(context.Background(), storage.PublishRequest{LocalPath: file, Bucket: "catalog-public", ObjectPath: "fixture", Digest: sha(data), ByteCount: 4, MediaType: "image/jpeg", CreateOnly: true})
				} else {
					err = client.Delete(context.Background(), "uploads-private", "fixture")
				}
				if err == nil || requests.Load() != 1 || credentials.Load() != 1 {
					t.Fatal("mutation was automatically replayed")
				}
			})
		}
	}
}

func TestMutationIsNotAcknowledgedWithoutAuthorizedVerification(t *testing.T) {
	data := []byte("data")
	file := filepath.Join(t.TempDir(), "artifact")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodPost, http.MethodDelete} {
		t.Run(method, func(t *testing.T) {
			var requests, credentials atomic.Int32
			source := tokenSourceFunc(func(context.Context) (string, error) {
				if credentials.Add(1) == 1 {
					return "mutation-fixture", nil
				}
				return "", errors.New("PRIVATE_ISSUER_DIAGNOSTIC")
			})
			transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
				requests.Add(1)
				return &http.Response{StatusCode: http.StatusCreated, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
			})
			client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: transport})
			if err != nil {
				t.Fatal(err)
			}
			if method == http.MethodPost {
				err = client.Publish(context.Background(), storage.PublishRequest{LocalPath: file, Bucket: "catalog-public", ObjectPath: "fixture", Digest: sha(data), ByteCount: 4, MediaType: "image/jpeg", CreateOnly: true})
			} else {
				err = client.Delete(context.Background(), "uploads-private", "fixture")
			}
			if !errors.Is(err, storage.ErrCredentialsUnavailable) || strings.Contains(err.Error(), "PRIVATE") || requests.Load() != 1 || credentials.Load() != 2 {
				t.Fatal("unverified mutation was acknowledged or replayed")
			}
		})
	}
}

func TestStoragePreservesRequestCancellation(t *testing.T) {
	var requests, credentials atomic.Int32
	source := tokenSourceFunc(func(context.Context) (string, error) { credentials.Add(1); return "fixture-token", nil })
	client, err := storage.NewClientWithTokenSource("https://storage.example.test", "publishable", source, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		requests.Add(1)
		return nil, errors.New("unexpected request")
	})})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = client.Download(ctx, storage.RawObjectRef{Bucket: "uploads-private", Path: "fixture", ByteCount: 4, StorageVersion: "v1"}, filepath.Join(t.TempDir(), "source"))
	if !errors.Is(err, context.Canceled) || requests.Load() != 0 || credentials.Load() != 0 {
		t.Fatal("cancelled request started credential or HTTP work")
	}
}
