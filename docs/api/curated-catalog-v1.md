# Staff-curated catalog API v1

Accepted under [ADR 0023](../adr/0023-staff-curated-licensed-catalog.md).
This describes the implemented contract, not its production deployment status.

`POST /functions/v1/curated-catalog-command` uses API version
`curated_catalog.v1`. Every action authenticates the current Supabase user,
requires AAL2, and checks the current active administrator grant in the database.
The user remains the upload owner. No creator grant is conferred. Public Creator
Terms may remain null while catalog reads and this separate admission operate.

Requests contain exactly `api_version`, `request_id`, `idempotency_key`, `action`,
and `payload`. Common UUID, idempotency, text, revision, and safe envelope rules
are in [Catalog API v1](catalog-v1.md). The request limit is 32,768 bytes. The
client cannot supply actor identity, assurance, storage paths, processing
success, review, or publication claims. `bind_upload` is server-only and is not
an accepted HTTP action.

| Action | Payload |
| --- | --- |
| `accept_attestation` | `expected_subject_id`, `attestation_version` |
| `create_upload` | `declared_byte_count`, `container_hint`, `original_filename`, `target` |
| `complete_upload` | `upload_session_id`, `expected_session_revision`, `draft` |
| `save_draft` | `submission_id`, `expected_revision`, `draft` |
| `submit` | `submission_id`, `expected_revision`, `expected_generation`, `attestation_version` |
| `status` | `upload_session_id` |
| `withdraw` | `submission_id`, `expected_revision` |

`target` is `{kind:"new"}` or the existing wallpaper-update target containing
`kind`, `wallpaper_id`, and `expected_revision`. Upload sizes and media types
retain the existing intake policy. Filenames are bounded basenames, not paths.

The exact draft keys are `title`, `description`, `primary_category_id`,
`suggested_tag_ids`, `content_warning`, `rights_basis`, `rights_holder`,
`license_id`, `source_url`, `attribution_text`, `proof_object_ids`,
`attests_rights`, and `attestation_version`. Rights basis must be `licensed`,
proof objects must be empty, attestation must be true, and source must be HTTPS.
An active negotiated license permitting WALI distribution is required. Required
credit is 1–500 plain-text characters; the rights holder is 1–160. Title,
description, tags, and warning retain the existing Creator bounds. The supported
Catalog License Attestation version is `2026-09-12`; its immutable text lives in
`supabase/functions/_shared/curated-license-attestation.ts`.

Acceptance stores document kind `catalog_license_attestation`, independently of
Creator Terms. Its response contains `document_kind`,
`accepted_attestation_version`, and `current_attestation_version`.

Create returns `upload_session_id`, `revision`, `expires_at`, `upload_endpoint`,
`required_headers:{"Tus-Resumable":"1.0.0"}`, and `scoped_upload_token`. The token
is the authenticated user's bearer, never an admin service token. Keep the bearer out of logs and receipts. A validated resumable endpoint may be
retained in the private operator receipt for recovery. The endpoint must
remain on this exact Supabase origin under `/storage/v1/upload/resumable/`, with
no query, fragment, user information, or redirect. HEAD/PATCH retain the normal
TUS offset rules. Every raw upload write rechecks owner, admission, active admin,
and AAL2; ordinary Creator paths cannot access curated work.

Completion returns the existing processing mutation shape: `submission_id`,
`state`, `revision`, `generation`, and `processing_status_key`. Save, submit, and
withdraw retain the existing submission mutation shape. A replay can add
`replayed:true`. Acceptance and create return HTTP201; other actions return200.

Status returns `upload_session_id`, upload `revision`, `upload_state`,
`expires_at`, and nullable `submission`. A submission contains its
`submission_id`, `revision`, `generation`, `state`, and existing bounded
`processing` projection. It contains no raw paths, tokens, or proof documents.

The database limits new reservations to24 per administrator per rolling day;
idempotent replays consume no new quota. Existing two-active-submission
backpressure remains. Processing must finish before submission for review. A
real different authorized administrator/moderator must perform the existing
review. Publication still requires all four verified artifacts, immutable
promotion, canonical manifest signing, and final transaction checks.

Clearing the configured catalog attestation disables acceptance and new upload,
completion, draft-save, and submit mutations. Authorized status and withdrawal
remain available for recovery. Disabling admission neither publishes queued
work nor removes existing published catalog records.

The operator workflow is documented in
[Staff-curated catalog runbook](../runbooks/staff-curated-catalog.md).
