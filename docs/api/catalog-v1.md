# Catalog API v1

Status: accepted contract under ADRs 0011, 0012, 0014, 0016, and 0017. The transport
adapter may use Supabase PostgREST and Edge Functions, but this document—not a
generated Supabase type—is the client compatibility boundary.

## Common wire rules

- HTTPS only. Catalog artifact URLs use an environment-injected exact-host
  allowlist and never follow a cross-host redirect.
- JSON is UTF-8. Requests and responses reject duplicate keys. User-visible
  text is NFC-normalized plain text with C0/C1 controls removed.
- IDs are lowercase canonical UUID strings. Digests are 64 lowercase hex
  characters. Times are UTC RFC 3339 with second precision.
- A request body is at most 65,536 bytes. A catalog response is at most
  1,048,576 bytes. Nesting is at most 8 outside signed catalog bodies.
- Page `limit` defaults to 24 and is clamped to 1...50. Arrays returned by one
  catalog page contain at most 50 items unless a smaller type-specific bound is
  stated.
- Cursors are opaque, unpadded base64url strings of at most 1,024 characters.
  The decoded body is at most 768 bytes and contains a version plus the complete
  stable sort tuple. Unknown versions, missing tuple values, and trailing bytes
  produce `invalid_cursor`; cursors grant no authorization.
- `request_id` is a caller-generated UUID. Mutation `idempotency_key` is 16...64
  ASCII characters matching `[A-Za-z0-9_-]+`. Reuse with different canonical
  input produces `idempotency_conflict`.
- `expected_revision` is an integer in 0...9,007,199,254,740,991. A mismatch
  produces `stale_revision` without mutation.
- Unknown additive enum values decode to a non-actionable `unknown` client
  presentation. Unknown values never grant a role, state transition, content
  rating exception, or install permission.

Edge Function success envelope:

```json
{"api_version":"catalog.v1","request_id":"00000000-0000-4000-8000-000000000001","data":{}}
```

Error envelope:

```json
{"api_version":"catalog.v1","request_id":"00000000-0000-4000-8000-000000000001","error":{"code":"invalid_request","message":"The request could not be completed.","retryable":false}}
```

Exactly one of `data` or `error` exists. Error messages are optional safe
presentation text; internal exceptions, SQL, paths, tokens, object names, and
rights evidence never cross the boundary. Stable common codes are:

| Code | HTTP | Retryable |
| --- | ---: | --- |
| `invalid_request` | 400 | no |
| `invalid_cursor` | 400 | no |
| `unsupported_api_version` | 400 | no |
| `authentication_required` | 401 | no |
| `forbidden` | 403 | no |
| `not_found` | 404 | no |
| `stale_revision` | 409 | no |
| `idempotency_conflict` | 409 | no |
| `rate_limited` | 429 | yes, after `Retry-After` |
| `temporarily_unavailable` | 503 | yes |

## Public catalog projection

The Data API exposes only these versioned views. Views are read-only and grant
no direct access to their source tables:

- `public.catalog_home_v1`
- `public.catalog_wallpapers_v1`
- `public.catalog_wallpaper_details_v1`
- `public.catalog_creators_v1`
- `public.catalog_categories_v1`
- `public.catalog_tags_v1`
- `public.catalog_collections_v1`
- `public.my_profile_v1`
- `public.my_creator_submissions_v1`
- `public.my_favorites_v1`
- `public.my_saved_wallpapers_v1`

Shared `WallpaperSummaryV1` fields:

| Field | Type and bound |
| --- | --- |
| `id` | UUID |
| `slug` | 1...120 lowercase URL-safe characters |
| `title` | NFC plain text, 1...120 characters |
| `creator` | `CreatorSummaryV1` |
| `content_rating` | `everyone`, `teen`, or `mature` |
| `primary_category` | `TaxonomySummaryV1` |
| `approved_tags` | 0...20 `TaxonomySummaryV1` values, sorted by slug |
| `poster` | public `ArtifactSummaryV1` with role `poster` |
| `preview` | public `ArtifactSummaryV1` with role `preview` |
| `current_release_id` | UUID |
| `revision` | integer 0...9,007,199,254,740,991; logical wallpaper revision |
| `published_at` | RFC 3339 UTC seconds |
| `verified_install_count` | nonnegative integer, server aggregate |
| `favorite_count` | nonnegative integer, server aggregate |
| `save_count` | nonnegative integer, server aggregate |

