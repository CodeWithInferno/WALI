package health

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"
)

var safeCodePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

type Metrics struct {
	mu            sync.Mutex
	total         uint64
	bySafeCode    map[string]uint64
	durationTotal time.Duration
}
type Snapshot struct {
	Total         uint64
	BySafeCode    map[string]uint64
	DurationTotal time.Duration
}

func NewMetrics() *Metrics { return &Metrics{bySafeCode: make(map[string]uint64)} }
func (metrics *Metrics) Record(safeCode string, duration time.Duration) {
	if !safeCodePattern.MatchString(safeCode) {
		safeCode = "invalid_safe_code"
	}
	if duration < 0 {
		duration = 0
	}
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.total++
	metrics.bySafeCode[safeCode]++
	metrics.durationTotal += duration
}
func (metrics *Metrics) Snapshot() Snapshot {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	counts := make(map[string]uint64, len(metrics.bySafeCode))
	for code, count := range metrics.bySafeCode {
		counts[code] = count
	}
	return Snapshot{metrics.total, counts, metrics.durationTotal}
}

type Readiness interface {
	Ready(context.Context) error
}

type handler struct {
	metrics   *Metrics
	readiness Readiness
}

func NewHandler(metrics *Metrics, readiness Readiness) (http.Handler, error) {
	if metrics == nil || readiness == nil {
		return nil, errors.New("health dependencies are required")
	}
	return &handler{metrics: metrics, readiness: readiness}, nil
}

func (h *handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Cache-Control", "no-store")
	if request.Method != http.MethodGet {
		http.NotFound(writer, request)
		return
	}
	switch request.URL.Path {
	case "/healthz":
		h.serveHealth(writer, request)
	case "/metrics":
		h.serveMetrics(writer)
	default:
		http.NotFound(writer, request)
	}
}

func (h *handler) serveHealth(writer http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
	defer cancel()
	writer.Header().Set("Content-Type", "application/json")
	if h.readiness.Ready(ctx) != nil {
		writer.WriteHeader(http.StatusServiceUnavailable)
		_, _ = writer.Write([]byte("{\"status\":\"unavailable\"}\n"))
		return
	}
	_, _ = writer.Write([]byte("{\"status\":\"ok\"}\n"))
}

func (h *handler) serveMetrics(writer http.ResponseWriter) {
	snapshot := h.metrics.Snapshot()
	writer.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = fmt.Fprintf(writer, "# TYPE wali_worker_jobs_total counter\nwali_worker_jobs_total %d\n", snapshot.Total)
	_, _ = fmt.Fprintf(writer, "# TYPE wali_worker_job_duration_seconds_total counter\nwali_worker_job_duration_seconds_total %s\n", strconv.FormatFloat(snapshot.DurationTotal.Seconds(), 'f', 6, 64))
	codes := make([]string, 0, len(snapshot.BySafeCode))
	for code := range snapshot.BySafeCode {
		codes = append(codes, code)
	}
	sort.Strings(codes)
	_, _ = writer.Write([]byte("# TYPE wali_worker_jobs_by_safe_code_total counter\n"))
	for _, code := range codes {
		_, _ = fmt.Fprintf(writer, "wali_worker_jobs_by_safe_code_total{safe_code=%q} %d\n", code, snapshot.BySafeCode[code])
	}
}

func ServeUnix(ctx context.Context, socketPath string, handler http.Handler) error {
	if handler == nil {
		return errors.New("health handler is required")
	}
	if info, err := os.Lstat(socketPath); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("health socket path already exists and is not a socket")
		}
		if err := os.Remove(socketPath); err != nil {
			return fmt.Errorf("remove stale health socket: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect health socket: %w", err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on health socket: %w", err)
	}
	defer listener.Close()
	defer os.Remove(socketPath)
	if err := os.Chmod(socketPath, 0o600); err != nil {
		return fmt.Errorf("secure health socket: %w", err)
	}

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 2 * time.Second,
		IdleTimeout:       5 * time.Second,
		MaxHeaderBytes:    4 << 10,
	}
	stopped := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			shutdownContext, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = server.Shutdown(shutdownContext)
			cancel()
		case <-stopped:
		}
	}()
	err = server.Serve(listener)
	close(stopped)
	if errors.Is(err, http.ErrServerClosed) && ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}
