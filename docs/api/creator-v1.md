# Creator API v1

Status: accepted contract under ADRs 0011, 0014, and 0015. Common envelopes,
IDs, text normalization, request bounds, idempotency, revision handling, and
stable errors are defined by `catalog-v1.md`.

Implementation status: server upload, submission, processing, and moderation
primitives are implemented and tested locally, but no production creator
gateway is composed into the app and public creator uploads remain disabled.
Only `original` and `public_domain` rights bases without proof objects are
accepted. The proof workflow below is reserved and unavailable.

## Authorization and state

Every operation requires an authenticated active account, a current unrevoked
`creator` role grant, accepted current Creator Terms, and server-side quota
authorization. An Apple/JWT claim may affect UI presentation but cannot replace
the database checks.

### Accepting Creator Terms

`creator-command` accepts the current Creator Terms only through this exact
request shape:

```json
{"api_version":"creator.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","action":"accept_terms","payload":{"expected_subject_id":"uuid","creator_terms_version":"2026-09-01"}}
```

`expected_subject_id` is mandatory and is the canonical UUID of the account
that initiated the review-and-consent flow. It is a binding assertion, not an
authority claim: the Edge Function independently authenticates the request and
rejects it unless the authenticated actor is exactly the expected subject. The
service-only database command repeats the same comparison before recording an
acceptance or granting creator access. The terms version must exactly match the
server-advertised current version, and the client unlocks Creator Studio only
after the server confirms that same subject and version.

Accepting terms never overrides a creator-role revocation. When the latest
creator grant is revoked, self-enrollment fails closed without recording terms
or creating a replacement grant. Restoring access requires a separate,
explicit administrator role-grant action with AAL2 authorization.

This is an intentionally incompatible tightening of the earlier acceptance
payload. The database migration, Edge Function, and native app require a
coordinated rollout. Keep creator enrollment and production uploads disabled
during rollout; apply the database migration, deploy and verify the Edge
Function, then distribute the matching app before enabling the feature.

Submission transitions are:

```text
draft -> uploading -> uploaded -> processing -> ready_for_submission
                                     |                  |
                                     v                  v
                              processing_failed      submitted -> under_review
                                                            |       |       |
                                                            v       v       v
                                             changes_requested approved rejected
                                                                  |
                                                                  v
                                                               published
```

`draft` and `changes_requested` may be withdrawn. A creator edit after submit
creates a new revision and cannot mutate the moderator's reviewed snapshot.
Replacing media increments `generation`; stale processing completions and stale
moderation decisions cannot advance the submission.

## Creator-provided fields

| Field | Requirement |
| --- | --- |
| media file | required; private raw MOV/MP4 under the media policy |
| `title` | NFC plain text, 1...120 characters |
| `description` | NFC plain text, 1...2,000 characters |
| `primary_category_id` | one active controlled category UUID |
| `suggested_tag_ids` | 0...20 unique active controlled tag UUIDs |
| `content_warning` | optional NFC plain text, at most 500 characters |
| `rights_basis` | `original` or `public_domain`; `licensed` and `other` fail closed until proof-object scanning is enabled |
| `rights_holder` | NFC plain text, 1...160 characters |
| `license_id` | one active license UUID consistent with the rights basis |
| `source_url` | conditional HTTPS URL, at most 2,048 characters |
| `attribution_text` | conditional NFC plain text, at most 1,000 characters |
| rights proof | reserved; rejected until the proof workflow is enabled |

The client never provides a public slug, artifact URL/path/digest, detected
codec, dimensions, duration, processing status, model output, moderator state,
publication time, signature, aggregate count, or ranking eligibility.

## Creator views

`public.my_creator_submissions_v1` returns only the authenticated creator's
records. Each item contains submission ID, optional logical wallpaper ID,
revision, generation, state, proposed public metadata, upload status without a
raw object path, safe processing findings, creator-facing moderation decision,
and timestamps. It never contains lease owners, private moderator notes,
rights-proof path, worker credentials, model raw JSON, another creator, or
internal exception text.

Page limits and cursor behavior follow `catalog-v1.md`. A missing creator grant
returns `creator_role_required`; it is not represented as an empty list.

## `create-upload`

Request body, at most 16,384 bytes:

```json
{"api_version":"creator.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","declared_byte_count":1048576,"container_hint":"video/mp4","original_filename":"private-name.mp4","target":{"kind":"new"}}
```

`declared_byte_count` is 1...1,073,741,824. `container_hint` is exactly
`video/mp4` or `video/quicktime` and is a hint, never a trust fact.
`original_filename` is private, stripped to a single component, NFC-normalized,
control-free, and capped at 255 characters; it is never reused as an object or
artifact path. Target is either `{"kind":"new"}` or
`{"kind":"wallpaper_update","wallpaper_id":"uuid","expected_revision":n}`
for a creator-owned logical wallpaper.

