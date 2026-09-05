package storage

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
)

const maximumTransferBytes = int64(2 << 30)

var (
	ErrObjectIntegrity = errors.New("object integrity verification failed")
	ErrObjectMissing   = errors.New("object is missing")
)

type RawObjectRef struct {
	Bucket         string `json:"bucket"`
	Path           string `json:"path"`
	ByteCount      int64  `json:"byte_count"`
	StorageVersion string `json:"storage_version"`
}

type ObservedObject struct {
	Digest    string
	ByteCount int64
}

type ImmutableObjectRef struct {
	Bucket    string
	Path      string
	Digest    string
	ByteCount int64
}

type PublishRequest struct {
	LocalPath  string
	Bucket     string
	ObjectPath string
	Digest     string
	ByteCount  int64
	MediaType  string
	CreateOnly bool
}

type BlobStore interface {
	Download(context.Context, RawObjectRef, string) (ObservedObject, error)
	Publish(context.Context, PublishRequest) error
}

type PromotionStore interface {
	DownloadVerified(context.Context, ImmutableObjectRef, string) error
	Publish(context.Context, PublishRequest) error
}

type ObjectDeleter interface {
	Delete(context.Context, string, string) error
}

type Client struct {
	baseURL        *url.URL
	publishableKey string
	token          string
	httpClient     *http.Client
}

func NewClient(rawURL, publishableKey, token string, httpClient *http.Client) (*Client, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("storage URL must be an origin-only HTTPS URL")
	}
	if publishableKey == "" || len(publishableKey) > 2048 || strings.ContainsAny(publishableKey, "\r\n \t") || token == "" || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("storage token is missing or invalid")
	}
	if httpClient == nil {
		httpClient = &http.Client{}
	}
	clientCopy := *httpClient
	clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("storage redirects are forbidden")
	}
	return &Client{baseURL: parsed, publishableKey: publishableKey, token: token, httpClient: &clientCopy}, nil
}

func (c *Client) Download(ctx context.Context, object RawObjectRef, destination string) (ObservedObject, error) {
	if err := validateRawObjectRef(object); err != nil {
		return ObservedObject{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.objectURL(object.Bucket, object.Path), nil)
	if err != nil {
		return ObservedObject{}, err
	}
	c.authorize(request)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return ObservedObject{}, fmt.Errorf("download object: %w", err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme || response.Request.URL.Host != c.baseURL.Host {
		return ObservedObject{}, errors.New("download redirected outside configured storage origin")
	}
	if response.StatusCode != http.StatusOK {
		return ObservedObject{}, fmt.Errorf("download object: unexpected status %d", response.StatusCode)
	}

	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return ObservedObject{}, fmt.Errorf("create exclusive download: %w", err)
	}
	keep := false
	defer func() {
		if !keep {
			_ = os.Remove(destination)
		}
	}()
	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(response.Body, object.ByteCount+1))
	closeErr := file.Close()
	if copyErr != nil {
		return ObservedObject{}, fmt.Errorf("download object bytes: %w", copyErr)
	}
	if closeErr != nil {
		return ObservedObject{}, fmt.Errorf("close downloaded object: %w", closeErr)
	}
	if written != object.ByteCount {
		return ObservedObject{}, fmt.Errorf("downloaded byte count mismatch: got %d want %d", written, object.ByteCount)
	}
	keep = true
	return ObservedObject{Digest: hex.EncodeToString(hasher.Sum(nil)), ByteCount: written}, nil
}

