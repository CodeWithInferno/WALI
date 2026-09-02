# WALI Marketplace Foundation

- status: accepted
- date: 2026-09-01
- owner: project owner
- implementation gate: accepted by the project owner; ADRs 0011-0016 are accepted
- target release: public beta foundation

## Executive decision

WALI should become an app-only, free wallpaper marketplace without turning into
a distributed-systems project. The production topology is deliberately small:

```text
WALI.app
  |-- public catalog reads, auth, creator and moderator UI
  |-- short-lived upload and install requests
  `-- verified catalog downloads into WALI-owned quarantine
          |
          v
Supabase
  |-- Auth: Sign in with Apple
  |-- Postgres: catalog, rights, moderation, engagement, ranking
  |-- Storage/CDN: private uploads and immutable public releases
  |-- Queues/Cron: processing, aggregation, retention, backup checks
  `-- Edge Functions: short privileged state transitions and manifest signing
          |
          v
one dedicated Linux VM
  |-- small Go control-plane worker
  |-- rootless, networkless media sandbox per attempt
  `-- rootless, networkless classifier sandbox per attempt
```

There is no Kubernetes, Redis, Kafka, Elasticsearch, GCP application stack,
microservice fleet, or customer-facing marketplace website. A small static
legal/support surface is required before public user-generated-content hosting.

The marketplace is not allowed to weaken the local runtime. In particular,
the process that receives Full Disk Access for experimental Lock Screen
continuity must not contain AVFoundation, a network client, a media parser, an
archive parser, WebKit, JavaScriptCore, shell execution, or generic filesystem
commands. That requires a new narrowly scoped Lock Screen helper and removal of
Full Disk Access from `WALIAgent`.

## Product definition

### Users and roles

| Role | Capabilities |
| --- | --- |
| Visitor | Browse, search, inspect creators and licenses, preview published releases |
| User | Visitor capabilities plus install, favorite, save, follow, report, and manage an account |
| Creator | User capabilities plus upload, edit drafts, submit, respond to requested changes, and view submission status |
| Moderator | Review canonical previews and rights declarations; approve, request changes, reject, suspend, and resolve reports |
| Administrator | Manage roles, taxonomy, featured collections, signing-key transitions, and account enforcement |

`user` is implicit for every authenticated account. Elevated roles are explicit,
revocable grants. Moderator and administrator sessions require AAL2 MFA.

### In-app surfaces

1. **Discover** — editorial hero, trending, new, and personalized rows.
2. **Browse** — categories, tags, search, sort, and filters.
3. **Wallpaper detail** — full-bleed video, title, creator, description,
   attribution, license, technical metadata, saves/downloads, related items,
   favorite, install, report, and share-link copy.
4. **Library** — locally installed releases and existing local imports.
5. **Favorites and saved** — account-backed lists.
6. **Creator Studio** — upload, metadata, rights declaration, processing state,
   validation findings, submission, and revision history.
7. **Review Queue** — role-gated moderation surface inside WALI.
8. **Settings/Account** — Apple sign-in, privacy controls, content filtering,
   data export/account deletion request, and existing playback controls.

The current Create page becomes Creator Studio. It is not another local import
page. Local import remains in Library; marketplace upload lives in Creator
Studio.

### V1 scope

- Free downloads only; no prices, checkout, payouts, tips, or tax handling.
- Native Sign in with Apple through Supabase Auth.
- Video wallpapers with generated poster, thumbnail, preview, and canonical
  playback variants.
- Creator profiles, rights declarations, categories, tags, search, editorial
  collections, trending, related, and a conservative personalized feed.
- Human approval before first publication and before every media replacement.
- Reports, copyright/takedown workflow, suspension, release revocation for
  security incidents, and auditable moderator actions.
- Content-addressed, immutable artifacts and signed versioned manifests.
- Offline playback after an installed release has been independently verified.
- Public read-only catalog; authentication is required to install or interact.

### Explicit non-goals

- A general social network, comments, direct messages, public follower counts,
  live presence, or claims about how many people are currently using a wallpaper.
- User-provided HTML, Markdown execution, scripts, shaders, screensavers,
  plugins, archives, playlists, subtitles, fonts, executables, or web content.
- Remote control of display layouts or synchronization of device-local display
  assignments.
- Automated copyright decisions or automatic publication based on a model.
- Deleting a user's already-installed local copy after a normal copyright
  delisting. Only a signed critical-security revocation can make a catalog
  release unselectable.
- FileVault preboot wallpaper support.

## Product rules

1. A wallpaper page is a stable logical record. Media changes create a new
   immutable release edition; they never overwrite a published artifact.
2. The displayed title comes from `title`. The original upload filename is
   private diagnostic data and is never a public name.
3. Creator-provided metadata is a proposal. System inspection and moderator
   decisions remain separate facts.
4. A checksum proves identity, not trust. Trust requires the complete processing,
   verification, moderation, signing, download, and local-install chain.
5. Every public statistic has a precise definition. V1 exposes saves and
   verified installs; it does not expose fake real-time usage.
6. Delisting stops new discovery and downloads but preserves moderation and
   audit history.
7. Publication requires a redistribution license or rights declaration that
   permits WALI to host and users to download the media.
8. No service-role key, signing private key, VM credential, or moderator secret
   ships in the macOS application.

## System topology and ownership

### Supabase control plane

Supabase is the sole internet-facing backend:

- **Auth** issues user sessions and federates native Sign in with Apple.
- **Postgres** owns product truth, state machines, authorization facts, search,
  vector metadata, statistics, and audit records.
- **Storage** receives resumable uploads and serves immutable public releases
  through the CDN.
- **Queues (`pgmq`)** hold media-processing and maintenance jobs.
- **Cron (`pg_cron`)** schedules ranking aggregation, retention, backup checks,
  and stale-job recovery.
- **Edge Functions** execute bounded privileged commands. They do not transcode,
  classify, perform long polling, or run long media jobs.

### VM media plane

The VM is a replaceable worker, not a second product backend. It has no inbound
public port. Outbound access is restricted to Supabase endpoints and the
operating-system/package update sources used during image construction.

The host runs a small Go worker under a dedicated unprivileged user. The worker
leases a queue message, obtains time-limited object access, creates opaque job
directories, and launches rootless Podman containers. The container processing
untrusted bytes never receives Supabase credentials or network access.

```text
Go worker with short-lived storage/queue access
  |
  |-- download opaque input bytes without parsing
  |
  |-- rootless podman run --network=none media-sandbox
  |      read-only input + bounded tmpfs + bounded output
  |
  |-- rootless podman run --network=none verifier-sandbox
  |      independent ffprobe/hash checks
  |
  |-- rootless podman run --network=none classifier-sandbox
  |      pinned model + sampled raster frames only
  |
  `-- upload verified artifacts and bounded JSON claims
```

