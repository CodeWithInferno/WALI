package storage

import (
	"context"
	"database/sql"
)

// DatabaseCredentialIssuer uses only the existing authenticated worker session.
// Its no-argument function chooses every claim; no issuer key reaches this process.
type DatabaseCredentialIssuer struct{ database *sql.DB }

func NewDatabaseCredentialIssuer(database *sql.DB) (*DatabaseCredentialIssuer, error) {
	if database == nil {
		return nil, ErrCredentialsUnavailable
	}
	return &DatabaseCredentialIssuer{database: database}, nil
}
func (i *DatabaseCredentialIssuer) Issue(ctx context.Context) (Credential, error) {
	var value Credential
	if err := i.database.QueryRowContext(ctx, `select access_token, expires_at, worker_id from wali.renew_storage_worker_token()`).Scan(&value.AccessToken, &value.ExpiresAt, &value.WorkerID); err != nil {
		if ctx.Err() != nil {
			return Credential{}, ctx.Err()
		}
		return Credential{}, ErrCredentialsUnavailable
	}
	return value, nil
}
