package storage

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

type issuanceConnector struct {
	query      *string
	queryError error
	expires    time.Time
}

func (c issuanceConnector) Connect(context.Context) (driver.Conn, error) { return issuanceConn{c}, nil }
func (c issuanceConnector) Driver() driver.Driver                        { return issuanceDriver{c} }

type issuanceDriver struct{ c issuanceConnector }

func (d issuanceDriver) Open(string) (driver.Conn, error) { return issuanceConn{d.c}, nil }

type issuanceConn struct{ c issuanceConnector }

func (c issuanceConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("unsupported") }
func (c issuanceConn) Close() error                        { return nil }
func (c issuanceConn) Begin() (driver.Tx, error)           { return nil, errors.New("unsupported") }
func (c issuanceConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	*c.c.query = query
	if len(args) != 0 {
		return nil, errors.New("caller controlled issuance arguments")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if c.c.queryError != nil {
		return nil, c.c.queryError
	}
	return &issuanceRows{expires: c.c.expires}, nil
}

type issuanceRows struct {
	done    bool
	expires time.Time
}

func (*issuanceRows) Columns() []string { return []string{"access_token", "expires_at", "worker_id"} }
func (*issuanceRows) Close() error      { return nil }
func (r *issuanceRows) Next(values []driver.Value) error {
	if r.done {
		return io.EOF
	}
	r.done = true
	values[0] = "synthetic-token"
	values[1] = r.expires
	values[2] = "worker-1"
	return nil
}
func TestDatabaseCredentialIssuerUsesPrivateFixedQueryAndRedactsFailures(t *testing.T) {
	for _, failure := range []error{nil, errors.New("secret-must-never-leak")} {
		var query string
		expires := time.Now().Truncate(time.Second).Add(15 * time.Minute)
		db := sql.OpenDB(issuanceConnector{&query, failure, expires})
		issuer, err := NewDatabaseCredentialIssuer(db)
		if err != nil {
			t.Fatal(err)
		}
		value, err := issuer.Issue(context.Background())
		db.Close()
		if query != `select access_token, expires_at, worker_id from wali.renew_storage_worker_token()` {
			t.Fatal("issuance contract changed")
		}
		if failure != nil {
			if !errors.Is(err, ErrCredentialsUnavailable) || strings.Contains(err.Error(), "secret-must-never-leak") || value.AccessToken != "" {
				t.Fatal("database error exposed or token retained")
			}
		} else if err != nil || value.WorkerID != "worker-1" || !value.ExpiresAt.Equal(expires) {
			t.Fatal("issuer envelope lost")
		}
	}
	if _, err := NewDatabaseCredentialIssuer(nil); !errors.Is(err, ErrCredentialsUnavailable) {
		t.Fatal("nil database accepted")
	}
}
