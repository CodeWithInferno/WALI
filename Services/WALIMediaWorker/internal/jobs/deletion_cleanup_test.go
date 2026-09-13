package jobs_test

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
)

func TestConsentedPublicCleanupRequiresExactLeasedContentAddress(t *testing.T) {
	objectPath := "sha256/aa/aa/" + strings.Repeat("a", 64) + "/poster.jpg"
	job := jobs.CleanupJob{SchemaVersion: 1, Kind: "storage_object", CleanupID: "44444444-4444-4444-8444-444444444444"}
	lease := jobs.Lease{Owner: "deletion-test", ExpiresAt: time.Date(2030, 1, 1, 0, 5, 0, 0, time.UTC)}
	for _, test := range []struct {
		name, payload string
		valid         bool
	}{
		{"exact public lease", `{"disposition":"started","bucket":"catalog-public","path":"` + objectPath + `"}`, true},
		{"wrong hash directories", `{"disposition":"started","bucket":"catalog-public","path":"` + strings.Replace(objectPath, "/aa/aa/", "/bb/aa/", 1) + `"}`, false},
		{"caller path", `{"disposition":"started","bucket":"catalog-public","path":"other/source.mp4"}`, false},
		{"URL", `{"disposition":"started","bucket":"catalog-public","path":"https://example.invalid/source.mp4"}`, false},
		{"active has no path", `{"disposition":"active"}`, true},
		{"completed has no path", `{"disposition":"completed"}`, true},
		{"active cannot transfer authority", `{"disposition":"active","bucket":"catalog-public","path":"` + objectPath + `"}`, false},
		{"unknown field", `{"disposition":"started","bucket":"catalog-public","path":"` + objectPath + `","user_id":"other"}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			db := sql.OpenDB(cleanupLeaseConnector{payload: test.payload, job: job, lease: lease})
			t.Cleanup(func() { _ = db.Close() })
			store, err := jobs.NewSQLAttemptStore(db)
			if err != nil {
				t.Fatal(err)
			}
			begin, err := store.BeginCleanup(context.Background(), job, lease)
			if !test.valid {
				if err == nil {
					t.Fatal("unbounded cleanup authority accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if begin.Disposition == "started" && (begin.Bucket != "catalog-public" || begin.Path != objectPath) {
				t.Fatal("exact target changed")
			}
		})
	}
}

type cleanupLeaseConnector struct {
	payload string
	job     jobs.CleanupJob
	lease   jobs.Lease
}

func (c cleanupLeaseConnector) Connect(context.Context) (driver.Conn, error) {
	return cleanupLeaseConn{c}, nil
}
func (c cleanupLeaseConnector) Driver() driver.Driver { return cleanupLeaseDriver{c} }

type cleanupLeaseDriver struct{ connector cleanupLeaseConnector }

func (d cleanupLeaseDriver) Open(string) (driver.Conn, error) {
	return cleanupLeaseConn{d.connector}, nil
}

type cleanupLeaseConn struct{ connector cleanupLeaseConnector }

func (cleanupLeaseConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (cleanupLeaseConn) Close() error              { return nil }
func (cleanupLeaseConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected transaction") }
func (c cleanupLeaseConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if query != `select wali.worker_begin_cleanup($1, $2, $3)` || len(args) != 3 || args[0].Value != c.connector.job.CleanupID || args[1].Value != c.connector.lease.Owner || args[2].Value != c.connector.lease.ExpiresAt {
		return nil, errors.New("cleanup lease binding changed")
	}
	return &exportLeaseRows{payload: c.connector.payload}, nil
}
