# Staff-curated catalog operator

This client admits one selected, licensed item to the existing media and review
pipeline under [ADR 0023](../adr/0023-staff-curated-licensed-catalog.md). It never
approves, publishes, runs SQL, assigns roles, accepts public Creator Terms, or
manages MFA. The [API contract](../api/curated-catalog-v1.md) defines the separate
administrator AAL2 endpoint and its database gates.

## Required inputs

Use the actual uploading administrator's current production AAL2 session. Pass
its access token through an already-open private pipe or socket descriptor, or
standard input connected to that pipe. The client rejects terminal and regular
file token inputs. Tokens must not appear in command arguments, environment
variables, files, shell history, clipboard logs, or receipts. The protected
session handoff opens the descriptor; this client does not extract a session or
create an authenticator factor.

Every online invocation calls production `/auth/v1/user` with that same token
before trusting subject, issuer, audience, role, expiry or AAL2 claims. Edge
independently authenticates again, and the database checks the current active
administrator. A management/service credential or decoded token alone cannot
substitute for that user authority. HTTP redirects and environment proxy
discovery are disabled. Requests are confined to the pinned production origin.

The public publishable key comes from `Config/Marketplace.production.json`, or
an explicit `--config` file with the same exact project and origin. Service-role
keys are rejected as the public configuration key. Every invocation requires
`--project-ref afgxvhhubqzgpijcstsv`; another project is refused.

Keep the reviewed batch manifest and prepared video-only copies outside Git.
Supply an absolute `--media-root` and a dedicated absolute `--receipt-dir` per
operator. Media must lie inside that root; source and ancestor symlinks are
refused. The receipt directory must be private (0700); new receipts and lock
files use 0600. The client creates only the final receipt directory when its
parent already exists. It never edits, moves or deletes source media.

## Batch manifest

The exact JSON envelope is:

```json
{
  "schema": "wali.curated_catalog.batch.v1",
  "project_ref": "afgxvhhubqzgpijcstsv",
  "items": []
}
```

Supply 1–24 items, each with exactly these fields:

| Field | Meaning |
| --- | --- |
| `item_id` | Stable lowercase UUID for this media/target identity. |
| `file_path` | Absolute regular-file path beneath the supplied media root. |
| `sha256` | Reviewed prepared-file SHA256, 64 lowercase hexadecimal characters. |
| `byte_count` | Exact prepared-file size, 1 through 1,073,741,824. |
| `container_hint` | `video/mp4` or `video/quicktime`. |
| `original_filename` | One filename without path separators, at most 255 UTF-16 units. |
| `target` | `{"kind":"new"}` or `{"kind":"wallpaper_update","wallpaper_id":"UUID","expected_revision":1}`. |
| `draft` | Exact licensed draft described below. |

The draft has exactly `title`, `description`, `primary_category_id`,
`suggested_tag_ids`, `content_warning`, `rights_basis`, `rights_holder`,
`license_id`, `source_url`, `attribution_text`, `proof_object_ids`,
`attests_rights`, and `attestation_version`. Use real taxonomy/license UUIDs,
truthful nonblank rights-holder and source information, a nonnull HTTPS source
URL, and required credit of 1–500 UTF-16 units. Title/description limits are 120
and 2000 units; the rights holder limit is 160. Text must be NFC and contain no
control characters. Up to 20 distinct suggested tag UUIDs are allowed.
`content_warning` is null or bounded plain text.

This path accepts only `rights_basis:"licensed"`, `proof_object_ids:[]`,
`attests_rights:true`, and `attestation_version:"2026-09-12"`. The license must
be the accurate negotiated license record. These fields do not establish
permission to relabel the content as a Creative Commons work, invent an artist,
or omit required publisher credit. Keep agreement references and private
permission evidence out of public fields.

## Offline validation

`validate` never initializes an HTTP client, requests authentication, reads a
token, or writes a receipt. It validates the entire manifest's shape and the
selected source's actual size/SHA256. Repeat for each selected item before use:

```bash
python3 scripts/curated-catalog.py validate \
  --project-ref afgxvhhubqzgpijcstsv \
  --manifest /absolute/private/catalog/batch.json \
  --media-root /absolute/private/catalog/prepared-video-only \
  --item ITEM_UUID
```

