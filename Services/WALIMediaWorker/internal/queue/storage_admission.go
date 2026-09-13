package queue

import (
	"context"
	"errors"
	"time"
)

type storageGatedBackend struct {
	Backend
	ready     func(context.Context) error
	mediaOnly bool
}

// NewStorageGatedBackend pauses new Storage leases without stopping consumers.
// Existing Ack/Nack/Reject recovery and DB-only account deletion remain available.
func NewStorageGatedBackend(backend Backend, ready func(context.Context) error) (Backend, error) {
	if backend == nil || ready == nil {
		return nil, errors.New("queue backend and storage readiness are required")
	}
	return &storageGatedBackend{Backend: backend, ready: ready}, nil
}

// NewMediaAdmissionGatedBackend restricts only new media work. Other queues
// and terminal operations retain their existing behavior when a fixed token
// no longer has enough time for another complete media attempt.
func NewMediaAdmissionGatedBackend(backend Backend, ready func(context.Context) error) (Backend, error) {
	if backend == nil || ready == nil {
		return nil, errors.New("queue backend and media readiness are required")
	}
	return &storageGatedBackend{Backend: backend, ready: ready, mediaOnly: true}, nil
}
func (b *storageGatedBackend) Read(ctx context.Context, name string, visibility time.Duration) (Message, bool, error) {
	if err := ctx.Err(); err != nil {
		return Message{}, false, err
	}
	if b.mediaOnly && name != "wali_media_processing" {
		return b.Backend.Read(ctx, name, visibility)
	}
	switch name {
	case "wali_media_processing", "wali_exports", "wali_promotions", "wali_cleanup", "wali_backup_verification":
		if err := b.ready(ctx); err != nil {
			if ctx.Err() != nil {
				return Message{}, false, ctx.Err()
			}
			return Message{}, false, nil
		}
	}
	return b.Backend.Read(ctx, name, visibility)
}