Every processing attempt receives fresh containers and scratch directories.
Timeout, memory, CPU, process, file-size, and disk quotas are mandatory. The
container root filesystem is read-only; Linux capabilities are dropped;
`no-new-privileges` is set; device access and host mounts are absent. The
worker never exposes the container runtime socket.

### macOS runtime

The target local topology is:

```text
WALI.app
  |-- WALIAppRuntime: catalog/auth/upload/download coordination
  |-- WALIUI: presentation only
  |-- no Full Disk Access
  |
  +-- authenticated/versioned XPC --> WALIAgent.app
  |       |-- sole local Engine, SQLite, install journal, and renderer authority
  |       |-- no Full Disk Access
  |       `-- private WALITranscoder.xpc
  |              sandboxed; no network; parses untrusted local/downloaded media
  |
  `-- authenticated narrow XPC --> WALILockScreenHelper.app
          only binary eligible for Full Disk Access
          no media parsing, playback, network, scripting, or arbitrary paths
```

The helper accepts only `status`, `activateVerifiedRelease`, `deactivate`, and
`restore` operations. An activation identifies an already verified WALI-owned
release by bounded IDs and digest. The helper resolves paths under its own
fixed roots, authenticates the caller's code signature, validates the current
macOS build/store schema/ownership, journals exact preimages, uses atomic
replacement, and fails closed on drift.

The agent should be App Sandbox enabled if the renderer and global wallpaper
window behavior pass a feasibility spike. If that is not possible, it still
must run Hardened Runtime without Full Disk Access; untrusted parsing stays in
the sandboxed transcoder, and the Lock Screen helper remains separate.

## Trust boundaries

| Boundary | Untrusted input | Required decision before trust |
| --- | --- | --- |
| Auth | OAuth result, client token, claimed role | Supabase token validation, issuer/audience/expiry, database role lookup |
| Upload | Filename, MIME header, bytes, creator metadata | Generated path, allowlist, signature inspection, quotas, canonical re-encode |
| Worker claim | ffmpeg output and JSON | Independent verifier sandbox, digest/size/metadata match |
| Classification | Labels and similarity scores | Stored as model suggestions; moderator or policy acceptance only |
| Publication | Database rows and artifact references | Approved state, immutable paths, canonical manifest, signature transaction |
| Catalog client | API JSON, URLs, manifest, CDN bytes | Bounded decoding, host allowlist, Ed25519 signature, length and SHA-256 |
| Local import | User-selected media | Security-scoped access, sandboxed canonicalization, agent-owned install journal |
| App to agent | App command | Named XPC, code-signature peer check, schema bounds, revision/idempotency check |
| Agent to FDA helper | Lock Screen command | Named XPC, code-signature peer check, fixed operation and fixed roots |

## End-to-end workflows

### Account creation

1. WALI starts native Sign in with Apple.
2. Supabase validates the Apple identity and returns a normal user session.
3. A database trigger creates a minimal `profile`; no role is taken from client
   metadata.
4. Tokens are held in Keychain through the catalog runtime, never in shared
   defaults or logs.
5. Creator status is self-enrolled only after the current creator terms are
   accepted. Moderator/admin roles require an audited admin grant and AAL2.

### New upload

1. Creator enters title, description, primary category, optional tags, rights
   holder, rights basis/license, source/credit when applicable, and a content
   warning.
2. `create-upload` validates quotas and returns an opaque upload session plus a
   short-lived resumable Storage URL under the creator's private prefix.
3. WALI uploads directly to private Storage using TUS; the original filename is
   retained only in the private upload row.
4. `complete-upload` verifies server-observed object size and enqueues processing.
5. The VM produces canonical variants, poster, thumbnail, sampled frames,
   technical metadata, and classification suggestions.
6. The creator reviews system findings and submits. Media bytes cannot be
   swapped after this point; a change creates another processing generation.
7. A moderator sees only canonical outputs, rights data, detected metadata,
   duplicate matches, and model suggestions—not the raw upload in the app.
8. Approval creates a new immutable release; `publish-release` signs a canonical
   manifest and atomically advances the wallpaper's `current_release_id`.

### Update an existing wallpaper

Text-only edits create a moderated metadata revision and do not alter artifact
identity. New media creates a new `wallpaper_release` edition. The previous
edition remains addressable for installed libraries and audit history, but only
the current approved edition is offered for new installs.

### Browse and search

Public catalog reads come from explicit safe views/RPCs, never raw internal
tables. Cursor pagination uses `(rank_score, published_at, wallpaper_id)` or a
surface-specific stable tuple. Detail responses include attribution, license,
creator, current release metadata, aggregate counts, and related IDs. Private
moderator notes, raw paths, account IDs, reports, and rights evidence never
enter catalog payloads.

### Install

1. An authenticated user requests an install for a published release.
2. The backend returns the signed release manifest and a short-lived idempotency
   receipt. Artifact URLs are immutable and restricted to the WALI CDN host.
3. WALI validates manifest schema, signature/key validity, URL host, counts,
   sizes, digests, and supported codecs before download.
4. WALI downloads to an opaque quarantine path. Redirects to another host,
   partial-length mismatch, symlinks, sparse-file anomalies, and quota overflow
   fail the attempt.
5. `WALITranscoder.xpc` inspects the downloaded canonical file with no network.
6. `WALIAgent` copies bytes into a fresh same-volume destination, independently
   hashes and validates them, then uses the existing no-replace publication and
   SQLite install journal from ADR 0005.
7. A catalog-origin `LibraryItem` pins the immutable release. A best-effort
   `install_success` event consumes the receipt; playback never depends on this
   analytics call.

### Report, takedown, and revocation

- A report creates a private case with a category and bounded plain-text detail.
- Moderators may hide a wallpaper pending review without deleting records.
- Copyright cases preserve the notice, counter-notice, deadlines, and actions
  outside public schemas.
- Normal takedown delists and stops new manifest issuance. Existing local files
  are not silently deleted.
- A critical malware/decoder-exploit response creates a signed release
  revocation. WALI refuses new install/selection and explains the security block.
  The revocation list targets catalog-origin releases only; local imports are
  never remotely controlled.

## Upload contract: creator input versus system facts

### Creator supplies

