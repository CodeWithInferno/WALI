# Moderation API v1

Status: accepted contract under ADRs 0011, 0014, 0015, and 0016. Common JSON,
envelope, ID, revision, idempotency, and safe-error rules are inherited from
`catalog-v1.md`.

Implementation status: bounded moderation/publication/revocation contracts and
native review routes exist. The staging private media projection includes full
video for human review; a poster or 30-second teaser is insufficient. Production
keys, full native moderation lifecycle evidence, and rights-proof review remain
release gates.

## Authorization

Every review operation verifies the Supabase session, active account, current
unrevoked database role grant, and MFA assurance level `aal2`. An AAL1 token,
stale JWT role, revoked grant, suspended account, or creator reviewing their own
submission fails before protected data is returned. Administrator-only
operations perform the same checks for `admin`.

Moderator responses are at most 1,048,576 bytes. Pages default to 24 and cap at
50. The current service accepts no proof objects and exposes no reviewer proof
grant. If that workflow is enabled later, proof must use a short-lived
reviewer-scoped object grant and never a public URL. All accesses and mutations
carry a server request ID and append an audit or moderation-action record.

## Review queue projection

The private moderator RPC `moderation_queue_v1(status, cursor, limit)` returns:

- submission ID, revision, current processing generation, state, and the logical wallpaper ID/revision;
- creator public identity plus conflict-of-interest ID check;
- proposed title, description, category, tags, rating, attribution, and source;
- rights declaration basis/license/attestation and proof status, currently
  limited to no-proof `original` and `public_domain` declarations;
- canonical poster, 30-second preview, and full `video_default`, served from verified output;
- deterministic media facts, duplicate signal, safe scanner/policy findings;
- normalized model suggestions labelled as suggestions;
- prior creator-facing decisions and append-only action summary.

It never returns service keys, queue credentials, worker lease secrets, raw
upload bytes, raw classifier output, another user's unrelated data, claimant
contact outside an assigned case, or arbitrary object paths.

Queue status is `pending`, `under_review`, or `approved`. Approved submissions remain in the private queue until publication, so operators can finish or retry publication after restarting the app. Queue filters are controlled values. Sort is exactly
`oldest_submitted`, `newest_submitted`, or `risk_priority`; arbitrary SQL is
rejected. A queue cursor includes the complete stable timestamp/UUID tuple.

## `moderate-submission`

Request, at most 32,768 bytes:

```json
{"api_version":"moderation.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","submission_id":"uuid","expected_revision":5,"expected_generation":2,"decision":"approved","checklist_revision":1,"reason_codes":[],"creator_note":"Plain text","private_note":"Plain text"}
```

`decision` is `approved`, `changes_requested`, or `rejected`. Reason codes are
0...20 controlled values. Creator note is NFC plain text at most 2,000
characters; private note is at most 4,000 and never enters a creator/catalog
response. The checklist revision must be current. Approval requires the latest
completed processing generation, current verified artifacts, accepted rights,
all blocking checklist items, and a moderator different from the creator.

The transaction appends one immutable review and moderation action, advances
the submission, and increments revision. It never publishes. Identical retry
returns the original result. Additional errors: `mfa_required`,
`moderator_role_required`, `self_review_forbidden`, `review_generation_stale`,
`checklist_stale`, `rights_not_approved`, `canonical_media_unavailable`, and
`review_state_conflict`.

## `publish-release`

Local implementation includes private staging, digest-verified promotion,
canonical signing/finalization, and client verification. This section defines
the accepted contract. The native Ready to Publish queue exposes explicit publication and retries the same idempotent request while verified media promotion completes. Hosted production signing keys, exact-release deployment, and a staging publish/install canary remain release gates.

Requires moderator or admin at AAL2. Request:

```json
{"api_version":"moderation.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","submission_id":"uuid","expected_revision":6,"expected_generation":2,"expected_wallpaper_revision":0,"manifest_schema":{"epoch":1,"revision":0}}
```

Publication is one server transaction plus a signing step with compensating
failure handling. It re-checks the current approval, rights, canonical artifact
set, artifact digests/paths, creator status, taxonomy, rating, license, and
generation. It assigns a positive edition, freezes release/artifact links,
creates exact canonical manifest bytes, signs them with the active valid
Ed25519 key, stores body/signature/digests immutably, advances the logical
wallpaper's current release, and appends audit/action rows.

Response contains wallpaper ID, release ID, edition, manifest digest, key ID,
published time, wallpaper revision, and catalog detail locator. It never returns
the private signing key or internal Storage credentials. Publication cannot
acknowledge success before immutable objects and signed manifest are readable.