The function enforces a maximum of two concurrent processing submissions and
the configured daily quota. It creates an opaque upload session/path and
returns session ID, 24-hour expiry, TUS endpoint, required resumable headers,
and a scoped upload token/grant. The path is server generated and not a durable
public identifier. No service key is returned.

Additional errors: `creator_role_required`, `creator_terms_required`,
`upload_quota_exceeded`, `upload_size_exceeded`, and `upload_target_invalid`.

## `complete-upload`

Request body:

```json
{"api_version":"creator.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","upload_session_id":"uuid","expected_session_revision":1}
```

The server checks Storage object ownership, exact path, final size, stable
object state, expiry, and one-time binding. It does not trust client-provided
digests or MIME. A successful transaction marks the session complete, creates
or advances a submission generation, reserves one processing attempt, and
enqueues one queue message. Response includes submission ID, revision,
generation, state `processing`, and safe processing-status URL/data key.

Repeating the same canonical request returns the same generation and attempt;
a changed object, key conflict, already-bound session, or stale revision does
not enqueue again. Additional errors: `upload_incomplete`, `upload_changed`,
`upload_expired`, `upload_already_bound`, and `processing_capacity_unavailable`.

## Draft mutation

`save-submission-draft` is a bounded creator RPC/Edge command accepting
submission ID, expected revision, idempotency key, and only the creator fields
listed above. It is allowed in `draft`, `ready_for_submission`, and
`changes_requested`. Changes after a review snapshot increment revision and
return to `changes_requested` or `draft`; media replacement requires a new
upload session/generation. It never mutates a published release.

Response contains the normalized stored proposal, new revision, generation,
state, and any safe field validation errors. Invalid fields are returned as
stable `{field, code}` pairs; rejected input is not partially saved.

## Processing result

The creator may read only a safe projection for the current generation:

- processing state and safe error code;
- detected container/codec, width, height, frame rate, and duration;
- generated variant roles and dimensions, without private object paths;
- duplicate-content warning without another creator's identity/private record;
- category/tag suggestions with model ID/revision/confidence;
- policy findings that the creator can act on.

The raw upload is never streamed back through WALI for moderation. Worker
lease, image digest internals, sandbox output, raw classifier JSON, antivirus
details, and exploit-sensitive parser output remain private.

## `submit-wallpaper`

Request body:

```json
{"api_version":"creator.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","submission_id":"uuid","expected_revision":4,"expected_generation":2,"creator_terms_version":"2026-09-01"}
```

The current generation must be `ready_for_submission` with complete canonical
artifacts, a valid current rights declaration, accepted terms, normalized
metadata, and no unresolved blocking finding. One transaction freezes the
review snapshot and enters `submitted`; asynchronous queue claiming enters
`under_review`. Repeated identical submission returns the same snapshot.

Additional errors: `submission_not_ready`, `processing_generation_stale`,
`rights_incomplete`, `rights_terms_stale`, `metadata_incomplete`,
`blocking_finding`, and `submission_state_conflict`.

## Rights proof upload (deferred)

No proof grant, scanner, reviewer fetch, or product UI is enabled in the current
implementation. Creator commands reject `licensed`, `other`, and every nonempty
proof-object list with `rights_workflow_unavailable`; clients must not attempt a
direct `moderation-private` upload.

The reserved contract permits only one-purpose grants for raster PNG/JPEG or
PDF proof objects, at most 20 MiB each and five objects per declaration. Before
that contract can be enabled, proof bytes must be scanned without execution,
kept outside the catalog, exposed only to the owner for status and authorized
reviewers, and covered by the retention/deletion controls in
`docs/security/data-inventory.yml`. A URL alone is never fetched automatically.

## Withdrawal and changes

`withdraw-submission` accepts submission ID, expected revision, and idempotency
key. It is valid before publication and preserves audit/rights records while
ending processing/review work. A published logical wallpaper uses a separate
delist request; creators cannot delete immutable releases or moderation history.

When moderation returns `changes_requested`, the public note contains bounded
reason codes and creator-facing text. The creator may revise metadata or upload
a new generation, then resubmit with a new expected revision. Rejection is
terminal for that review snapshot; a new submission is required unless a
moderator explicitly reopens it.

## Storage and privacy

Raw upload paths are `uploads-private/<creator-uuid>/<session-uuid>/source` and
are opaque outside server policy. A future rights-proof workflow must use
independently generated paths. Neither raw paths nor future proof paths may
appear in public API, logs, manifests, download metadata, or titles. Raw media
is deleted 30 days after a terminal decision; abandoned sessions expire
earlier. Active legal holds override ordinary deletion and are audited.
