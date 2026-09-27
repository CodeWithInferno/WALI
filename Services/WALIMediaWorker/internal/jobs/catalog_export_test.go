package jobs_test

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/storage"
	"os"
	"strings"
	"testing"
)

func TestExportProcessorAcceptsPublicationEvidenceWithoutPrivateFields(t *testing.T) {
	job := jobs.ExportJob{SchemaVersion: 1, ExportID: "11111111-1111-4111-8111-111111111111", UserID: "22222222-2222-4222-8222-222222222222"}
	path := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	legacy := `{"schema_version":1,"export_id":"` + job.ExportID + `","user_id":"` + job.UserID + `","exported_at":"2030-01-01T00:00:00Z","account_identity":{"email":null,"providers":[],"created_at":null,"last_sign_in_at":null},"profile":{},"creator_profile":null,"preferences":{"category_ids":[]},"terms_acceptances":[],"favorites":[],"saved_wallpapers":[],"creator_follows":[],"install_receipts":[],"engagement_events":[],"upload_sessions":[],"submissions":[],"rights_declarations":[],"reports":[]}`
	cases := []struct {
		name, extra string
		valid       bool
	}{
		{"legacy", "", true},
		{"safe publication evidence", `{"automatic_publication_decisions":[{"policy_version":"automatic-publication-2026-09-12","rights_snapshot":{"rights_holder":"Artist"}}],"automatic_publication_jobs":[{"status":"completed","attempts":1}]}`, true},
		{"only one nested array", `{"automatic_publication_jobs":[]}`, true},
		{"private token", `{"automatic_publication_jobs":[{"lease_token":"private-fixture"}]}`, false},
		{"private proof path", `{"automatic_publication_decisions":[{"rights_snapshot":{"proof_storage_path":"private-fixture"}}]}`, false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			payload := strings.Replace(legacy, `"submissions":[]`, `"submissions":[`+test.extra+`]`, 1)
			store := &fakeExportStore{begin: jobs.ExportBegin{Disposition: "started", Path: path}, payload: json.RawMessage(payload)}
			blobs := &fakeBlobs{}
			processor, err := jobs.NewExportProcessor(store, blobs, t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			result := processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-fixture"})
			if test.valid {
				if result.Action != jobs.ActionAck || !store.completed || len(blobs.published) != 1 {
					t.Fatalf("safe export rejected: %v", store.failed)
				}
			} else if store.failed != "export_projection_invalid" || len(blobs.published) != 0 {
				t.Fatal("unsafe export was not rejected before publication")
			}
		})
	}
}

func TestExportProcessorHandlesCreatorBlocks(t *testing.T) {
	job := jobs.ExportJob{SchemaVersion: 1, ExportID: "11111111-1111-4111-8111-111111111111", UserID: "22222222-2222-4222-8222-222222222222"}
	path := "exports/" + job.UserID + "/" + job.ExportID + "/account.json"
	legacy := `{"schema_version":1,"export_id":"` + job.ExportID + `","user_id":"` + job.UserID + `","exported_at":"2030-01-01T00:00:00Z","account_identity":{"email":null,"providers":[],"created_at":null,"last_sign_in_at":null},"profile":{},"creator_profile":null,"preferences":{"category_ids":[]},"terms_acceptances":[],"favorites":[],"saved_wallpapers":[],"creator_follows":[],"install_receipts":[],"engagement_events":[],"upload_sessions":[],"submissions":[],"rights_declarations":[],"reports":[]}`
	active := `{"creator_id":"33333333-3333-4333-8333-333333333333","active":true,"revision":1,"created_at":"2029-01-01T00:00:00Z","updated_at":"2029-01-01T00:00:00Z"}`
	inactive := `{"creator_id":"44444444-4444-4444-8444-444444444444","active":false,"revision":2,"created_at":"2029-01-01T00:00:00Z","updated_at":"2029-01-02T00:00:00Z"}`
	withExtra := func(extra string) string { return strings.TrimSuffix(legacy, "}") + extra + "}" }
	cases := []struct {
		name, payload string
		valid         bool
		blockCount    int
	}{
		{"legacy without blocks", legacy, true, -1},
		{"empty blocks", withExtra(`,"creator_blocks":[]`), true, 0},
		{"active and inactive blocks", withExtra(`,"creator_blocks":[` + active + `,` + inactive + `]`), true, 2},
		{"reordered blocks", withExtra(`,"creator_blocks":[` + inactive + `,` + active + `]`), true, 2},
		{"null blocks", withExtra(`,"creator_blocks":null`), false, 0},
		{"object blocks", withExtra(`,"creator_blocks":{}`), false, 0},
		{"unexpected root beside blocks", withExtra(`,"creator_blocks":[],"incoming_creator_blocks":[]`), false, 0},
		{"missing required root", strings.Replace(withExtra(`,"creator_blocks":[]`), `,"reports":[]`, "", 1), false, 0},
		{"private data inside blocks", withExtra(`,"creator_blocks":[{"access_token":"redacted-fixture"}]`), false, 0},
	}
	var firstCanonical []byte
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			store := &fakeExportStore{begin: jobs.ExportBegin{Disposition: "started", Path: path}, payload: json.RawMessage(test.payload)}
			blobs := &capturingExportBlobs{}
			processor, err := jobs.NewExportProcessor(store, blobs, t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			result := processor.Process(context.Background(), job, jobs.Lease{Owner: "worker-fixture"})
			if !test.valid {
				if result.Action != jobs.ActionAck || store.failed != "export_projection_invalid" || store.completed || len(blobs.published) != 0 {
					t.Fatal("invalid root or private field was not rejected before publication")
				}
				return
			}
			if result.Action != jobs.ActionAck || !store.completed || store.failed != "" || len(blobs.published) != 1 {
				t.Fatalf("approved export projection rejected: code=%s", store.failed)
			}
			var published map[string]json.RawMessage
			if err := json.Unmarshal(blobs.payload, &published); err != nil {
				t.Fatal(err)
			}
			blocks, hasBlocks := published["creator_blocks"]
			if test.blockCount < 0 {
				if hasBlocks {
					t.Fatal("legacy export unexpectedly changed shape")
				}
				return
			}
			var rows []json.RawMessage
			if !hasBlocks || json.Unmarshal(blocks, &rows) != nil || len(rows) != test.blockCount {
				t.Fatal("owner block relationships were not preserved")
			}
			if test.blockCount > 0 {
				if firstCanonical == nil {
					firstCanonical = append([]byte(nil), blobs.payload...)
				} else if !bytes.Equal(firstCanonical, blobs.payload) {
					t.Fatal("block ordering changed canonical export bytes")
				}
			}
		})
	}
}

type capturingExportBlobs struct {
	fakeBlobs
	payload []byte
}

func (blobs *capturingExportBlobs) Publish(ctx context.Context, request storage.PublishRequest) error {
	payload, err := os.ReadFile(request.LocalPath)
	if err != nil {
		return err
	}
	blobs.payload = payload
	return blobs.fakeBlobs.Publish(ctx, request)
}