func (c *Client) DownloadVerified(ctx context.Context, object ImmutableObjectRef, destination string) error {
	if err := validatePublishedObject(object.Bucket, object.Path, object.Digest, object.ByteCount); err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.objectURL(object.Bucket, object.Path), nil)
	if err != nil {
		return err
	}
	c.authorize(request)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("download immutable object: %w", err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme || response.Request.URL.Host != c.baseURL.Host {
		return errors.New("immutable download redirected outside configured storage origin")
	}
	if response.StatusCode == http.StatusNotFound {
		return fmt.Errorf("%w: immutable object", ErrObjectMissing)
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("download immutable object: unexpected status %d", response.StatusCode)
	}
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create immutable download: %w", err)
	}
	keep := false
	defer func() {
		if !keep {
			_ = os.Remove(destination)
		}
	}()
	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(response.Body, object.ByteCount+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return errors.New("read immutable object")
	}
	if written != object.ByteCount || hex.EncodeToString(hasher.Sum(nil)) != object.Digest {
		return fmt.Errorf("%w: immutable source differs from frozen intent", ErrObjectIntegrity)
	}
	keep = true
	return nil
}

func (c *Client) Publish(ctx context.Context, publication PublishRequest) error {
	if !publication.CreateOnly {
		return errors.New("publication must be create-only")
	}
	if err := validatePublishedObject(publication.Bucket, publication.ObjectPath, publication.Digest, publication.ByteCount); err != nil {
		return err
	}
	file, err := os.Open(publication.LocalPath)
	if err != nil {
		return fmt.Errorf("open publication: %w", err)
	}
	defer file.Close()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.objectURL(publication.Bucket, publication.ObjectPath), file)
	if err != nil {
		return err
	}
	c.authorize(request)
	request.ContentLength = publication.ByteCount
	request.Header.Set("Content-Type", publication.MediaType)
	request.Header.Set("x-upsert", "false")
	request.Header.Set("x-wali-sha256", publication.Digest)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("publish object: %w", err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme || response.Request.URL.Host != c.baseURL.Host {
		return errors.New("publish redirected outside configured storage origin")
	}
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		return c.verifyExisting(ctx, publication)
	}
	if !isExistingObjectResponse(response) {
		return fmt.Errorf("publish object: unexpected status %d", response.StatusCode)
	}
	return c.verifyExisting(ctx, publication)
}