Additional errors: `publication_not_approved`, `publication_generation_stale`,
`publication_rights_invalid`, `artifact_set_invalid`, `artifact_not_immutable`,
`signing_key_unavailable`, `manifest_signing_failed`, and
`publication_state_conflict`.

## Report and copyright case operations

`moderation_reports_v1` returns open, triaged, and appealed reports that are
unassigned or assigned to the current reviewer; admins can see other assignments.
Both the reporter and the wallpaper creator are excluded from reviewing their
own case. The response includes the report's real revision, full bounded report
text, wallpaper identity/title/status/revision, reported release/edition, and
verified canonical media claims. The Edge read operation signs five-minute
private artifact grants for that exact reported edition. Staff authorization and
assignment are also enforced by the storage read policy. Native report pages
support bounded pagination and verified full-video playback.

`resolve-report` accepts `report_id`, `expected_revision`,
`expected_wallpaper_revision`, `action`, `reason_code`, and a required private
decision note of 1–2,000 characters, within the `moderation.v1` command envelope.
The server rechecks active staff grants, AAL2, assignment, no-self-review, and
both locked revisions. Identical idempotency keys replay the recorded decision;
changed content under an existing key is rejected. Decisions append moderation
and audit events. The report revision advances through the existing row trigger.

Implemented actions:

- `close_no_action`: requires `no_violation`; closes the report and preserves
  current wallpaper visibility, including any earlier hide.
- `hide_pending_review`: hides a published listing and keeps the assigned report
  triaged. It never restores an already suspended or removed wallpaper.
- `delist`: marks the wallpaper removed and closes the report.

Hide/remove prevent new marketplace install authorizations. Existing library
copies and previously issued public artifact URLs are not erased. Policy reports
never issue a critical technical revocation. Restoration, automatic escalation,
and removal of hosted public artifacts require separate operator workflows;
they are not implemented by this endpoint.

Copyright-case storage exists for claimant/contact and private notice objects.
The complete notice/counter-notice, deadlines, restoration, strikes, and retention
workflow remains a release gate; there is no native case-management flow yet.
Contact fields must remain outside catalog/creator APIs and logs. Legal policy
and human review determine case outcomes.

## Security revocation

The prepare/sign/finalize and client-verification primitives exist locally, but
no production recovery key boundary or operator route is deployed. A signed
revocation must not be treated as an available incident control until key
recovery, retry, staging, and supported-client evidence is recorded.

`issue-catalog-revocation` is admin AAL2 plus security-response authorization.
It accepts a published release, one exact artifact digest, expected keyset/list
revision, idempotency key, and one reason: `critical_security`,
`corrupt_artifact`, or `signing_compromise`. It appends the entry to a canonical
sorted revocation body and signs the batch with an eligible key or offline
surviving trust path.

Copyright, attribution, quality, or ordinary policy disputes cannot use this
operation. They delist instead. A revocation stops new installs/selections of
catalog-origin releases; it does not target local imports or silently erase
files. Additional errors: `revocation_reason_forbidden`, `revocation_stale`,
`revocation_signing_unavailable`, and `release_not_published`.

## `admin-role-grant`

Admin AAL2 only. Request contains target user ID, controlled role, desired
active Boolean, reason code/text, expected role revision, and idempotency values.
The caller cannot remove the last active administrator through this endpoint,
grant a role to a suspended/deleted account, or grant by email/handle ambiguity.
Every grant/revocation appends a security audit row and revokes affected sessions
when policy requires. Response contains only target ID, role, state, revision,
and timestamps.

## Taxonomy, collections, and key transitions

Admin/editorial commands use controlled records and expected revisions. They
never accept arbitrary SQL, model labels, URLs to fetch, or raw HTML. Category
and tag deletion is soft while referenced. Published collection membership is
ordinal and deterministic.

Signing-key transition requires key ID, Ed25519 public key, validity interval,
status, and a transition signature from an already trusted eligible key. Private
key bytes enter only the signing secret store through an operator runbook. A
database row alone cannot expand client trust.

## Audit and safe failure

Moderation reviews, actions, role changes, publication, delisting, key changes,
revocations, rights decisions, account enforcement, exports, and deletions are
append-only. Records contain bounded redacted metadata and request IDs, not
tokens, raw proof, emails, filesystem paths, or SQL exceptions. Update/delete
attempts fail.

If signing, object verification, database authorization, AAL, generation, or
revision cannot be proved, the operation fails closed. A moderator UI may retry
an identical idempotent request; it must never infer success from a timeout.