`CreatorSummaryV1` contains `id`, 3...32-character `handle`, 1...80-character
`display_name`, optional approved HTTPS `avatar_url`, and
`verification_status`. `TaxonomySummaryV1` contains UUID `id`, 1...80-character
`name`, and 1...80-character lowercase slug. `ArtifactSummaryV1` contains
`role`, approved HTTPS `url`, lowercase `sha256`, positive `byte_count`, exact
`media_type`, positive `width`/`height`, and positive `duration_ms` for video.

`WallpaperDetailV1` wraps one `WallpaperSummaryV1` as `wallpaper`, then adds
description (1...2,000), edition, rights holder, attribution text/source URL
when required, a license object, duration, dimensions, rational frame rate,
related wallpaper summaries (at most 24), authenticated viewer flags
`is_favorite`/`is_saved` plus `favorite_revision`/`saved_revision`, and
`video_default` as a public `ArtifactSummaryV1` for hero/desktop playback.
Each viewer
revision is an integer in 0...9,007,199,254,740,991 and is `0` when no row
has ever existed. A false tombstone retains its nonzero monotonic revision so
an add/remove/add cycle cannot recreate revision `0`. It contains no raw
filename, private object path,
rights proof, moderator note, model raw output, eligibility flag, or local-use
claim.

The stable JSON field order for `WallpaperSummaryV1` is `id`, `slug`, `title`,
`creator`, `content_rating`, `primary_category`, `approved_tags`, `poster`,
`preview`, `current_release_id`, `revision`, `published_at`,
`verified_install_count`, `favorite_count`, `save_count`. Detail field order is
`wallpaper`, `description`, `edition`, `rights_holder`, `attribution_text`,
`source_url`, `license`, `duration_ms`, `width`, `height`,
`frame_rate_numerator`, `frame_rate_denominator`, `is_favorite`,
`favorite_revision`, `is_saved`, `saved_revision`, `related`, and
`video_default`. Nullable
fields are `attribution_text` and `source_url`; unauthenticated viewer flags are
`false` and viewer revisions are `0`.

`license` is an object with this exact field order and shape:

| Field | Type and bound |
| --- | --- |
| `code` | 1...64 ASCII `[A-Za-z0-9._-]` |
| `name` | NFC plain text, 1...120 characters |
| `terms_url` | HTTPS URL, at most 2,048 characters |
| `attribution_required` | Boolean |
| `commercial_use_allowed` | Boolean |
| `derivatives_allowed` | Boolean |
| `redistribution_allowed` | Boolean; always true for a published release |
| `terms_revision` | integer 1...2,147,483,647 |

`rights_holder` is required NFC plain text of 1...160 characters.
`attribution_text` is nullable NFC plain text of at most 1,000 characters and is
required when the license requires attribution. `source_url` is nullable HTTPS
of at most 2,048 characters and is required when the license/rights declaration
requires a source link. Frame rate is carried only as positive integer numerator
and denominator; a floating-point `frames_per_second` field is not part of v1.

## Read RPCs

### `catalog_home_v1(locale, rating_ceiling)`

Visitor-readable. `locale` is a normalized BCP-47 tag of at most 35 characters;
unsupported locales fall back to `en`. `rating_ceiling` is one controlled
rating. Returns at most eight sections, each with stable `id`, title, kind,
cursor, and at most 24 summaries. Section kinds are `editorial`, `trending`,
`new`, `for_you`, and `category`. Personalization opt-out or cold start omits
`for_you` and uses the deterministic editorial/trending/fresh mix.

### `catalog_search_v1(query, filters, cursor, limit)`

Visitor-readable. Query is NFC plain text, 1...200 characters. Filters contain
only `category_slug`, up to 10 tag slugs, `content_rating_ceiling`, and optional
duration bounds inside 1...600,000 ms. Returns summaries, `next_cursor`, and a
versioned `ranking_explanation` containing only formula/model revision IDs—not
private scores or other users' behavior.

### `catalog_browse_v1(category, tags, sort, cursor, limit)`

Visitor-readable. Category is zero or one slug; tags are zero...10 unique slugs.
Sort is exactly `featured`, `trending`, `newest`, or `most_installed`. Returns
summaries and `next_cursor`; arbitrary SQL order expressions are rejected.

