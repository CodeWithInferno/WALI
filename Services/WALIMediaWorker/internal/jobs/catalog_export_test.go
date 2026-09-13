package jobs_test

import (
	"context"
	"encoding/json"
	"github.com/TryCleanMcp/WALI/Services/WALIMediaWorker/internal/jobs"
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
