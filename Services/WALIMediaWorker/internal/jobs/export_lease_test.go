package jobs_test

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
)

func TestSQLExportLeaseUsesDispositionSpecificPath(t *testing.T) {
	job := jobs.ExportJob{SchemaVersion: 1, ExportID: "11111111-1111-4111-8111-111111111111", UserID: "22222222-2222-4222-8222-222222222222"}
	lease := jobs.Lease{Owner: "export-fixture", ExpiresAt: time.Date(2030, 1, 1, 0, 5, 0, 0, time.UTC)}
	path := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	cases := []struct {
		name, payload, disposition string
		valid                      bool
		action                     jobs.Action
	}{
		// These are the actual worker_begin_export response shapes. A path is
		// returned only after this caller has acquired a started lease.
		{"started", `{"disposition":"started","path":"` + path + `"}`, "started", true, 0},
		{"active redelivery", `{"disposition":"active"}`, "active", true, jobs.ActionLeave},
		{"completed redelivery", `{"disposition":"completed"}`, "completed", true, jobs.ActionAck},
		{"stale redelivery", `{"disposition":"stale"}`, "stale", true, jobs.ActionAck},
		{"started missing path", `{"disposition":"started"}`, "", false, 0},
		{"started foreign path", `{"disposition":"started","path":"exports/another-user/account.json"}`, "", false, 0},
		{"active unexpected path", `{"disposition":"active","path":"` + path + `"}`, "", false, 0},
		{"completed unexpected path", `{"disposition":"completed","path":"` + path + `"}`, "", false, 0},
		{"stale unexpected path", `{"disposition":"stale","path":"` + path + `"}`, "", false, 0},
		{"unknown disposition", `{"disposition":"other","path":"` + path + `"}`, "", false, 0},
		{"unknown field", `{"disposition":"completed","other":true}`, "", false, 0},
		{"trailing response", `{"disposition":"completed"} {}`, "", false, 0},
		{"wrong path type", `{"disposition":"started","path":42}`, "", false, 0},
		{"invalid JSON", `{`, "", false, 0},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			connector := exportLeaseConnector{payload: test.payload, job: job, lease: lease}
			db := sql.OpenDB(connector)
			t.Cleanup(func() { _ = db.Close() })
			store, err := jobs.NewSQLAttemptStore(db)
			if err != nil {
				t.Fatal(err)
			}
			begin, err := store.BeginExport(context.Background(), job, lease)
			if !test.valid {
				if err == nil {
					t.Fatal("invalid SQL lease response accepted")
				}
				return
			}
			if err != nil || begin.Disposition != test.disposition {
				t.Fatalf("valid SQL lease response rejected: begin=%+v error=%v", begin, err)
			}
			if test.disposition == "started" {
				if begin.Path != path {
					t.Fatal("started lease lost its exact path")
				}
				return
			}
			// Exercise the real adapter together with the processor. No data
			// projection, object publication, or completion may follow redelivery.
			blobs := &fakeBlobs{}
			processor, err := jobs.NewExportProcessor(store, blobs, t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			result := processor.Process(context.Background(), job, lease)
			if result.Action != test.action || len(blobs.published) != 0 {
				t.Fatalf("redelivery result=%+v published=%d", result, len(blobs.published))
			}
		})
	}
}

type exportLeaseConnector struct {
	payload string
	job     jobs.ExportJob
	lease   jobs.Lease
}

func (c exportLeaseConnector) Connect(context.Context) (driver.Conn, error) {
	return exportLeaseConn{c}, nil
}
func (c exportLeaseConnector) Driver() driver.Driver { return exportLeaseDriver{c} }

type exportLeaseDriver struct{ connector exportLeaseConnector }

func (d exportLeaseDriver) Open(string) (driver.Conn, error) {
	return exportLeaseConn{d.connector}, nil
}

type exportLeaseConn struct{ connector exportLeaseConnector }

func (exportLeaseConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (exportLeaseConn) Close() error              { return nil }
func (exportLeaseConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected transaction") }
func (c exportLeaseConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if query != `select wali.worker_begin_export($1, $2, $3, $4)` || len(args) != 4 ||
		args[0].Value != c.connector.job.ExportID || args[1].Value != c.connector.job.UserID ||
		args[2].Value != c.connector.lease.Owner || args[3].Value != c.connector.lease.ExpiresAt {
		return nil, errors.New("unexpected export SQL command or lease binding")
	}
	return &exportLeaseRows{payload: c.connector.payload}, nil
}

type exportLeaseRows struct {
	payload string
	done    bool
}

func (*exportLeaseRows) Columns() []string { return []string{"worker_begin_export"} }
func (*exportLeaseRows) Close() error      { return nil }
func (r *exportLeaseRows) Next(values []driver.Value) error {
	if r.done {
		return io.EOF
	}
	r.done = true
	values[0] = []byte(r.payload)
	return nil
}