### `catalog_wallpaper_detail_v1(wallpaper_id)`

Visitor-readable. Returns one active published detail or `not_found`. Unlisted
items are returned only through their exact ID/slug route and are excluded from
home/search/browse. Hidden, suspended, removed, and unpublished items are not
returned to public callers.

### `catalog_creator_v1(handle, cursor, limit)`

Visitor-readable. Handle is 3...32 normalized characters. Returns the public
creator profile and published summaries. Private account identity, email,
moderation state, uploads, rights evidence, and follower identities are absent.

### Account-scoped reads

`my_favorites_v1(cursor, limit)` and `my_saved_wallpapers_v1(cursor, limit)`
require a user session and return only the caller's summaries. `my_profile_v1`
returns the caller's safe profile/preferences. An unauthenticated response is
`authentication_required`, never an empty list that could conceal auth drift.

## Interaction RPCs

`set_favorite_v1`, `set_saved_v1`, and `set_creator_follow_v1` require a current
user session. Each accepts target UUID, Boolean `desired`, idempotency key, and
expected revision. The response contains `desired`, resulting revision, and
server aggregate count. Setting the current state again is a successful
idempotent no-op. A changed state increments a persisted monotonic revision;
deactivation retains a false tombstone and never resets the revision to zero.
Clients cannot write aggregate or ranking eligibility fields.

## Install functions

### `request-install`

Requires a user session. Request:

```json
{"api_version":"catalog.v1","request_id":"uuid","idempotency_key":"16-to-64-chars","wallpaper_id":"uuid","release_id":"uuid","expected_wallpaper_revision":1}
```

The requested release must still be the current published, unrevoked edition.
The response contains exact canonical `manifest_body` and `metadata_body` bytes
encoded separately as unpadded base64url, detached `signature` as unpadded
base64url, `key_id`, and a one-use
opaque `install_receipt` of at most 512 characters expiring within 30 minutes.
The body is at most 65,536 decoded bytes and is verified before any artifact is
downloaded. `metadata_body` is at most 16,384 decoded bytes and its exact
SHA-256 must equal the signed manifest `metadata_digest`. Both the foreground
app and agent independently verify it; only these bytes may supply the locally
persisted title, creator, attribution, and rights-holder provenance. Receipt
issuance records `install_requested`; it does not count as an install.

Additional codes: `release_not_current`, `release_revoked`,
`manifest_unavailable`, and `account_suspended`.

### `record-install`

Requires the same user. Request contains API/request/idempotency values,
`install_receipt`, manifest digest, release ID, and local result exactly
`verified_installed`. It contains no local path, filename, display, assignment,
playback, or device inventory. A valid receipt is consumed once and records one
eligible `install_succeeded`; replay returns the original result without a new
ranking contribution.

### `catalog-security-state`

This public bounded function returns `catalog.v1` data with optional
`trust_transition` and required `revocations`. Each signed document contains
`revision`, unpadded-base64url canonical `body`, detached unpadded-base64url
`signature`, and `key_id`. Trust-transition bodies are at most 32,768 decoded
bytes and revocations at most 1,048,576. Clients verify, persist, and forward
last-known-good state to the agent before an install. Network failure may use
an already verified cache; corrupt cache, rollback, or same-revision
equivocation fails closed.

## Report function

`report-wallpaper` requires a user session. It accepts request/idempotency
values, wallpaper ID, optional release ID, controlled `kind`, and NFC plain-text
detail of 1...2,000 characters. The response contains report ID, `open` status,
and creation time. It never returns assignment, moderator identity, private
notes, or other reports. Duplicate/rate-limited reports return a stable prior
result or `rate_limited`.

## Canonical manifest v1

The signature covers the exact bytes of `Fixtures/Catalog/manifest-v1.json`.
Canonical bytes are UTF-8 without BOM, compact single-line JSON, insignificant
whitespace, or a trailing newline. JSON strings use shortest valid escapes;
solidus and printable ASCII are not escaped. All strings are NFC. Duplicate or
unknown keys, floats, exponents, negative values, `null`, and unknown epochs are
rejected before signature trust.

Root key order is:

1. `schema`
2. `key_id`
3. `wallpaper_id`
4. `release_id`
5. `edition`
6. `issued_at`
7. `artifacts`
8. `metadata_digest`

