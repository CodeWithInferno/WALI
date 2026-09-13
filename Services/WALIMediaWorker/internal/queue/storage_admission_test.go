package queue

import (
	"context"
	"errors"
	"testing"
	"time"
)

type admissionBackend struct{ reads, acks, nacks, rejects int }

func (b *admissionBackend) Read(context.Context, string, time.Duration) (Message, bool, error) {
	b.reads++
	return Message{ID: 42}, true, nil
}
func (b *admissionBackend) Ack(context.Context, string, int64) error { b.acks++; return nil }
func (b *admissionBackend) Nack(context.Context, string, int64, time.Duration) error {
	b.nacks++
	return nil
}
func (b *admissionBackend) Reject(context.Context, string, int64, string) error {
	b.rejects++
	return nil
}
func TestUnavailableCredentialsDoNotClaimStorageJobsAndRecover(t *testing.T) {
	inner := &admissionBackend{}
	unavailable := true
	gated, err := NewStorageGatedBackend(inner, func(context.Context) error {
		if unavailable {
			return errors.New("unavailable")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"wali_media_processing", "wali_exports", "wali_promotions", "wali_cleanup", "wali_backup_verification"} {
		_, found, err := gated.Read(context.Background(), name, time.Minute)
		if err != nil || found {
			t.Fatalf("unavailable %s claimed work or stopped consumer", name)
		}
	}
	if inner.reads != 0 {
		t.Fatal("unavailable credentials reached queue")
	}
	if _, found, err := gated.Read(context.Background(), "wali_account_deletions", time.Minute); err != nil || !found {
		t.Fatal("DB-only account work unnecessarily blocked")
	}
	if err := gated.Ack(context.Background(), "wali_media_processing", 1); err != nil {
		t.Fatal(err)
	}
	if err := gated.Nack(context.Background(), "wali_media_processing", 1, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := gated.Reject(context.Background(), "wali_media_processing", 1, "invalid"); err != nil {
		t.Fatal(err)
	}
	if inner.acks != 1 || inner.nacks != 1 || inner.rejects != 1 {
		t.Fatal("terminal operations blocked")
	}
	unavailable = false
	if message, found, err := gated.Read(context.Background(), "wali_media_processing", time.Minute); err != nil || !found || message.ID != 42 {
		t.Fatal("renewal did not resume queue")
	}
}
func TestStorageAdmissionCancellationAndRequiredInputs(t *testing.T) {
	inner := &admissionBackend{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	gated, _ := NewStorageGatedBackend(inner, func(ctx context.Context) error { return ctx.Err() })
	if _, _, err := gated.Read(ctx, "wali_media_processing", time.Minute); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation swallowed")
	}
	if inner.reads != 0 {
		t.Fatal("cancelled queue read reached DB")
	}
	if _, err := NewStorageGatedBackend(nil, func(context.Context) error { return nil }); err == nil {
		t.Fatal("nil backend accepted")
	}
	if _, err := NewStorageGatedBackend(inner, nil); err == nil {
		t.Fatal("nil readiness accepted")
	}
}