| Field | Required | Rule |
| --- | --- | --- |
| media file | yes | Accepted container/codec allowlist, bounded size/duration; never public as uploaded |
| title | yes | Plain text, normalized, 1–120 visible characters |
| description | yes | Plain text, normalized, 1–2,000 visible characters |
| primary category | yes | One active taxonomy ID |
| tags | optional | Up to 12 active taxonomy IDs; treated as suggestions |
| rights basis | yes | `original`, `licensed`, `public_domain`, or `other` |
| rights holder | yes | Plain text, 1–160 visible characters |
| license | yes | Active license/terms record allowing intended redistribution |
| source URL | conditional | HTTPS only; required for licensed/public-domain external sources |
| attribution text | conditional | Required when the chosen license requires it |
| proof file | conditional | Private PDF/image evidence; never served as wallpaper content |
| content warning | optional | Creator disclosure; does not replace moderation |

### System derives

| Field group | Examples |
| --- | --- |
| identity | UUIDs, edition, slug, idempotency keys, processing generation |
| byte facts | SHA-256, detected MIME/container, byte count |
| media facts | width, height, duration, frame rate, codec, pixel format, color space, audio/track count |
| artifacts | poster, thumbnail, preview, 1080p/1440p/4K variants as applicable |
| discovery | text and visual embeddings, suggested categories/tags and confidence, duplicate similarity |
| safety/quality | validation result, moderation state, quality score, rejection codes |
| operation | timestamps, actor IDs, worker/model versions, manifest schema, key ID, signature |
| metrics | verified installs, saves, favorites, reports, ranking feature snapshots |

Model output never overwrites creator input. Both are stored with provenance;
the approved public values are explicit moderator/editorial decisions.

## Relational schema

### Database shape

Authoritative tables live in a non-exposed `wali` schema. The Supabase Data API
exposes only the `public` schema, which contains deliberately safe views and
bounded RPC functions. Every table still enables RLS as defense in depth. The
application receives `anon`/`authenticated` access only to named public
surfaces; broad default table grants are revoked.

Required extensions are `pgcrypto`, `citext`, `vector`, `pgmq`, and `pg_cron`.
All primary keys are UUIDs generated server-side unless a content digest or
composite natural key is explicitly named. All mutable rows include
`created_at timestamptz`, `updated_at timestamptz`, and a monotonic integer
`revision` where optimistic concurrency matters.

### Controlled enums

| Type | Values |
| --- | --- |
| `account_status` | `active`, `suspended`, `deletion_pending`, `deleted` |
| `role_name` | `creator`, `moderator`, `admin` |
| `verification_status` | `unverified`, `pending`, `verified`, `rejected` |
| `wallpaper_status` | `draft`, `published`, `hidden`, `suspended`, `removed` |
| `visibility` | `public`, `unlisted` |
| `content_rating` | `everyone`, `teen`, `mature` |
| `submission_status` | `draft`, `uploading`, `uploaded`, `processing`, `processing_failed`, `ready_for_submission`, `submitted`, `under_review`, `changes_requested`, `approved`, `rejected`, `published`, `withdrawn` |
| `release_status` | `processing`, `review`, `approved`, `published`, `revoked` |
| `artifact_role` | `thumbnail`, `poster`, `preview`, `video_1080p`, `video_1440p`, `video_2160p`, `video_default` |
| `taxonomy_source` | `creator`, `classifier`, `moderator`, `editorial` |
| `tag_kind` | `subject`, `style`, `mood`, `color`, `motion`, `setting`, `format` |
| `suggestion_status` | `suggested`, `approved`, `rejected` |
| `rights_basis` | `original`, `licensed`, `public_domain`, `other` |
| `review_decision` | `approved`, `changes_requested`, `rejected` |
| `report_kind` | `copyright`, `impersonation`, `unsafe`, `sexual`, `hate`, `violence`, `spam`, `misleading`, `other` |
| `case_status` | `open`, `triaged`, `actioned`, `closed`, `appealed` |
| `event_kind` | `detail_view`, `install_requested`, `install_succeeded`, `favorite_added`, `favorite_removed`, `saved`, `unsaved`, `report_submitted` |
| `revocation_reason` | `critical_security`, `corrupt_artifact`, `signing_compromise` |

Enums that cross a client boundary are versioned API values. Unknown additive
values decode into a safe `unknown` client presentation and cannot grant a
capability.

### Identity and authorization

#### `wali.profiles`

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | uuid | PK, FK `auth.users(id)` on delete cascade |
| `handle` | citext | unique, 3–32 normalized characters |
| `display_name` | text | 1–80 plain-text characters |
| `avatar_path` | text nullable | generated Storage path only |
| `status` | account_status | default `active` |
| `deleted_at` | timestamptz nullable | soft-delete marker |

#### `wali.role_grants`

`(user_id, role)` is unique for an active grant. Rows record `granted_by`,
`granted_at`, `revoked_by`, `revoked_at`, and `reason`. Client JWT custom claims
may accelerate display but never authorize a privileged database action; the
server checks the current grant.

#### `wali.creator_profiles`

One-to-one with a profile: `bio`, `website_url`, `verification_status`,
`verified_at`, `verified_by`. URLs are HTTPS and rendered as inert links.

#### `wali.terms_acceptances`

Composite uniqueness on `(user_id, document_kind, document_version)`. Stores
acceptance timestamp and server request ID, not a raw IP address.

#### `wali.user_preferences`

One row per user: content-rating ceiling, locale, personalization opt-out, and
marketing opt-out. Display topology and local wallpaper assignments are never
stored here.

### Rights and taxonomy

#### `wali.licenses`

`id`, stable `code`, display `name`, optional `spdx_expression`, `terms_url`,
`attribution_required`, `commercial_use_allowed`, `derivatives_allowed`,
`redistribution_allowed`, `active`, and `terms_revision`. Content licenses that
are not software SPDX licenses retain a null SPDX expression.

#### `wali.categories`

`id`, nullable `parent_id`, unique `slug`, `name`, `description`, `sort_order`,
`active`. The initial tree is intentionally shallow: Nature, Space, Abstract,
Anime & Illustration, Games, Film & TV, Cars, Cities, Technology, Minimal,
Retro, and Other. Category changes are editorial and audited.

#### `wali.tags`

`id`, unique `slug`, `label`, `kind`, `active`. Users cannot create arbitrary
public tags in V1. This prevents synonym explosion and adversarial labels.

### Catalog

#### `wali.wallpapers`

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | uuid | PK |
| `creator_id` | uuid | FK profile, immutable after publication |
| `slug` | citext | unique public locator |
| `title` | text | normalized plain text, 1–120 |
| `description` | text | normalized plain text, 1–2,000 |
| `status` | wallpaper_status | current logical-page state |
| `visibility` | visibility | `public` or `unlisted` |
| `content_rating` | content_rating | moderator-approved |
| `primary_category_id` | uuid | FK active category |
| `license_id` | uuid | FK license |
| `rights_holder_display` | text | public attribution fact |
| `attribution_text` | text nullable | required by license policy when applicable |
| `source_url` | text nullable | public source link when required |
| `current_release_id` | uuid nullable | FK release, set only by publish transaction |
| `published_at` | timestamptz nullable | first publication |
| `search_document` | tsvector | derived title/description/creator/tags |

