package queue

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestStaticMediaGateBlocksOnlyNewMediaAndPreservesRecovery(t *testing.T) {
	inner := &admissionBackend{}
	usable := true
	gated, err := NewMediaAdmissionGatedBackend(inner, func(context.Context) error {
		if !usable {
			return errors.New("expired for next media attempt")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, found, err := gated.Read(context.Background(), "wali_media_processing", time.Minute); err != nil || !found {
		t.Fatal("usable credential did not admit media")
	}
	usable = false
	reads := inner.reads
	if _, found, err := gated.Read(context.Background(), "wali_media_processing", time.Minute); err != nil || found || inner.reads != reads {
		t.Fatal("insufficient credential claimed media or stopped consumer")
	}
	for _, name := range []string{"wali_promotions", "wali_exports", "wali_cleanup", "wali_backup_verification", "wali_account_deletions"} {
		if _, found, err := gated.Read(context.Background(), name, time.Minute); err != nil || !found {
			t.Fatalf("unrelated queue %s was blocked", name)
		}
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
		t.Fatal("terminal recovery was blocked")
	}
}
func TestStaticMediaGateCancellationAndInputs(t *testing.T) {
	inner := &admissionBackend{}
	gated, _ := NewMediaAdmissionGatedBackend(inner, func(context.Context) error { return nil })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := gated.Read(ctx, "wali_media_processing", time.Minute); !errors.Is(err, context.Canceled) || inner.reads != 0 {
		t.Fatal("cancelled read claimed work")
	}
	if _, err := NewMediaAdmissionGatedBackend(nil, func(context.Context) error { return nil }); err == nil {
		t.Fatal("nil backend accepted")
	}
	if _, err := NewMediaAdmissionGatedBackend(inner, nil); err == nil {
		t.Fatal("nil readiness accepted")
	}
}
