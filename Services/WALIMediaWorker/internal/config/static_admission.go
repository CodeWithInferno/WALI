package config

import (
	"context"
	"errors"
	"time"
)

const StaticMediaMinimumLifetime = 95 * time.Minute

// NewStaticMediaAdmission caches only the expiry of the existing validated
// credential. It does not verify a signature, issue a token, or renew one.
// The Storage provider remains responsible for authenticating the credential.
func NewStaticMediaAdmission(token, workerID string, now func() time.Time) (func(context.Context) error, error) {
	if now == nil {
		return nil, errors.New("static credential clock is required")
	}
	expiresAt, err := workerTokenExpiry(token, workerID, now())
	if err != nil {
		return nil, err
	}
	ready := func(ctx context.Context) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !expiresAt.After(now().Add(StaticMediaMinimumLifetime)) {
			return errors.New("static Storage credential cannot cover the media execution budget")
		}
		return nil
	}
	if err := ready(context.Background()); err != nil {
		return nil, err
	}
	return ready, nil
}