#### `wali.wallpaper_releases`

`id`, `wallpaper_id`, positive `edition`, `source_submission_id`, `status`,
`manifest_epoch`, `manifest_revision`, `manifest_digest`, `manifest_signature`,
`signing_key_id`, `published_at`, nullable `revoked_at`, and
`revocation_reason`. `(wallpaper_id, edition)` and `source_submission_id` are
unique. A trigger rejects mutation of media/manifest columns after publication.

#### `wali.artifacts`

`digest` is the lowercase SHA-256 primary key. Other columns are `media_type`,
`byte_count`, `storage_bucket`, `storage_path`, `width`, `height`,
`duration_ms`, `frame_rate_numerator`, `frame_rate_denominator`, `codec`,
`pixel_format`, `color_space`, `has_audio`, `verified_by_attempt_id`, and
`created_at`. Paths are generated, immutable, and unique; user filenames never
appear in paths.

#### `wali.release_artifacts`

Composite PK `(release_id, role)`, FK digest, optional `variant_name`, and
`sort_order`. A published release must have exactly one poster, thumbnail,
preview, and default video plus any eligible size variants.

#### `wali.wallpaper_categories`

Composite key `(wallpaper_id, category_id, source)`, with `confidence`,
`model_run_id`, `approved_by`, and `approved_at`. The explicit primary category
lives on `wallpapers`; this table provides secondary facets and provenance.

#### `wali.wallpaper_tags`

Composite key `(wallpaper_id, tag_id, source)`, with `confidence`, `status`,
`model_run_id`, `decided_by`, and `decided_at`. Only approved tags enter public
search and ranking.

#### `wali.wallpaper_embeddings`

Composite key `(wallpaper_id, release_id, modality, model_id, model_revision)`.
Stores a normalized `vector(768)`, input digest, and timestamp. V1 modalities
are `text`, `visual`, and `combined`. The model registry defines the dimension;
a model change writes new rows rather than silently replacing old vectors.

#### `wali.collections` and `wali.collection_items`

Collections have `slug`, title, description, kind (`editorial` or `system`),
status, optional artwork path, active window, and editor. Items have collection,
wallpaper, ordinal, optional editorial caption, and uniqueness on both the
ordinal and wallpaper within a collection.

### Creator and processing

#### `wali.upload_sessions`

`id`, `creator_id`, opaque `storage_path`, private `original_filename`,
`declared_byte_count`, nullable `received_byte_count`, nullable `source_digest`,
detected media type, status, expiry, completed timestamp, and idempotency key.
An upload can be bound to only one processing generation.

#### `wali.submissions`

`id`, `creator_id`, nullable `wallpaper_id` for updates, proposed public fields,
`upload_session_id`, `status`, `generation`, `revision`, timestamps for submit
and terminal decision, and last safe error code. The row is a review snapshot;
creator edits after submission require a new revision and return the state to
`draft` or `changes_requested`.

#### `wali.rights_declarations`

One active row per submission with `basis`, `rights_holder`, `license_id`,
`source_url`, `attribution_text`, private `proof_storage_path`, `attested_at`,
`creator_terms_version`, `review_status`, reviewer, and review timestamp.

#### `wali.processing_attempts`

`id`, `submission_id`, positive generation, queue message ID, status, lease
owner/expiry, `worker_build`, `media_image_digest`, `classifier_image_digest`,
safe error code, started/finished timestamps, and bounded output summary.
`(submission_id, generation)` is unique. Stale completions cannot advance the
submission.

#### `wali.classification_runs`

`id`, attempt, `model_id`, `model_revision`, model artifact digest, input frame
set digest, status, started/finished timestamps, and bounded raw result JSON.
Normalized tag/category suggestions are stored in the taxonomy join tables.

### Moderation and safety

#### `wali.moderation_reviews`

`id`, `submission_id`, `moderator_id`, decision, public creator-facing note,
private note, checklist revision, structured reason codes, and timestamp. A
moderator cannot approve their own submission. Publication requires the latest
completed processing generation and an approved rights declaration.

#### `wali.moderation_actions`

Append-only action log with actor, action, target type/ID, reason code, request
ID, and redacted metadata. Update/delete triggers reject mutation.

#### `wali.reports`

`id`, nullable reporter, wallpaper/release, kind, bounded detail, status,
assigned moderator, resolution code, and timestamps. Public clients can read
only their own report status, never other reports or moderator notes.

#### `wali.copyright_cases`

Private claimant/contact fields, notice and counter-notice object paths, target
release, statutory/event dates, status, assigned reviewer, and resulting
actions. Sensitive contact fields are not exposed through PostgREST and are
redacted from logs/analytics.

#### `wali.catalog_revocations`

Release ID, artifact digest, restricted reason, issued timestamp, signing key,
and signature-batch revision. Only critical technical-security reasons are
accepted. Copyright and policy removal use catalog state, not this mechanism.

### Engagement and ranking

#### `wali.favorites`, `wali.saved_wallpapers`, `wali.creator_follows`

Composite keys `(user_id, target_id)` plus timestamp. RLS restricts mutation and
raw reads to the owning user. Public counts come from aggregate tables only.

#### `wali.engagement_events`

Append-only rows with UUID, user, wallpaper, release, event kind, occurred
timestamp, client request ID, install receipt when applicable, and a minimal
coarse source. A uniqueness policy deduplicates install receipts and user/event/
release/day contributions used for ranking. A server-owned eligibility flag and
bounded exclusion reason determine whether an event contributes to ranking; the
client cannot set either. No window title, file path, display topology, playback
history, or raw IP is recorded.

#### `wali.wallpaper_stats_hourly` and `wali.wallpaper_stats_daily`

Per-wallpaper buckets for unique installers, install successes, favorites,
saves, detail views, and report counts. Aggregation excludes creator
self-interaction, suspended users, known abuse, duplicate receipts, and events
outside accepted time bounds.

#### `wali.ranking_snapshots`

`surface`, optional category/tag segment, `formula_version`, wallpaper,
computed score, ordinal, generated timestamp, and expiry. A snapshot is
reproducible from recorded feature inputs; changing weights increments the
formula version.

#### `wali.quality_assessments`

One immutable assessment per release/formula revision. It stores bounded
technical-completeness, variant-coverage, attribution-completeness,
moderator/editorial, and report-health components plus the total score and
input snapshot digest. Ranking reads the active formula's latest assessment;
popularity never enters this table.