The online `upload` action repeats source validation. An open file descriptor,
metadata checks and per-chunk hashes bind transmitted bytes to the reviewed file.
Changes during upload stop completion. Canonical conversion and observed-media
validation still belong to the existing worker.

## Online commands

The examples assume the approved session handoff has already attached the
current token pipe at descriptor 3. They contain no bearer value. Replace the
paths and item UUID with the reviewed private batch inputs.

Read the immutable Catalog License Attestation, then invoke `accept` only when
the factual declaration is accurate:

> I attest that I am authorized under the recorded agreement to process, host, distribute, and display each selected work for WALI. I will stay within the recorded license scope, preserve original authorship and all required source, artist, and publisher credits, and retain the agreement reference. This declaration records my publishing authority; it does not grant new rights or accept public Creator Terms.

```bash
python3 scripts/curated-catalog.py accept \
  --project-ref afgxvhhubqzgpijcstsv \
  --receipt-dir /absolute/private/catalog/operator-receipts \
  --token-fd 3
```

For one item, use the same manifest, media root and receipts for every action:

```bash
python3 scripts/curated-catalog.py upload \
  --project-ref afgxvhhubqzgpijcstsv \
  --manifest /absolute/private/catalog/batch.json \
  --media-root /absolute/private/catalog/prepared-video-only \
  --receipt-dir /absolute/private/catalog/operator-receipts \
  --item ITEM_UUID --token-fd 3
```

Replace `upload` with `status`, `save-draft`, `submit`, or `withdraw` as needed.
`upload` reserves, resumes through TUS HEAD/PATCH, and completes into processing.
It never automatically submits. `status` reads current server state. `submit`
requires the item to be ready and sends its current expected revision/generation.
A different real authorized reviewer must perform review using existing tools.
The server's two-active-submission backpressure and 24-new-session rolling-day
quota remain authoritative; the client does not fan out a batch or consume a
second retry quota.

## Interruption and corrections

Each request identity derives from production project, actual subject, stable
item/media identity, action and exact payload. An intent is durably written
before sending. Receipt locking prevents two local processes from operating the
same item simultaneously. Reusing a directory for another subject or changing
immutable media/target fields is refused.

Each PATCH records its intended range and digest before sending. On restart,
HEAD must confirm the exact total length, TUS version, and an offset explainable
by the previous confirmed offset and pending PATCH. Regressed, unexplained,
negative or out-of-range offsets stop the client. Redirects, cross-project URLs,
non-TUS paths, credentials in URLs and query/fragment URLs are refused. Expired
sessions are not sent new chunks. An ambiguous PATCH is never blindly resent.

A lost completion response replays the exact old request ID, idempotency key,
expected session revision and draft. It does not obtain a new reservation or
substitute the session's later revision. After known completion, rerunning
`upload` reads status instead of allocating or uploading again. Preserve receipts
when transport fails; do not delete them to work around a conflict.

Draft fields are excluded from the immutable media fingerprint. For a credit or
metadata correction, update only the item's reviewed `draft`, then explicitly run
`save-draft`. It reads current status and sends the exact expected revision. A
pending save must first replay its original draft/revision, even if the local
draft was edited again; after that result is reconciled, invoke `save-draft`
again to apply the later edit. Likewise, an already-issued completion retains its
original draft; a later correction uses `save-draft`. Rights/metadata changes
continue to invalidate prior review through the existing database rules.

Receipts contain operation IDs, payloads, hashes and bounded result fields, but
never bearer tokens or service credentials. A validated TUS endpoint may be
retained in the private receipt: it has no query/token and still requires user
authorization. Keep receipts private and available for reconciliation. Console
output contains only bounded status/IDs and the receipt path; server diagnostics
are not echoed.

## Verification boundary

Run the deterministic offline tests with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts -p test_curated_catalog.py -v
make edge-test
```

Fixtures exercise real boundary behavior with synthetic HTTP responses. They do
not prove a live authenticated session, Storage acceptance, worker completion,
independent review, signed publication, native consumption, or release readiness.
Deployment, activation, actual session setup and publication remain separate
explicitly authorized operations.