`schema` key order is `epoch`, `revision`; V1 is exactly epoch 1 revision 0.
Artifact key order is `role`, `url`, `sha256`, `byte_count`, `media_type`,
`width`, `height`, `duration_ms`. Artifacts use this canonical role order:
`thumbnail`, `poster`, `preview`, `video_default`, `video_1080p`,
`video_1440p`, `video_2160p`.

Manifest bounds:

| Value | Bound |
| --- | --- |
| body | at most 65,536 bytes |
| nesting | at most 4 |
| artifacts | 4...7, unique roles; thumbnail/poster/preview/video_default required |
| `key_id` | 1...64 ASCII `[a-z0-9._-]` |
| UUIDs | lowercase canonical 36 characters |
| `edition` | 1...2,147,483,647 |
| `issued_at` | exact `YYYY-MM-DDTHH:MM:SSZ` |
| URL | at most 2,048 characters; HTTPS; exact allowed host; no userinfo/query/fragment/redirect |
| digests | 64 lowercase hex |
| `byte_count` | 1...2,147,483,648 |
| `width` | 1...7,680 |
| `height` | 1...4,320 |
| `duration_ms` | 1...600,000 for video; `0` for raster image roles |
| media types | exactly `image/jpeg`, `image/png`, or `video/mp4`, consistent with role |

Detached signatures are raw 64-byte Ed25519 signatures encoded as 86-character
unpadded base64url. The golden fixture uses test-only key ID
`catalog-test-2026-01`, RFC 8032 test seed
`9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60`, and
public key `d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a`.
The seed documents reproducibility of public test data and is forbidden from
every deployed key registry.

## Canonical install metadata v1

Root key order is `schema`, `wallpaper_id`, `release_id`, `edition`, `title`,
`creator_name`, `creator_handle`, `attribution_text`, `rights_holder`.
`schema` is exactly `wali.catalog.install-metadata.v1`. UUID and edition values
must equal the signed manifest. `creator_handle` and `attribution_text` remain
present strings and may be empty; required provenance strings are non-empty.
The document is compact NFC UTF-8 with the same duplicate/unknown-key and
integer rules as the manifest and is capped at 16,384 bytes.

## Canonical trust transition v1

The cumulative key-state root order is `schema`, `revision`, `issued_at`,
`keys`; `schema` is exactly `wali.catalog.trust-transition.v1`. Key entries are
sorted by `key_id`, unique, capped at 32, and ordered `key_id`, `public_key`,
`valid_from`, `valid_until`, `status`. Public keys are raw 32-byte Ed25519 keys
encoded as unpadded base64url. Status is `active`, `retired`, or `compromised`.

Every transition is signed directly by an active compiled primary or recovery
anchor so a clean client can verify the latest cumulative document without a
missing transition chain. Compiled key material and validity windows cannot be
replaced. Keys cannot disappear, retired keys cannot reactivate, and
compromised keys remain compromised. Revision and issue time are monotonic;
equal revision is idempotent only for byte-identical canonical content.

## Revocation body v1

Canonical root order is `schema`, `key_id`, `revision`, `issued_at`,
`revocations`. Entry order is `release_id`, `artifact_sha256`, `reason`,
`issued_at`; entries sort by release ID then artifact digest and are unique.
The body is at most 1,048,576 bytes, contains at most 4,096 entries, and uses
the same canonical string/integer/time/key rules. `revision` is
1...2,147,483,647. Reasons are exactly `critical_security`, `corrupt_artifact`,
or `signing_compromise`. A revocation body is accepted only with a detached
signature from an active key in the current compiled-or-transitioned trust set;
retired keys remain valid for historical release manifests but cannot authorize
new security state. The fixture is canonical data, not unsigned authority.

## Cache and compatibility

Public catalog pages may be cached by version, cursor, locale, and rating
ceiling. Account, creator-draft, moderator, upload, receipt, and report responses
are never placed in the public cache. Installed artifacts remain usable offline
after local verification unless an already trusted signed critical revocation
has been received. A network failure never rewrites or deletes local state.

Any incompatible field/ordering/signature change requires a new manifest epoch.
An additive API change uses a new API version or optional field only after all
current clients safely ignore it. V1 fields never silently change meaning.