#### `wali.user_interest_profiles`

One optional derived profile per user/model revision containing the normalized
preference vector, contributing interaction cutoff, generated timestamp, and
expiry. It contains no local playback or device state. Personalization opt-out
deletes the row and prevents regeneration.

#### `wali.command_idempotency`

Server commands reserve `(actor_id, operation, idempotency_key)` with the
request digest, status, stable response code/body digest, and expiry. Reusing a
key with different input fails. Completed commands return the prior safe result.

#### `wali.rate_limit_buckets`

Atomic, expiring counters keyed by a server-derived subject hash, operation,
and time window. Raw IP addresses are not stored. Limits are policy data and
cannot be modified by clients.

#### `wali.audit_events`

Append-only security/audit events for role changes, publication, suspension,
signing-key changes, rights decisions, and data export/deletion. Payloads are
schema-bounded and secret-free.

### Signing and model registries

#### `wali.catalog_signing_keys`

Public key ID, Ed25519 public key, validity interval, status, and rotation
metadata. Private key material exists only in the signing Edge Function secret
store. The app ships at least one trust anchor; online keyset changes require a
valid signature chain from an already trusted key.

#### `wali.model_registry`

Model ID/revision, task, source URL, upstream license, artifact digest,
embedding dimension, approved labels/taxonomy revision, approval actor/date,
and active status. No model runs in production until its code, weights, and
training-use limitations are recorded.

### Relationships

```text
auth.users 1--1 profiles 1--0..1 creator_profiles
     |              |--* role_grants
     |              `--* terms_acceptances
     |
     `--* submissions 1--1 rights_declarations
             |        `--* processing_attempts --* classification_runs
             |
             `--0..1 wallpapers 1--* wallpaper_releases
                                  |       `--* release_artifacts --1 artifacts
                                  |--* wallpaper_categories --1 categories
                                  |--* wallpaper_tags --1 tags
                                  |--* wallpaper_embeddings
                                  |--* reports
                                  `--* engagement_events
```

### Public API views

The exposed schema contains only:

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
- bounded RPCs for search, pagination, favorite/save/follow, report creation,
  and account export/deletion requests.

Views expose only published/active facts appropriate to the caller. Every view
uses `security_invoker` where supported; privileged transitions live behind
Edge Functions or narrowly reviewed `security definer` functions with a fixed
`search_path`, explicit authorization, and no dynamic SQL.

### Required indexes

- Unique indexes for handles, slugs, editions, generated object paths, active
  grants, idempotency keys, and install receipts.
- Partial indexes on published wallpapers/releases and open moderation cases.
- GIN index on `search_document`.
- HNSW indexes scoped by active embedding model and modality.
- B-tree indexes on creator/status/update time, category/publish time,
  submission/status, report/status, and ranking surface/segment/ordinal.
- Time-bucket indexes on engagement and audit tables; retention partitions are
  introduced only when measured volume warrants them.

## State machines

### Submission

```text
draft -> uploading -> uploaded -> processing -> ready_for_submission
                                      |               |
                                      v               v
                              processing_failed    submitted
                                                      |
                                                      v
                                                 under_review
                                              /       |       \
                                   changes_requested approved rejected
                                          |             |
                                          `-> draft     `-> published

draft|ready_for_submission|changes_requested -> withdrawn
```

Only server commands move state. Every command supplies expected `revision`
and an idempotency key. Illegal, stale, or duplicate transitions return stable
machine codes.

### Processing attempt

```text
queued -> leased -> downloading -> transcoding -> verifying -> classifying
   |         |            |              |             |           |
   `---------+------------+--------------+-------------+----------> failed

classifying -> completed
leased|downloading|transcoding|verifying|classifying -> timed_out
```

A lease expiry creates a new attempt generation; it never lets a stale worker
commit. Scratch cleanup is independent and idempotent.

### Wallpaper/release

```text
wallpaper: draft -> published -> hidden -> published
                         |          |
                         v          v
                     suspended -> removed