func isExistingObjectResponse(response *http.Response) bool {
	if response.StatusCode == http.StatusConflict || response.StatusCode == http.StatusPreconditionFailed {
		return true
	}
	if response.StatusCode != http.StatusBadRequest {
		return false
	}
	// Supabase also returns its legacy 400 envelope for create-only collisions.
	// A collision is successful only after verifyExisting checks all stored bytes.
	var failure struct {
		Code  string `json:"code"`
		Error string `json:"error"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 4096))
	if decoder.Decode(&failure) != nil {
		return false
	}
	return failure.Code == "KeyAlreadyExists" || failure.Code == "ResourceAlreadyExists" || failure.Error == "Duplicate"
}

func (c *Client) Delete(ctx context.Context, bucket, objectPath string) error {
	if err := validateObjectLocation(bucket, objectPath); err != nil {
		return err
	}
	body, err := json.Marshal(struct {
		Prefixes []string `json:"prefixes"`
	}{[]string{objectPath}})
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, c.objectURL(bucket, ""), bytes.NewReader(body))
	if err != nil {
		return err
	}
	c.authorize(request)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("delete object: %w", err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme || response.Request.URL.Host != c.baseURL.Host {
		return errors.New("delete redirected outside configured storage origin")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("delete object: unexpected status %d", response.StatusCode)
	}
	check, err := http.NewRequestWithContext(ctx, http.MethodGet, c.objectURL(bucket, objectPath), nil)
	if err != nil {
		return err
	}
	c.authorize(check)
	verification, err := c.httpClient.Do(check)
	if err != nil {
		return fmt.Errorf("verify object deletion: %w", err)
	}
	defer verification.Body.Close()
	if verification.StatusCode != http.StatusNotFound {
		return errors.New("deleted object remains readable")
	}
	return nil
}

func (c *Client) verifyExisting(ctx context.Context, publication PublishRequest) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.objectURL(publication.Bucket, publication.ObjectPath), nil)
	if err != nil {
		return err
	}
	c.authorize(request)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("verify existing object: %w", err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme || response.Request.URL.Host != c.baseURL.Host {
		return errors.New("verification redirected outside configured storage origin")
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("verify existing object: unexpected status %d", response.StatusCode)
	}
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(response.Body, publication.ByteCount+1))
	if err != nil {
		return fmt.Errorf("verify existing object bytes: %w", err)
	}
	if written != publication.ByteCount || hex.EncodeToString(hasher.Sum(nil)) != publication.Digest {
		return fmt.Errorf("%w: stored object differs from publication", ErrObjectIntegrity)
	}
	return nil
}

func (c *Client) authorize(request *http.Request) {
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("apikey", c.publishableKey)
}

func (c *Client) objectURL(bucket, objectPath string) string {
	copyURL := *c.baseURL
	copyURL.Path = strings.TrimSuffix(copyURL.Path, "/") + "/storage/v1/object/" + bucket + "/" + objectPath
	return copyURL.String()
}

func validateRawObjectRef(object RawObjectRef) error {
	if object.Bucket == "" || strings.ContainsAny(object.Bucket, "/\\:\x00\r\n") {
		return errors.New("bucket is invalid")
	}
	if object.Path == "" || path.IsAbs(object.Path) || path.Clean(object.Path) != object.Path || strings.Contains(object.Path, "../") || strings.ContainsAny(object.Path, "\\\x00\r\n") {
		return errors.New("object path is not a clean relative path")
	}
	if object.ByteCount <= 0 || object.ByteCount > maximumTransferBytes {
		return errors.New("object byte count is out of bounds")
	}
	if object.StorageVersion == "" || len(object.StorageVersion) > 128 || strings.ContainsAny(object.StorageVersion, "/\\:\x00\r\n\t ") {
		return errors.New("storage version is invalid")
	}
	return nil
}

func validatePublishedObject(bucket, objectPath, digest string, byteCount int64) error {
	if err := validateObjectLocation(bucket, objectPath); err != nil {
		return err
	}
	if len(digest) != 64 {
		return errors.New("object digest must be lowercase SHA-256")
	}
	if _, err := hex.DecodeString(digest); err != nil || digest != strings.ToLower(digest) {
		return errors.New("object digest must be lowercase SHA-256")
	}
	if byteCount <= 0 || byteCount > maximumTransferBytes {
		return errors.New("object byte count is out of bounds")
	}
	return nil
}

func validateObjectLocation(bucket, objectPath string) error {
	if bucket == "" || strings.ContainsAny(bucket, "/\\:\x00\r\n") {
		return errors.New("bucket is invalid")
	}
	if objectPath == "" || path.IsAbs(objectPath) || path.Clean(objectPath) != objectPath || strings.Contains(objectPath, "../") || strings.ContainsAny(objectPath, "\\\x00\r\n") {
		return errors.New("object path is not a clean relative path")
	}
	return nil
}

func ImmutablePath(digest, role, relativePath string) (string, error) {
	if len(digest) != 64 {
		return "", errors.New("digest must be SHA-256")
	}
	extension := path.Ext(relativePath)
	if extension != ".jpg" && extension != ".png" && extension != ".mp4" {
		return "", errors.New("artifact extension is not allowed")
	}
	if role == "" || strings.ContainsAny(role, "/\\.:\x00\r\n") {
		return "", errors.New("artifact role is invalid")
	}
	if _, err := hex.DecodeString(digest); err != nil || digest != strings.ToLower(digest) {
		return "", errors.New("digest must be lowercase hexadecimal")
	}
	// SQL upload intents use URL filename tokens (video-default), while the
	// immutable artifact role remains video_default in the wire contract.
	filenameRole := strings.ReplaceAll(role, "_", "-")
	return "sha256/" + digest[:2] + "/" + digest[2:4] + "/" + digest + "/" + filenameRole + extension, nil
}