release: processing -> review -> approved -> published -> revoked
```

Published artifact and manifest fields are immutable. A revoked release cannot
return to published; recovery creates another edition.

## Storage and retention

| Bucket | Access | Contents | Retention |
| --- | --- | --- | --- |
| `uploads-private` | creator write to issued path; worker/service read | original media under opaque session IDs | delete 30 days after terminal decision; shorter for abandoned sessions |
| `moderation-private` | creator upload via issued path; moderator/service read | rights evidence, notices, counter-notices | policy/legal retention; never public CDN |
| `catalog-public` | public immutable read; service-only write | posters, thumbnails, previews, canonical videos, signed manifests | retain while referenced; no overwrite/upsert |
| `exports-private` | owner-only short-lived signed read | account data exports | delete after 7 days |

Published paths are content-addressed, for example
`sha256/ab/cd/<digest>/<role>.<ext>`. The database and object store both reject
an attempt to bind different bytes to the same digest/path. Raw uploads and
proof files never share a bucket with public artifacts.

Supabase database backups do not contain Storage objects. Before public launch,
a scheduled VM job must copy immutable catalog objects and protected originals
needed for active cases to an independent S3-compatible or GCS cold-backup
bucket, verify object digests, and emit a restore report. The provider is
replaceable; GCP is not part of the application runtime. Database PITR,
configuration export, signing public-key history, and quarterly restore drills
are required.

## Media policy and processing

### Accepted input

V1 accepts only MOV and MP4 containers containing a single supported video
track. Initial video codecs are H.264 and HEVC. Audio, subtitles, attachments,
chapters, data tracks, fonts, external references, edit lists with pathological
time ranges, and encrypted tracks are rejected or removed through canonical
decode/re-encode. Exact size/duration/dimension/frame-rate caps live in a
versioned policy document and are enforced before, during, and after decoding.

Recommended beta limits:

- maximum raw upload: 1 GiB;
- maximum duration: 10 minutes;
- maximum decoded dimensions: 7680 x 4320;
- maximum frame rate: 120 fps;
- maximum tracks: 2 at intake, exactly 1 video and 0 audio at output;
- maximum canonical output: 2 GiB across all variants;
- per-creator concurrent processing: 2; daily submission quota: configurable.

These are abuse limits, not promises that every allowed extreme will produce
every resolution variant.

### Canonical outputs

- H.264 MP4 default for broad compatibility; optional HEVC variants only after
  client capability negotiation is specified.
- No audio or non-video tracks.
- Square raster thumbnail and landscape poster in JPEG/PNG as policy chooses;
  never SVG, PDF, or animated image containers.
- Short, lower-bitrate preview with the same sanitized track rules.
- Metadata whitelist only; creator/source text comes from the database, not
  embedded media tags.
- Encoder build, arguments policy revision, and ffmpeg binary digest recorded
  with the attempt.

### Classification

Classification assists taxonomy; it does not moderate rights or publish. The
worker samples seven deterministic frames across the safe duration, converts
them to bounded RGB raster images in the media sandbox, and runs the pinned
Apache-2.0 `google/siglip-base-patch16-224` model in a separate networkless
classifier container. The controlled category/tag label set comes from a
versioned taxonomy snapshot. Title and description receive a text embedding
from the same model family; the stored combined vector is normalized.

Each output records model ID, exact upstream revision, model artifact digest,
taxonomy revision, frame-set digest, and confidence. Low-confidence or
conflicting suggestions remain invisible until a moderator approves them. A
`NoopClassifier` keeps local development and self-hosting functional without
downloading model weights; it never fabricates labels.

Model and dependency licenses must pass the repository allowlist before their
artifacts are mirrored or distributed. The model can be swapped by registering
a new revision and recomputing embeddings; no schema rewrite is required.

## Search, recommendations, and ranking

V1 ranking is deterministic, versioned, inspectable SQL plus embeddings—not a
black-box recommender service.

### Search

Candidate generation combines:

- PostgreSQL full-text relevance over title, description, creator, approved
  tags, and category;
- trigram/prefix matching for short titles and handles;
- text-to-wallpaper cosine similarity against the active combined embedding;
- hard filters for status, rating, category, tag, resolution, and duration.

The final score is:

```text
0.50 * normalized_full_text
+ 0.25 * normalized_semantic_similarity
+ 0.15 * quality_score
+ 0.10 * freshness_prior
```

Exact weights belong to `formula_version = search-v1`. Empty queries do not use
this formula; they use browse/editorial ordering.

### Trending

Hourly aggregation computes:

```text
0.45 * log1p(unique_install_successes_24h)
+ 0.25 * log1p(unique_saves_24h)
+ 0.10 * log1p(unique_favorites_24h)
+ 0.10 * quality_score
+ 0.10 * freshness_prior
- abuse_penalty
- unresolved_report_penalty
```

Inputs decay with a 36-hour half-life. One account contributes at most once per
release/day for install ranking; creator self-interaction and suspended/abusive
accounts contribute zero. A minimum unique-account threshold prevents a single
user from manufacturing “trending.”

### Related

Related candidates use combined embedding similarity, approved tag overlap,
category proximity, and aspect-ratio compatibility. The final list enforces
creator diversity and excludes the current wallpaper, hidden content, and near-
duplicate releases of the same wallpaper.

### Discover

Discover blends fixed slots rather than one opaque score:

1. approved editorial hero/collection;
2. trending;
3. new and noteworthy with a quality floor;
4. category rows;
5. “For You” when the user has enough explicit interactions;
6. a diverse fallback mix when personalization is off or sparse.

“For You” builds a user vector from saved, favorited, and installed wallpaper
embeddings, with explicit negative weight only for reports. It never reads local
playback duration, apps, files, or display arrangement. Users can disable
personalization; the service then deletes/refrains from storing the derived
preference vector.

### Quality score

Quality is a bounded, explainable combination of technical validity, useful
resolution variants, moderator/editorial assessment, low report rate, and
complete attribution. Popularity is not quality. Creator verification can be a
small trust feature but cannot dominate ranking.

## API and function contract

### Direct safe reads/RPCs

- `catalog_home_v1(locale, rating_ceiling)`
- `catalog_search_v1(query, filters, cursor, limit)`
- `catalog_browse_v1(category, tags, sort, cursor, limit)`
- `catalog_wallpaper_detail_v1(wallpaper_id)`
- `catalog_creator_v1(handle, cursor, limit)`
- `my_favorites_v1(cursor, limit)`
- `my_saved_wallpapers_v1(cursor, limit)`
- `set_favorite_v1(wallpaper_id, desired, idempotency_key)`
- `set_saved_v1(wallpaper_id, desired, idempotency_key)`
- `set_creator_follow_v1(creator_id, desired, idempotency_key)`

Limits are server-capped. Cursors are opaque base64url payloads with a version
and stable sort tuple; they are strictly decoded and bounded, but need no secret
because changing a cursor can affect only the caller's page position. Arbitrary
client order clauses are not accepted.

### Edge Functions

| Function | Caller | Responsibility |
| --- | --- | --- |
| `create-upload` | creator | quota check, session/path creation, resumable upload grant |
| `complete-upload` | creator | object fact check, immutable bind, queue processing |
| `submit-wallpaper` | creator | validate current generation, rights, metadata, transition to review |
| `moderate-submission` | moderator AAL2 | record decision/action, never publish stale generation |
| `publish-release` | moderator/admin AAL2 | immutable release transaction, canonical manifest, Ed25519 signature |
| `request-install` | user | current release check, manifest, idempotent install receipt |
| `record-install` | user | consume receipt after local success; ranking-safe deduplication |
| `report-wallpaper` | user | validate/rate-limit report and create case |
| `admin-role-grant` | admin AAL2 | grant/revoke elevated role with audit event |
| `request-account-export` | user | enqueue bounded export |
| `request-account-deletion` | user | mark deletion workflow and revoke sessions as policy requires |

Every function verifies JWT claims, current database authorization, request
schema/size, idempotency, expected revision, and rate limit. Responses use
stable error codes plus optional safe presentation text. Internal exception
details never cross the boundary.

## Signed release manifest

The canonical JSON envelope is versioned and bounded:

```json
{
  "schema": { "epoch": 1, "revision": 0 },
  "key_id": "catalog-2026-01",
  "wallpaper_id": "uuid",
  "release_id": "uuid",
  "edition": 1,
  "issued_at": "RFC3339",
  "artifacts": [
    {
      "role": "video_default",
      "url": "https://approved-cdn-host/...",
      "sha256": "64-lowercase-hex",
      "byte_count": 123,
      "media_type": "video/mp4",
      "width": 1920,
      "height": 1080,
      "duration_ms": 30000
    }
  ],
  "metadata_digest": "64-lowercase-hex"
}
```

The signature covers canonical UTF-8 bytes of the manifest body, not an
ambiguous parsed object. Arrays are canonically ordered; duplicate keys,
floating-point numbers, unknown epoch, excessive nesting/count/length, invalid
URLs, and inconsistent roles are rejected. Signature bytes travel outside the
body with the key ID. The manifest contains no user token, private Storage URL,
raw filename, or dynamic instruction.

## Authorization matrix

| Resource | Visitor | User | Creator owner | Moderator | Admin | Service worker |
| --- | --- | --- | --- | --- | --- | --- |
| published catalog views | read | read | read | read | read | read |
| own profile/preferences | none | read/write safe fields | same | same | same | none |
| another private profile row | none | none | none | none | audited admin operation | none |
| own upload/submission | none | none | read/write by state | read for review | read | processing-only fields |
| another creator submission | none | none | none | review read | read | processing assignment only |
| rights evidence | none | none | own issued upload/read status | review read | read | no access except required object fetch policy |
| moderation action | none | none | none | append within role | append | none |
| role grants | none | none | none | none | audited command | none |
| artifacts/public manifest | read | read | read | read | read | service write only |
| raw uploads | none | none | own issued path | canonical output only in app | incident access | time-limited read |
| engagement rows | none | own | own | aggregate only | aggregate/audit | append/aggregate jobs |

RLS tests must exercise anonymous, user A, user B, creator A, moderator, admin,
and service paths. The service-role bypass is never used as evidence that RLS
is correct.

## Security architecture

### Threat priorities

The highest-impact threats are:

1. malicious media exploiting a decoder and inheriting Full Disk Access;
2. object/path substitution between verification and publication;
3. service-role or signing-key extraction from an app, worker, log, or CI job;
4. broken RLS leaking drafts, rights proof, email/contact data, or moderation;
5. a creator overwriting already-approved bytes;
6. forged or replayed release manifests and install receipts;
7. moderator/admin account takeover;
8. poisoned dependencies, model weights, container images, or FFmpeg builds;
9. stored metadata injection into a native/web/legal surface;
10. resource exhaustion through decompression bombs, pathological media, queue
    floods, or ranking manipulation.

### Hostile upload controls

- Authenticate uploads and enforce per-user/session quotas before issuing a URL.
- Generate every path; ignore client filenames for storage/publication.
- Allowlist extensions, then independently validate magic bytes, container,
  track layout, and decoded limits. Never trust `Content-Type` alone.
- Keep originals private and separate from public CDN objects.
- Decode and fully re-encode in a fresh rootless, networkless sandbox with no
  credentials, host mounts, devices, or persistent home.
- Treat ffmpeg/ffprobe as vulnerable code: cap CPU, memory, PIDs, wall time,
  decoded frames, output bytes, and scratch space; patch and rebuild images.
- Verify outputs in a separate fresh sandbox. The control-plane worker only
  handles opaque bytes and bounded JSON.
- Strip all unnecessary tracks and metadata. Never accept active document or
  executable formats as wallpaper artifacts.
- Scan raw/proof uploads with a malware scanner as an additional signal, not a
  substitute for canonicalization or sandboxing.

### macOS containment

- `WALI.app`, `WALIAgent`, `WALITranscoder`, and `WALILockScreenHelper` each have
  the minimum separate entitlement set.
- Full Disk Access is optional and limited to the Lock Screen helper.
- The helper has no network client, media frameworks, scripting runtime,
  dynamic plugins, shell/process launching, or generic path API.
- XPC peers are authenticated by expected Team ID, bundle ID, designated
  requirement, protocol version, and bounded message schema.
- Downloaded catalog bytes follow the same destination-byte verification,
  same-volume preparation, no-replace publication, fsync, journal, lease, and
  recovery requirements as local imports.
- Hardened Runtime remains enabled. No JIT, unsigned executable memory,
  disabled library validation, debugger entitlement, or DYLD injection
  exception ships in Release.
- Release bundles are Developer ID signed, notarized, stapled, and verified as
  an exact nested-code graph.

### Auth and secret handling

- OAuth/session tokens live in Keychain and are redacted from errors.
- Service-role key exists only in Edge Function/VM secret stores; the VM secret
  is scoped to queue/storage/database operations required by the worker.
- Manifest signing uses a dedicated Ed25519 key, not a JWT secret or TLS key.
- Moderator/admin requires AAL2, short sessions, recent-auth checks for role or
  signing operations, and append-only audit.
- CI uses short-lived/OIDC credentials where supported. Repository secrets do
  not appear in forked pull-request jobs.
- Secret scanning and dependency/container scanning block release.

### Database controls

- RLS enabled on every table, explicit grants, and public-schema exposure
  reviewed by a failing allowlist check.
- `security definer` functions fix `search_path`, schema-qualify objects, reject
  arbitrary identifiers, and re-check the authenticated user/role.
- Database constraints enforce state transitions, ownership, immutability,
  uniqueness, and bounded scalar values in addition to application validation.
- Sensitive contact/proof data stays in the private schema and bucket.
- Audit and moderation action rows are append-only with mutation-rejecting
  triggers.
- Backups are encrypted, access-controlled, digest-verified, and restore-tested.

### Metadata and URL controls

All user text is Unicode-normalized, control characters removed, length-
bounded, and rendered as plain text. No user HTML is stored or interpreted.
External URLs must be HTTPS, exclude credentials/fragments where inappropriate,
and are never fetched by the backend merely because a creator supplied them.
Artifact downloads accept a fixed WALI CDN host and strict redirect policy,
preventing SSRF and local-file access.

## Privacy and analytics

WALI collects the minimum server data needed for marketplace operation:
account identity, explicit interactions, upload/moderation facts, and coarse
operational/security events. It does not upload local filenames, media library,
display geometry, desktop applications, playback timeline, lock/unlock history,
or wallpaper assignments.

Ranking uses explicit marketplace events. Product analytics is first-party,
documented, retention-bounded, and disabled for local-only use. Logs use request
IDs and stable error codes; emails, tokens, paths, rights proof, and raw metadata
are redacted. A data inventory specifies purpose, retention, access, and deletion
behavior for every table/bucket/log stream.

## Moderation and legal operations

Before public creator uploads are enabled, publish:

- Privacy Policy;
- Terms of Service;
- Creator Content License and distribution grant;
- Community/Content Guidelines;
- Copyright/DMCA notice and counter-notice process;
- designated agent/contact information where the launch jurisdiction requires;
- repeat-infringer policy;
- security reporting instructions;
- account export/deletion and support instructions.

This is a product and engineering checklist, not legal advice. Counsel should
review the documents and operating process before public UGC launch. The code
must make the promised workflow possible: preserve notices/actions, meet case
deadlines, delist promptly, support counter-notices, and audit account strikes.

## OSS and supply-chain policy

1. The WALI application remains Apache-2.0 and retains DCO-based contributions.
2. Every dependency, container base, FFmpeg build, model code, and model weight
   is pinned to an immutable version/digest and recorded in an SPDX SBOM.
3. An allowlist admits permissive dependencies by default. Copyleft, custom,
   non-commercial, research-only, or unclear model/content terms require an
   explicit legal/architecture decision.
4. FFmpeg runs as a separate executable. The project documents its exact build
   flags and complies with the resulting LGPL/GPL obligations; the default
   build avoids `--enable-gpl` and nonfree components unless a later accepted
   decision changes distribution obligations.
5. No wallpaper ships in seed data without a written redistribution grant or a
   compatible public-domain/Creative Commons basis plus required attribution.
6. No Backdrop/Wallsflow proprietary assets, endpoints, cookies, manifests,
   credentials, or brand elements enter the repository or service.
7. GitHub Actions are SHA-pinned. Renovation/dependency updates run verification
   and license-policy checks before merge.
8. Generated files, migrations, API contracts, fixtures, and license notices
   have named owners and documented regeneration commands.

## Operations

### Environments

Use separate Supabase projects for local, staging, and production. Migrations
flow forward from version control; Studio edits are never the source of truth.
Local development uses Supabase CLI and seeded synthetic media metadata. The VM
has separate staging/production configurations and cannot address another
environment's buckets or queue.

### Observability

Monitor:

- Edge Function error/latency/rate-limit counts;
- queue depth, oldest age, lease expiry, attempt failure code, and processing
  latency by worker/image version;
- Storage growth and orphan/reference reconciliation;
- auth failures, AAL2 coverage, role changes, RLS denials, and unusual report/
  install patterns;
- signing operations/key validity and manifest verification failures;
- macOS crash-free sessions, catalog download verification failures, and agent/
  helper IPC health through privacy-safe aggregate diagnostics.

No raw user metadata or media enters monitoring. Alerts are actionable and map
to a runbook.

### Reliability targets

- Published catalog read availability: Supabase managed service objective plus
  cached client content; installed playback remains independent of backend.
- No acknowledged publication without a signed manifest and immutable objects.
- At-least-once job processing with idempotent generation commits.
- Recovery point: database PITR tier; public artifacts reconstructable from
  independent object backup; restore drill every quarter.
- Worker replacement: rebuild a clean VM from documented image/config and drain
  expired leases; no hand-maintained state required.

### Incident response

Runbooks cover credential leak, signing-key compromise, malicious release,
copyright notice, RLS/data exposure, worker compromise, storage loss, and
ranking abuse. Signing compromise rotates the key, freezes publication, issues
a signed key/revocation transition from a surviving offline/root trust path,
and requires a new client release if no trusted key remains.

## Architecture decisions required before implementation

Create and explicitly accept these proposed ADRs before changing runtime code
or persistent schemas:

1. **0011 — Supabase marketplace control plane and one isolated VM media plane.**
2. **0012 — Immutable signed remote-catalog releases and catalog-origin local
   library records.**
3. **0013 — Separate Full Disk Access Lock Screen helper.** This partially
   supersedes the clauses in ADRs 0008–0010 that place Apple-store access in
   `WALIAgent`, without weakening their version gate, journaling, rollback, or
   authenticated-session limits.
4. **0014 — Marketplace database schemas, RLS/public façade, migrations, and
   environment policy.**
5. **0015 — Hostile media sandbox and canonicalization policy.**
6. **0016 — Minimal first-party engagement and ranking data policy.**

The first implementation checkpoint is ADR acceptance. Until then this document
is a design proposal, not permission to change production boundaries.

## Release gates

### Gate A — Architecture accepted

- All six ADRs accepted with reciprocal supersession metadata where required.
- Threat model reviewed; data inventory and retention policy approved.
- Content/license policy reviewed by counsel or explicitly held from public UGC.

### Gate B — Backend security proven

- All migrations replay cleanly from an empty local project.
- RLS/grant tests pass for every role and cross-user attempt.
- Storage policy tests prove path ownership and immutable service-only publish.
- State-machine, idempotency, stale-generation, and manifest signature tests pass.
- Staging backup restore reconstructs database references and object digests.

### Gate C — Media containment proven

- Malformed/truncated/bomb/pathological corpus cannot escape quotas or sandbox.
- Processing containers have no network, credentials, host paths, capabilities,
  writable root, or long-lived state.
- Independent verification detects substituted/corrupt outputs.
- Exact FFmpeg/model/container digests and licenses appear in SBOM/NOTICE.

### Gate D — macOS privilege separation proven

- `WALIAgent` operates without Full Disk Access.
- Only `WALILockScreenHelper` appears in the Full Disk Access consent path.
- Static checks prove forbidden frameworks/APIs are absent from the helper.
- XPC peer-authentication and malformed-message suites fail closed.
- Local and downloaded hostile media reach only the transcoder sandbox before
  verified publication.
- Existing desktop, multi-display, pause, scaling, and Lock Screen behavior pass
  live signed Development validation.

### Gate E — Public beta ready

- Creator, moderator, report, takedown, account deletion, and recovery flows are
  operable end to end in staging.
- Legal/support pages are public and linked in-app.
- Notarized release verifies nested signatures and entitlements.
- Seed catalog contains only licensed/owned media and complete attribution.
- Load test demonstrates expected catalog/search/upload concurrency with room
  to grow; worker queue backpressure is visible.
- Runbooks, on-call contacts, key rotation, restore evidence, and rollback are
  present.

## Sprint boundary and expected repository shape

One focused sprint can deliver the public-beta foundation because managed
Supabase services replace most infrastructure. The detailed plan names 193 new
files and 43 existing files that may be touched; implementation should
consolidate wherever a smaller coherent module is clearer and must stay below
200 new files. The additions are dominated by SQL migrations/policy tests,
Edge Functions, worker/sandbox code, Swift catalog/upload integration, security
fixtures, and documentation. The file count is a ceiling, not a target.

The sprint delivers the architecture, schema, auth, publishing pipeline,
catalog/search/detail, upload/review surfaces, secure install, rankings, legal
hooks, and operational gates. It does not promise a large licensed seed catalog,
payment system, advanced collaborative filtering, or universal macOS private-
store compatibility.

## References

- [Supabase Storage](https://supabase.com/docs/guides/storage)
- [Supabase resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)
- [Supabase Sign in with Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Queues](https://supabase.com/docs/guides/queues)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
- [Supabase database backups and Storage limitation](https://supabase.com/docs/guides/database/overview)
- [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple XPC service guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- [Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Apple Full Disk Access](https://support.apple.com/en-gb/guide/mac-help/mchl211c911f/mac)
- [OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)
- [NIST SP 800-190: Application Container Security Guide](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf)
- [FFmpeg legal and license guidance](https://ffmpeg.org/legal.html)
- [SPDX](https://spdx.dev/)
- [SigLIP model card and license](https://huggingface.co/google/siglip-base-patch16-224)
- [U.S. Copyright Office Section 512 overview](https://www.copyright.gov/512/)
