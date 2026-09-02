# WALI Marketplace Foundation Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Deliver a production-ready free wallpaper marketplace foundation inside the WALI macOS app: accounts, secure creator upload, canonical media processing, moderation, signed catalog releases, browse/search/detail, secure local install, basic ranking, OSS/legal controls, and privilege separation for Full Disk Access.

**Architecture:** Supabase is the only public control plane (Auth, Postgres, Storage/CDN, Queues, Cron, short Edge Functions). One dedicated Linux VM runs a small Go queue worker that launches fresh rootless, networkless media/verifier/classifier containers. WALI adds a shared catalog-contract module plus a foreground Supabase adapter. `WALIAgent` remains the local install/render authority without Full Disk Access; a separate narrow helper owns only the experimental Lock Screen store mutation.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, CryptoKit, XPC, SQLite, Supabase Swift SDK, Supabase Auth/Postgres/Storage/Edge Functions/Queues/Cron, PostgreSQL RLS/pgTAP/pgvector, Deno TypeScript, Go, rootless Podman, FFmpeg/ffprobe, Python/SigLIP, Docker/OCI images, GitHub Actions, SPDX SBOM.

---

## Source of truth and sprint contract

The product, data, security, ranking, storage, and release decisions for this
plan are specified in
`docs/design/2026-09-01-marketplace-foundation.md`. Implementation must not
silently weaken that document. Where implementation evidence forces a change,
amend the proposed design and ADR before changing code.

Begin integration from the current protected base only after the approved
wallpaper-detail and Lock Screen work has landed. Reuse that work; never replace
or recreate another task's uncommitted files.

This is one focused public-beta foundation sprint. It is deliberately not a
payment sprint, a licensed-content acquisition sprint, or a website sprint.
The explicit inventory below names 193 new files and 43 existing files that may
be touched. Consolidate when it improves cohesion and do not exceed 200 new
files; the count is a ceiling, not an acceptance criterion.

### Required implementation lanes

After the ADR checkpoint, work can proceed in parallel in tess-owned worktrees:

| Lane | Tasks | Merge dependency |
| --- | --- | --- |
| Architecture/security | 1–2 | first; all other lanes consume accepted contracts |
| Database/API | 3–9 | migrations before functions; RLS before staging access |
| Media worker | 10–13 | queue/storage contract from Tasks 4–7 |
| macOS catalog | 14–18 | catalog/manifest contracts from Tasks 2, 6, 8 |
| Privilege split | 19–20 | ADR 0013 accepted; merge before public media install |
| Operations/release | 21–23 | consumes every lane; final launch gate |

Use `tess new`, `tess path`, `tess status`, `tess diff`, and `tess ship`; never
use raw `git worktree`. Do not commit, push, open a PR, or ship a lane until the
repository owner explicitly authorizes publication. Commit commands below are
named checkpoints, not standing authorization.

### Ten-working-day sprint map

| Day | Critical path | Parallel work |
| --- | --- | --- |
| 1 | ADR review and acceptance | API/media/data contract fixtures |
| 2 | Supabase foundation and RLS skeleton | worker and catalog-contract scaffolds |
| 3 | catalog/creator/moderation migrations | media/verifier containers; Swift auth adapter |
| 4 | storage/queues/public API | classifier; Discover/Browse data flow |
| 5 | Edge Functions and signed publication | Creator Studio and detail integration |
| 6 | end-to-end processing in staging | catalog download and agent install |
| 7 | Full Disk Access helper split | moderation UI, ranking, reports |
| 8 | cross-lane integration and hostile corpus | legal, SBOM, backup/runbooks |
| 9 | RLS/security/load/restore/key-rotation gates | native accessibility/visual polish |
| 10 | signed macOS live verification and staging canary | evidence, fixes, release review |

Autonomous parallel implementation can compress active coding, but ADR approval,
staging media processing, restore proof, signing-key exercises, and signed live
macOS verification remain sequential release gates. If a gate fails, fix it;
do not trade it for the calendar target.

### Test policy

Do not generate low-value snapshot tests, one-test-per-field CRUD tests, or UI
tests that merely restate SwiftUI layout. Tests are mandatory only where they
protect a security boundary, state transition, migration, data-access rule,
signature, path/digest invariant, recovery behavior, or the primary user flow.
Automated tests must never write the live Apple wallpaper store.

## Definition of done

- A fresh checkout can start local Supabase, replay every migration, seed only
  redistributable synthetic fixtures, and pass database/RLS tests.
- A creator can sign in with Apple, upload a video, see processing results,
  submit it, and receive a moderator decision.
- A moderator with AAL2 can approve only the current processed generation.
- Publication creates immutable CDN artifacts plus a signed manifest; an old or
  tampered manifest cannot install.
- A user can browse, search, open the full-bleed detail surface, install, save,
  favorite, and report a wallpaper.
- The agent installs catalog media through the existing content-addressed
  journal and plays it offline after verification.
- Raw or downloaded hostile media never executes in a process with Full Disk
  Access. `WALIAgent` runs without it; only the narrow helper is eligible.
- Ranking/search are deterministic, versioned, privacy-bounded, and degrade to
  editorial/manual taxonomy if classification is unavailable.
- Backup restore, signing-key rotation, takedown, critical revocation, worker
  replacement, and account deletion have exercised runbooks.
- Release bundle is Hardened Runtime enabled, Developer ID signed, notarized,
  stapled, and has an exact verified nested-code/entitlement graph.
- Every shipped dependency, model, container, and seed asset has license and
  provenance records.

## Phase 0 — decisions and contracts

### Task 1: Record and accept the marketplace ADR set

**Files:**

- Create: `docs/adr/0011-supabase-marketplace-control-plane.md`
- Create: `docs/adr/0012-signed-remote-catalog-releases.md`
- Create: `docs/adr/0013-separate-full-disk-access-helper.md`
- Create: `docs/adr/0014-marketplace-schema-and-rls.md`
- Create: `docs/adr/0015-hostile-media-canonicalization.md`
- Create: `docs/adr/0016-minimal-engagement-and-ranking-data.md`
- Modify: `docs/adr/0008-session-lock-aerial-adapter.md`
- Modify: `docs/adr/0009-global-linked-lock-screen-activation.md`
- Modify: `docs/adr/0010-restart-lock-screen-playback-on-session-lock.md`
- Modify: `ARCHITECTURE.md`
- Modify: `SECURITY.md`
- Modify: `docs/architecture/modules.yml`
- Modify: `docs/compatibility/surfaces.yml`
- Modify: `docs/migrations.md`

**Steps:**

1. Draft all six ADRs with `status: proposed`, controlled owner roles,
   `accepted_by: pending`, and the exact invariants from the design document.
2. ADR 0013 must partially supersede only the process-ownership clauses that put
   Apple-store access in `WALIAgent`. Add reciprocal `superseded_by`,
   `superseded_scope`, `supersedes`, and `supersedes_scope` metadata to ADRs
   0008–0010 without rewriting their history.
3. Record the new targets, catalog manifest epoch, server schema epoch, model
   registry, signing keys, storage paths, and public API versions in the module
   and compatibility inventories.
4. Add architecture checks requiring accepted ADRs before the corresponding
   targets, schemas, remote dependency, or network code may appear.
5. Present the ADR bundle to the project owner. Stop implementation if the owner
   does not explicitly accept it; do not infer acceptance from this plan.
6. After approval, fill the controlled acceptance fields and run:

   ```bash
   make check-architecture
   git diff --check
   ```

   Expected: architecture policy passes and every supersession reference is
   reciprocal.

**Checkpoint after explicit owner authorization:**

```bash
git add docs/adr ARCHITECTURE.md SECURITY.md docs/architecture docs/compatibility docs/migrations.md
git commit -m "docs: define marketplace security architecture"
```

### Task 2: Define versioned public contracts and generated boundaries

**Files:**

- Create: `docs/api/catalog-v1.md`
- Create: `docs/api/creator-v1.md`
- Create: `docs/api/moderation-v1.md`
- Create: `docs/security/marketplace-threat-model.md`
- Create: `docs/security/data-inventory.yml`
- Create: `docs/security/media-policy.yml`
- Create: `docs/security/dependency-policy.yml`
- Create: `Fixtures/Catalog/manifest-v1.json`
- Create: `Fixtures/Catalog/manifest-v1.signature`
- Create: `Fixtures/Catalog/revocations-v1.json`
- Create: `Fixtures/Catalog/invalid/duplicate-key.json`
- Create: `Fixtures/Catalog/invalid/oversized-count.json`
- Create: `Fixtures/Catalog/invalid/unapproved-host.json`
- Create: `scripts/check-marketplace-contracts.rb`
- Modify: `scripts/check-architecture.sh`
- Modify: `Tests/Architecture/check-architecture-tests.sh`

**Steps:**

1. Specify exact request, response, cursor, error-code, idempotency, maximum-size,
   and authorization contracts for every public view/RPC and Edge Function.
2. Specify canonical JSON rules for manifest and revocation bodies: UTF-8,
   unique keys, integers only, stable field order, stable artifact ordering,
   bounded nesting/count/string/byte values, and no unknown epoch.
3. Put the exact accepted upload/output limits in `media-policy.yml`; both Edge
   Functions and worker code must consume generated constants or verify their
   checked-in copy matches the policy digest.
4. Enumerate every stored data category, purpose, access role, retention,
   deletion behavior, and backup treatment in `data-inventory.yml`.
5. Add architecture checks that reject an exposed table not on the API allowlist,
   a helper target importing a forbidden framework, an unpinned remote
   dependency, or a missing compatibility entry.
6. Add mutation cases to the architecture checker proving each new check fails
   on a deliberately invalid fixture.
7. Run:

   ```bash
   ./scripts/check-marketplace-contracts.rb
   ./Tests/Architecture/check-architecture-tests.sh
   make check-architecture
   ```

   Expected: valid fixtures pass; every invalid mutation fails with a stable
   policy code.

## Phase 1 — Supabase data plane

### Task 3: Scaffold local Supabase and environment-safe configuration

**Files:**

- Create: `supabase/config.toml`
- Create: `supabase/seed.sql`
- Create: `supabase/.gitignore`
- Create: `supabase/README.md`
- Create: `Config/Marketplace.example.xcconfig`
- Create: `Services/WALIMediaWorker/config.example.toml`
- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Modify: `Makefile`

**Steps:**

1. Initialize a conventional Supabase project without linking it to production.
2. Expose only the `public` schema through the local Data API; retain
   authoritative tables in `wali`.
3. Add Make targets: `backend-start`, `backend-stop`, `backend-reset`,
   `backend-test`, `worker-test`, and `marketplace-verify`. None may require
   production credentials.
4. Check in variable-name examples only. Never write a real Supabase URL/key,
   Apple secret, service-role key, signing private key, or backup credential.
5. Seed deterministic UUIDs, accounts, categories, tags, wallpapers, and
   artifact metadata using generated synthetic color/video fixtures only.
6. Run:

   ```bash
   supabase start
   supabase db reset
   supabase status
   ```

   Expected: local services are healthy; reset applies all migrations and seed
   data without network access to production.

### Task 4: Create extensions, schemas, common domains, and auth helpers

**Files:**

- Create: `supabase/migrations/202609010001_extensions_and_schemas.sql`
- Create: `supabase/migrations/202609010002_identity_and_roles.sql`
- Create: `supabase/tests/database/001_identity_rls.test.sql`
- Create: `supabase/tests/database/002_role_authorization.test.sql`

**Steps:**

1. Enable `pgcrypto`, `citext`, `vector`, `pgmq`, and `pg_cron` in explicit
   schemas supported by Supabase.
2. Create `wali`; revoke default access from `anon` and `authenticated`.
3. Create all controlled enums from the design document with comments marking
   their public versioning behavior.
4. Create `profiles`, `role_grants`, `creator_profiles`, `terms_acceptances`, and
   `user_preferences` with server-side bounds, uniqueness, revision, and
   timestamp triggers.
5. Create auth helper functions for current user, active role, and AAL checks.
   Use `security definer` only when necessary, set a fixed empty/safe
   `search_path`, and schema-qualify every object.
6. Add an `auth.users` trigger that creates a minimal profile; do not accept role
   grants from user metadata.
7. Enable RLS and add owner policies. Users cannot inspect another user's
   private profile/preferences/terms rows.
8. In pgTAP, impersonate anonymous, user A, user B, creator, moderator, admin,
   and service roles. Prove cross-user reads/writes and client role escalation
   fail.
9. Run:

   ```bash
   supabase db reset
   supabase test db
   ```

   Expected: all identity/role tests pass; no internal table is granted broadly.

### Task 5: Create catalog, taxonomy, rights, and immutable release schema

**Files:**

- Create: `supabase/migrations/202609010003_catalog_and_taxonomy.sql`
- Create: `supabase/migrations/202609010004_releases_and_artifacts.sql`
- Create: `supabase/tests/database/003_catalog_invariants.test.sql`
- Create: `supabase/tests/database/004_release_immutability.test.sql`

**Steps:**

1. Create `licenses`, `categories`, `tags`, `wallpapers`, `wallpaper_releases`,
   `artifacts`, `release_artifacts`, `wallpaper_categories`, `wallpaper_tags`,
   `wallpaper_embeddings`, `collections`, and `collection_items` exactly as
   specified in the design.
2. Add text/range/check constraints and FK delete policies that preserve
   published/audit history.
3. Create the `tsvector` search-document maintenance function using title,
   description, creator, primary category, and approved tags.
4. Create unique, partial, GIN, and HNSW indexes named in the design. HNSW
   queries must filter to an active model revision.
5. Add deferrable current-release linkage so a publish transaction can create
   the release and atomically set `wallpapers.current_release_id`.
6. Add triggers that reject any media, digest, path, edition, manifest, signing,
   or publication mutation after a release is published.
7. Prove that different bytes cannot reuse an artifact digest/path and that a
   release lacking required roles cannot publish.
8. Prove a normal authenticated client cannot insert/update artifacts, releases,
   approved taxonomy, collections, signatures, or current-release pointers.
9. Run `supabase db reset && supabase test db`.

### Task 6: Create upload, processing, moderation, report, and audit schema

**Files:**

- Create: `supabase/migrations/202609010005_creator_processing.sql`
- Create: `supabase/migrations/202609010006_moderation_and_reports.sql`
- Create: `supabase/tests/database/005_submission_state_machine.test.sql`
- Create: `supabase/tests/database/006_moderation_rls.test.sql`
- Create: `supabase/tests/database/007_audit_append_only.test.sql`

**Steps:**

1. Create `upload_sessions`, `submissions`, `rights_declarations`,
   `processing_attempts`, `classification_runs`, `moderation_reviews`,
   `moderation_actions`, `reports`, `copyright_cases`, `catalog_revocations`,
   `catalog_signing_keys`, `model_registry`, and `audit_events`.
2. Implement state-transition functions that accept expected revision and
   idempotency key; reject client-written state values.
3. Enforce one active processing generation, stale-worker rejection,
   own-submission review prohibition, current rights review, and current
   processing completion before approval/publication.
4. Make audit/moderation action rows append-only through privilege and triggers.
5. Put claimant contact, proof paths, private notes, worker leases, and raw model
   output outside all public views.
6. Prove creators can see/update only their own allowed draft fields, cannot
   publish, cannot approve taxonomy, and cannot overwrite an uploaded object
   binding after submission.
7. Prove a moderator requires AAL2 and cannot approve their own submission.
8. Prove duplicate/stale commands are idempotent or fail with the expected
   stable code.
9. Run `supabase db reset && supabase test db`.

### Task 7: Create engagement, aggregation, search, and public façade

**Files:**

- Create: `supabase/migrations/202609010007_engagement_and_ranking.sql`
- Create: `supabase/migrations/202609010008_public_api.sql`
- Create: `supabase/tests/database/008_public_api_exposure.test.sql`
- Create: `supabase/tests/database/009_ranking_and_abuse.test.sql`
- Create: `supabase/tests/database/010_cursor_stability.test.sql`

**Steps:**

1. Create favorites, saved wallpapers, follows, engagement events, hourly/daily
   stats, ranking snapshots, quality assessments, user interest profiles,
   command idempotency records, and rate-limit buckets.
2. Add deduplication rules for install receipts and one-user/release/day ranking
   contribution. Exclude creator self-interaction and inactive accounts.
3. Implement `search-v1`, `trending-v1`, related, browse, and Discover slot
   calculations exactly from the design; record formula version and inputs.
4. Create the explicit `public` catalog/profile/creator/self views and RPCs.
   Revoke every other public-schema grant.
5. Use cursor pagination with stable tie breakers. Cap limits and filter values;
   never accept arbitrary SQL order/filter fragments.
6. Prove anonymous reads see only published safe fields; user A cannot see user
   B interactions; suspended/hidden content disappears; private paths/notes do
   not appear in `information_schema`-derived public column allowlists.
7. Prove rankings are stable for a fixed clock/input and resist duplicate
   receipts, creator self-installs, and one-account event floods.
8. Run `supabase db reset && supabase test db`.

### Task 8: Create Storage policies, queue, cron, and retention jobs

**Files:**

- Create: `supabase/migrations/202609010009_storage_policies.sql`
- Create: `supabase/migrations/202609010010_queues_and_cron.sql`
- Create: `supabase/tests/database/011_storage_policies.test.sql`
- Create: `supabase/tests/database/012_queue_and_retention.test.sql`
- Modify: `supabase/seed.sql`

**Steps:**

1. Create `uploads-private`, `moderation-private`, `catalog-public`, and
   `exports-private` buckets with explicit size and MIME policy.
2. Permit creators to write only the exact opaque object path issued for their
   active upload/proof session. Deny list access and overwrite/upsert.
3. Permit only service operations to write public catalog objects; allow public
   immutable reads. Raw uploads and proof paths remain private.
4. Create processing, export, aggregation, cleanup, and backup-verification
   queues with bounded retry/dead-letter behavior.
5. Schedule hourly stats/ranking, stale lease recovery, abandoned upload cleanup,
   export expiry, orphan reconciliation, and backup verification with `pg_cron`.
6. Prove a creator cannot read another upload, guess/list paths, overwrite an
   object, or promote bytes into the public bucket.
7. Prove cleanup never removes an object referenced by a current release, open
   copyright case, active attempt, or unexpired export.
8. Run `supabase db reset && supabase test db`.

### Task 9: Implement bounded Edge Functions

**Files:**

- Create: `supabase/functions/import_map.json`
- Create: `supabase/functions/_shared/auth.ts`
- Create: `supabase/functions/_shared/database.ts`
- Create: `supabase/functions/_shared/errors.ts`
- Create: `supabase/functions/_shared/idempotency.ts`
- Create: `supabase/functions/_shared/manifest.ts`
- Create: `supabase/functions/_shared/rate-limit.ts`
- Create: `supabase/functions/_shared/validation.ts`
- Create: `supabase/functions/create-upload/index.ts`
- Create: `supabase/functions/complete-upload/index.ts`
- Create: `supabase/functions/submit-wallpaper/index.ts`
- Create: `supabase/functions/moderate-submission/index.ts`
- Create: `supabase/functions/publish-release/index.ts`
- Create: `supabase/functions/request-install/index.ts`
- Create: `supabase/functions/record-install/index.ts`
- Create: `supabase/functions/report-wallpaper/index.ts`
- Create: `supabase/functions/admin-role-grant/index.ts`
- Create: `supabase/functions/request-account-export/index.ts`
- Create: `supabase/functions/request-account-deletion/index.ts`
- Create: `supabase/functions/tests/marketplace-functions.test.ts`

**Steps:**

1. Pin Deno/Supabase dependencies to reviewed immutable versions. Share only
   cross-cutting auth/validation/error/idempotency/manifest code; do not build a
   generic action framework.
2. Validate JWT, current DB role, AAL2 where required, request content type,
   exact schema, maximum body size, expected revision, idempotency, and rate
   limit before mutation.
3. `create-upload` generates the opaque path and TUS grant. `complete-upload`
   checks server-observed object facts and enqueues one processing generation.
4. Creator/moderator functions call the database's constrained state commands;
   service-role access is never used to bypass a missing business check.
5. `publish-release` opens one DB transaction, confirms current approval,
   canonicalizes the manifest, signs with Ed25519, writes the signature/key ID,
   advances the current release, and records an audit event. No private key is
   persisted in Postgres.
6. Install functions issue/consume one-time receipts. Playback does not depend
   on successful metrics reporting.
7. Return stable codes and safe messages; log only request IDs, actor IDs, and
   redacted reason codes.
8. Test wrong role/AAL, stale revision, duplicate idempotency, oversized body,
   forged object path, hidden release, tampered manifest, and success paths
   against local Supabase.
9. Run:

   ```bash
   deno fmt --check supabase/functions
   deno lint supabase/functions
   deno test --allow-env --allow-net=127.0.0.1 supabase/functions/tests
   ```

## Phase 2 — isolated media plane

### Task 10: Implement the Go worker control plane

**Files:**

- Create: `Services/WALIMediaWorker/go.mod`
- Create: `Services/WALIMediaWorker/go.sum`
- Create: `Services/WALIMediaWorker/cmd/wali-media-worker/main.go`
- Create: `Services/WALIMediaWorker/internal/config/config.go`
- Create: `Services/WALIMediaWorker/internal/queue/consumer.go`
- Create: `Services/WALIMediaWorker/internal/storage/client.go`
- Create: `Services/WALIMediaWorker/internal/jobs/processor.go`
- Create: `Services/WALIMediaWorker/internal/jobs/lease.go`
- Create: `Services/WALIMediaWorker/internal/sandbox/runner.go`
- Create: `Services/WALIMediaWorker/internal/claims/decoder.go`
- Create: `Services/WALIMediaWorker/internal/telemetry/metrics.go`
- Create: `Services/WALIMediaWorker/internal/jobs/processor_test.go`
- Create: `Services/WALIMediaWorker/internal/claims/decoder_test.go`
- Consolidate the media-worker contract in: `docs/runbooks/media-worker.md`

**Steps:**

1. Implement one bounded `ProcessSubmission` job schema with attempt ID,
   submission ID, generation, input bucket/path/digest/size, policy digest, and
   deadlines. Reject unknown versions and fields beyond bounded extension data.
2. Lease from `pgmq`, heartbeat only the active generation, and make completion
   conditional on the same attempt/generation/lease owner.
3. Download opaque bytes to an exclusive file under a per-attempt directory.
   The Go process never calls ffprobe, opens media codecs, or derives a filename
   from user input.
4. Invoke rootless Podman through a fixed argv builder—never a shell string.
   Permit only named images by immutable digest and fixed mounts/limits.
5. Decode bounded JSON claims with `DisallowUnknownFields`, size limits, integer
   bounds, safe codes, and exact expected artifact counts.
6. Upload by digest to service-authorized immutable paths with create-only
   semantics; a pre-existing object is reusable only after digest/size match.
7. Ack only after the DB generation commit. Nack/retry transient errors; move
   permanent policy failures to a terminal safe code; always enqueue scratch
   cleanup.
8. Test lease expiry, duplicate delivery, stale completion, truncated claim,
   path/argv injection, timeout, Podman crash, partial upload, and cleanup retry.
9. Run:

   ```bash
   cd Services/WALIMediaWorker
   gofmt -w .
   go vet ./...
   go test -race ./...
   ```

### Task 11: Build the networkless media and verifier images

**Files:**

- Create: `Services/WALIMediaSandbox/Containerfile`
- Create: `Services/WALIMediaSandbox/bin/process-media`
- Create: `Services/WALIMediaSandbox/bin/verify-media`
- Create: `Services/WALIMediaSandbox/policy/ffmpeg-policy.json`
- Create: `Services/WALIMediaSandbox/tests/run-corpus.sh`
- Create: `Services/WALIMediaSandbox/tests/fixtures/README.md`
- Create: `Services/WALIMediaSandbox/THIRD_PARTY_NOTICES.md`
- Consolidate the media-sandbox contract in: `docs/runbooks/media-worker.md`

**Steps:**

1. Pin the base image and FFmpeg package/build by digest. Record exact configure
   flags and license obligations; default to an LGPL-compatible build without
   GPL/nonfree components.
2. `process-media` validates container signature/track inventory/declared
   limits, fully decodes/re-encodes through fixed argv templates, strips audio
   and metadata, emits only approved raster/video roles, and writes a bounded
   claim JSON last.
3. The script uses strict shell settings only for fixed project-owned values;
   no user value is evaluated, expanded as an option, or used as a path.
4. `verify-media` runs in a separate container and independently checks digest,
   byte count, decoded bounds, exact track layout, codec/pixel/color policy, and
   role relationships.
5. Configure runner flags: rootless user, `--network=none`, read-only root,
   dropped capabilities, `no-new-privileges`, no devices, fixed read-only input,
   bounded output/tmpfs, PIDs/CPU/memory/file-size/wall timeout, no host home.
6. Add a compact public-domain/generated hostile corpus: empty/truncated files,
   spoofed extension/MIME, excessive tracks, long duration metadata, huge
   dimensions, frame-rate extremes, corrupt atoms, symlink/FIFO/device attempts,
   and output-quota exhaustion.
7. Prove the corpus produces safe codes, no network traffic, no files outside
   output, no credential visibility, and no lingering process/container.
8. Run the corpus test under the same rootless runtime used in staging.

### Task 12: Build the deterministic classifier image

**Files:**

- Create: `Services/WALIClassifier/pyproject.toml`
- Create: `Services/WALIClassifier/uv.lock`
- Create: `Services/WALIClassifier/Containerfile`
- Create: `Services/WALIClassifier/wali_classifier/classify.py`
- Create: `Services/WALIClassifier/wali_classifier/contracts.py`
- Create: `Services/WALIClassifier/model-manifest.json`
- Create: `Services/WALIClassifier/taxonomy-v1.json`
- Create: `Services/WALIClassifier/tests/test_contract.py`
- Create: `Services/WALIClassifier/THIRD_PARTY_NOTICES.md`
- Consolidate the classifier contract in: `docs/runbooks/media-worker.md`

**Steps:**

1. Pin Python, inference libraries, `google/siglip-base-patch16-224`, its exact
   upstream revision, and every model file digest. Mirror weights only after the
   Apache-2.0/model-card provenance review is recorded.
2. Accept only seven bounded raster frames, normalized title/description, and a
   fixed taxonomy snapshot. No URL, arbitrary prompt, pickle, plugin, remote
   model code, or runtime download is accepted.
3. Run with offline/local-files-only flags in a networkless, read-only rootless
   container. Prefer safetensors; reject unsafe serialized weight formats.
4. Emit normalized visual/text/combined embeddings plus category/tag scores in
   a bounded JSON contract. Results include model, model revision, model digest,
   taxonomy revision, and input-frame-set digest.
5. Keep thresholds conservative. The worker stores low-confidence output as a
   suggestion; it never promotes content or publishes.
6. Implement `NoopClassifier` in the Go worker for local/self-hosted operation
   without weights; it emits an explicit unavailable state, never fake tags.
7. Test deterministic fixture output, corrupt/extra inputs, oversized text,
   missing model, unsafe weight file, taxonomy mismatch, and offline startup.
8. Run `uv run pytest` and image license/SBOM checks.

### Task 13: Provision the replaceable worker VM and staging pipeline

**Files:**

- Create: `deploy/worker/cloud-init.yml`
- Create: `deploy/worker/wali-media-worker.service`
- Create: `deploy/worker/worker.env.example`
- Create: `deploy/worker/firewall.md`
- Create: `deploy/worker/deploy.sh`
- Create: `deploy/worker/verify.sh`
- Create: `docs/runbooks/worker-rebuild.md`
- Create: `docs/runbooks/worker-compromise.md`

**Steps:**

1. Provision a dedicated minimal Linux VM with automatic security updates,
   encrypted disk, SSH keys only, no password/root login, no inbound application
   port, and outbound allowlisting where the provider supports it.
2. Install rootless Podman and run the Go service as a dedicated user. Never
   mount a Docker/Podman daemon socket into a workload.
3. Store environment-scoped secrets outside the repo with permissions limited
   to the service account. Prefer short-lived/scoped credentials; rotate the
   bootstrap credential after first successful staging run.
4. Pull OCI images by digest, verify signatures/SBOM/allowlist, and keep only
   current plus rollback images.
5. `verify.sh` proves service user, firewall, no listener, rootless runtime,
   container limits, networkless decode, secret invisibility, queue health, and
   scratch cleanup.
6. Process a generated staging upload end to end. Destroy and rebuild the VM
   from docs, then prove expired lease recovery completes the job exactly once.

## Phase 3 — macOS marketplace

### Task 14: Add the shared catalog contract and signature verifier

**Files:**

- Create: `Packages/WALICore/Sources/WALICatalog/CatalogIdentifiers.swift`
- Create: `Packages/WALICore/Sources/WALICatalog/CatalogManifest.swift`
- Create: `Packages/WALICore/Sources/WALICatalog/CanonicalJSON.swift`
- Create: `Packages/WALICore/Sources/WALICatalog/ManifestVerifier.swift`
- Create: `Packages/WALICore/Sources/WALICatalog/RevocationList.swift`
- Create: `Packages/WALICore/Tests/WALICatalogTests/ManifestVerifierTests.swift`
- Create: `Packages/WALICore/Tests/WALICatalogTests/CanonicalJSONTests.swift`
- Modify: `Packages/WALICore/Package.swift`
- Modify: `docs/architecture/modules.yml`

**Steps:**

1. Add a static `WALICatalog` package product depending on `WALIModel` and
   importing only Foundation/CryptoKit plus the standard library. It has no
   network, UI, AppKit, AVFoundation, SQLite, Storage, or Supabase dependency.
2. Model bounded catalog/release/artifact/key/revocation values with explicit
   schema epoch/revision and validated IDs, sizes, counts, URLs, MIME types, and
   SHA-256.
3. Decode JSON with duplicate-key rejection and canonicalize exact bytes. Do not
   rely on general JSON object re-serialization that loses duplicate/order facts.
4. Verify Ed25519 signature, trusted key validity/chain, approved CDN host,
   artifact relationship, metadata digest, and revocation state.
5. Use the valid/invalid fixtures from Task 2. Add tamper, wrong key, expired key,
   unsupported epoch, duplicate key, oversized field/count, redirect host, and
   signature-replay tests.
6. Run:

   ```bash
   swift test --package-path Packages/WALICore --filter WALICatalogTests
   make check-architecture
   ```

### Task 15: Add the foreground Supabase catalog/auth adapter

**Files:**

- Create: `Sources/WALICatalogRuntime/CatalogGateway.swift`
- Create: `Sources/WALICatalogRuntime/SupabaseCatalogGateway.swift`
- Create: `Sources/WALICatalogRuntime/CatalogDTOs.swift`
- Create: `Sources/WALICatalogRuntime/CatalogMapper.swift`
- Create: `Sources/WALICatalogRuntime/AuthSessionStore.swift`
- Create: `Sources/WALICatalogRuntime/AppleSignInCoordinator.swift`
- Create: `Sources/WALICatalogRuntime/CatalogDownloader.swift`
- Create: `Sources/WALICatalogRuntime/CatalogCache.swift`
- Create: `Sources/WALICatalogRuntime/CatalogEnvironment.swift`
- Create: `Tests/WALICatalogRuntimeTests/CatalogMapperTests.swift`
- Create: `Tests/WALICatalogRuntimeTests/ManifestDownloadTests.swift`
- Modify: `project.yml`
- Modify: `docs/architecture/modules.yml`

**Steps:**

1. Pin one reviewed exact Supabase Swift SDK release in `project.yml`; no runtime
   dependency floats by branch or open range.
2. Define a product-shaped `CatalogGateway` for home, browse, search, detail,
   creator, favorites, saves, upload commands, moderation commands, and install
   request. Provide the real adapter and one deterministic fake; avoid generic
   repository/CRUD protocols.
3. Use native Sign in with Apple and Supabase sessions. Keep tokens in Keychain,
   refresh through the SDK, clear them on logout/deletion, and redact them from
   logs/errors.
4. Decode public DTOs with strict required fields, conservative unknown-enum
   handling, capped pages, and cursor preservation. Map into presentation/domain
   values without exposing Supabase types above the adapter.
5. Cache only public catalog responses and verified posters/manifests. Private
   creator/moderator/account data is memory-bound or encrypted as explicitly
   designed, never placed in shared defaults.
6. Download to an opaque WALI-owned quarantine file with create-exclusive,
   maximum length, expected Content-Length, streaming SHA-256, redirect-host
   policy, cancellation, and cleanup. Never use title/original filename as path.
7. Inject URL/session/clock/storage in focused tests. Prove token redaction,
   cross-host redirect rejection, partial/oversized/digest mismatch cleanup,
   cancellation, and verified success.
8. Run the target tests plus `make check-architecture`.

### Task 16: Build Discover, Browse, search, detail data, and account state

**Files:**

- Create: `Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/DiscoverView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/BrowseView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/CatalogSearchView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/CatalogCardView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/CatalogFiltersView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/AccountView.swift`
- Create: `Sources/WALIUI/CatalogPresentationModels.swift`
- Modify: `Sources/WALIAppRuntime/WALIConnectedAppRootView.swift`
- Modify: `Sources/WALIAppRuntime/WallpaperDetailView.swift`
- Modify: `Sources/WALIAppRuntime/VideoPreview.swift`
- Modify: `DESIGN.md`
- Create: `Tests/WALIAppTests/MarketplaceCoordinatorTests.swift`

**Steps:**

1. Replace placeholder/local-only navigation with Discover, Browse, Creator
   Studio, Review Queue when authorized, Library, and Account while preserving
   the existing native sidebar/window language.
2. Bind rows to backend collections/rank snapshots through the coordinator.
   Implement cancellation, stale-response generation checks, cursor loading,
   offline/empty/error states, and cached poster fallback.
3. Reuse the full-bleed wallpaper detail work: video fills the window, bottom
   gradient protects title/creator/license/actions, and related wallpapers
   continue below. Never blur/upscale a low-resolution poster as the active
   preview when a safe preview video is available.
4. Show title, creator, description, rights holder, attribution, license link,
   dimensions/duration/codec, verified installs, saves, categories/tags,
   related items, favorite, install, report, and share-link copy.
5. Use actual API values; no invented “live users” metric. Auth-required actions
   present a native sign-in sheet and resume the intended action once.
6. Add VoiceOver labels, keyboard navigation, Reduce Motion behavior, text
   scaling, high-contrast checks, and no information conveyed only by color.
7. Test coordinator stale/cancel/offline/auth-resume behavior, not view pixels.
8. Live-check large/small windows, low bandwidth, missing preview, reduced
   motion, unauthenticated/authenticated accounts, and all three displays.

### Task 17: Build Creator Studio and moderation queue

**Files:**

- Create: `Sources/WALIAppRuntime/Marketplace/CreatorStudioView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/CreatorSubmissionEditor.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/UploadCoordinator.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/RightsDeclarationView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/ProcessingStatusView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/ReviewQueueView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/SubmissionReviewView.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/ReportQueueView.swift`
- Modify: `Sources/WALIAppRuntime/SecondarySurfaces.swift`
- Create: `Tests/WALIAppTests/UploadCoordinatorTests.swift`
- Create: `Tests/WALIAppTests/ModerationAuthorizationTests.swift`

**Steps:**

1. Turn Create into Creator Studio; keep local file import in Library only.
2. Collect exactly the creator-supplied fields from the design. Validate for
   usability locally, then accept the server as authority.
3. Use security-scoped file access only long enough to stream a resumable TUS
   upload. Preserve source media; support pause/retry/cancel; never copy it into
   a public-name path.
4. Display server-observed bytes/media facts, system category/tag suggestions,
   and safe processing error codes. Creator input and model suggestions remain
   visually/provenance-distinct.
5. Require an explicit rights attestation and current Creator Terms acceptance
   before submission. Conditional source/attribution/proof fields follow the
   selected license policy.
6. Review Queue is absent unless the current server grant and AAL2 session allow
   it. Every action shows the target generation/revision, requires a structured
   reason where needed, and handles stale decisions without overwriting.
7. Moderators preview only canonical artifacts. The app never streams the raw
   upload or proof file through the wallpaper player.
8. Test resumable-offset recovery, file-access revocation, cancellation,
   generation mismatch, auth expiry, rights requirements, role removal, and
   AAL2 enforcement.

### Task 18: Install signed catalog releases through the agent

**Files:**

- Modify: `Packages/WALICore/Sources/WALIModel/Assets/LibraryItem.swift`
- Modify: `Packages/WALICore/Sources/WALIWire/AgentProtocol.swift`
- Modify: `Packages/WALICore/Sources/WALIWire/AgentXPCProtocol.swift`
- Modify: `Sources/WALIAppRuntime/WALIAppCoordinator.swift`
- Modify: `Sources/WALIAppRuntime/IPC/AgentConnection.swift`
- Create: `Sources/WALIAgentRuntime/Catalog/CatalogInstallCoordinator.swift`
- Create: `Sources/WALIAgentRuntime/Catalog/CatalogTrustStore.swift`
- Create: `Sources/WALIAgentRuntime/Catalog/CatalogRevocationStore.swift`
- Modify: `Sources/WALIAgentRuntime/IPC/AgentCommandRouter.swift`
- Modify: `Sources/WALIAgentRuntime/Storage/LibraryRecordFactory.swift`
- Modify: `Sources/WALIAgentRuntime/Storage/ContentStorage.swift`
- Modify: `Sources/WALIAgentRuntime/Storage/RuntimeStore.swift`
- Create: `Tests/WALIAgentTests/CatalogInstallTests.swift`
- Create: `Tests/WALIAgentTests/CatalogRevocationTests.swift`
- Create: `Tests/WALIAppTests/CatalogInstallFlowTests.swift`

**Steps:**

1. Add a versioned catalog origin to the closed `LibraryItemOrigin` model and a
   migration preserving local-import/bundled decoding. Record remote wallpaper,
   release, edition, creator/attribution snapshot, and manifest digest without
   introducing mutable network references as local authority.
2. Add bounded install wire messages carrying canonical manifest bytes,
   signature, key ID, idempotency/revision, and WALI-owned quarantine reference.
   Never carry arbitrary destination paths or an authenticated URL to the agent.
3. Authenticate the app peer, independently verify the manifest/signature/key/
   revocation in the agent, and ask `WALITranscoder` to inspect the downloaded
   canonical artifact before trust.
4. Feed the result into ADR 0005's existing agent-owned fresh destination,
   destination-byte SHA-256/media validation, no-replace publication, fsync,
   journal, SQLite commit, lease, and recovery path. Worker/app claims are not
   trust facts.
5. Make the command idempotent. A digest already installed is reused only after
   independent validation; a stale manifest/release does not retarget an
   existing library item silently.
6. Implement signed critical-security revocation for catalog-origin releases.
   Delisted/copyright-removed content stops new installs but is not remotely
   deleted from a user's library.
7. Prove tamper, wrong key, revoked key/release, redirect substitution, digest/
   length/media mismatch, symlink/FIFO/sparse file, stale command, process crash
   at each journal stage, duplicate install, and offline playback behavior.
8. Run focused package/app/agent tests, then `make verify`.

## Phase 4 — Full Disk Access privilege split

### Task 19: Add the narrow Lock Screen helper product

**Files:**

- Create: `Sources/WALILockScreenHelper/main.swift`
- Create: `Sources/WALILockScreenHelperRuntime/LockScreenHelperService.swift`
- Create: `Sources/WALILockScreenHelperRuntime/LockScreenOperationRouter.swift`
- Create: `Sources/WALILockScreenHelperRuntime/AuthenticatedPeer.swift`
- Create: `Sources/WALILockScreenHelperRuntime/FixedWallpaperStore.swift`
- Create: `Config/WALILockScreenHelper.entitlements`
- Create: `Config/Generated/WALILockScreenHelper-Info.plist`
- Modify: `Packages/WALICore/Sources/WALIWire/AgentXPCProtocol.swift`
- Modify: `project.yml`
- Modify: `Config/Base.xcconfig`
- Modify: `scripts/generate-info-plists.sh`
- Modify: `scripts/verify-bundle.sh`
- Modify: `docs/architecture/modules.yml`
- Create: `Tests/WALILockScreenHelperTests/LockScreenHelperTests.swift`

**Steps:**

1. Add an embedded `LSUIElement` helper with a stable bundle ID and named XPC
   service. It is the only product whose user-facing instructions request Full
   Disk Access.
2. Give it only required App Group/keychain/XPC entitlements. Do not add network,
   user-selected file, Downloads/Documents, automation, Accessibility, screen
   recording, JIT, or temporary exception entitlements.
3. Define only `status`, `activateVerifiedRelease`, `deactivate`, and `restore`
   wire operations. Resolve fixed store/source roots internally from bounded
   release IDs/digests. Reject path strings, URLs, data blobs, commands, and
   unknown operations.
4. Authenticate the caller's designated code requirement and exact protocol
   version before decoding an operation.
5. Move or reimplement only the Apple-store validator/journal/atomic replacement
   needed by the helper. Preserve ADRs 0008–0010 build/schema/ownership/rollback/
   session-lock limits.
6. Add static policy checks that fail if this target links/imports AVFoundation,
   VideoToolbox, WebKit, JavaScriptCore, Network, shell/Process, plugin loading,
   SQLite, or a general scripting runtime.
7. Update bundle verification to require exactly the documented nested app/XPC
   graph and entitlements, rather than the old one-helper assumption.
8. Test only against injected temporary store roots and sanitized fixtures.
   Never use the live Apple store in automated tests.

### Task 20: Remove Full Disk Access from the agent path and migrate continuity

**Files:**

- Create: `Sources/WALIAgentRuntime/LockScreen/LockScreenHelperConnection.swift`
- Modify: `Sources/WALIAgentRuntime/LockScreen/LockScreenContinuityCoordinator.swift`
- Modify: `Sources/WALIAgentRuntime/LockScreen/LockScreenStoreMonitor.swift`
- Modify: `Sources/WALIAgentRuntime/WALIAgentController.swift`
- Modify: `Sources/WALIAppRuntime/WALISettingsView.swift`
- Modify: `Config/WALIAgent.entitlements`
- Modify: `SECURITY.md`
- Modify: `DESIGN.md`
- Modify: `Tests/WALIAgentTests/WALIAgentTests.swift`
- Create: `Tests/WALIAgentTests/LockScreenHelperConnectionTests.swift`

**Steps:**

1. Replace direct Apple-store mutation in `WALIAgent` with the authenticated
   helper connection. The agent supplies a verified local release identity;
   the helper owns fixed-root mutation and rollback.
2. Ensure the agent works fully without Full Disk Access. The normal desktop
   renderer, library, imports, catalog, multi-display assignments, scaling, and
   pause behavior must not depend on helper availability.
3. Update Settings to show separate helper permission status, open the exact
   System Settings pane, and explain authenticated-session/FileVault limits.
4. Keep continuity disabled/fail-closed when helper identity, build allowlist,
   store schema, WALI ownership, or source digest validation fails.
5. Run an App Sandbox feasibility spike for `WALIAgent`. If global wallpaper
   windows work, enable it and document entitlements. If not, retain Hardened
   Runtime without FDA and record the evidence/decision in ADR 0013 before
   proceeding.
6. Tests prove malformed/unauthenticated XPC cannot read/write; disconnected or
   crashed helper only creates a warning; exact rollback survives restart; no
   agent process can open the protected Apple store without the user grant.
7. Build signed Development bundles and live-check on the verified macOS build:
   first and repeated lock, unlock resume, permission removal, helper crash,
   unsupported build, three-display topology, and rollback. Record evidence;
   never automate the live store.
8. Run `make verify`, signed `make development`, and `verify-bundle` for both
   Development and Release configurations.

## Phase 5 — OSS, operations, and launch

### Task 21: Add legal/support surfaces and complete OSS provenance

**Files:**

- Create: `docs/legal/privacy-policy.md`
- Create: `docs/legal/terms-of-service.md`
- Create: `docs/legal/creator-content-license.md`
- Create: `docs/legal/content-guidelines.md`
- Create: `docs/legal/copyright-policy.md`
- Create: `docs/legal/account-deletion.md`
- Create: `docs/legal/README.md`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `sbom/.gitkeep`
- Create: `scripts/check-licenses.sh`
- Create: `scripts/generate-sbom.sh`
- Create: `docs/content/seed-catalog.yml`
- Modify: `NOTICE`
- Modify: `CONTRIBUTING.md`
- Modify: `SECURITY.md`
- Modify: `Sources/WALIAppRuntime/Marketplace/AccountView.swift`
- Modify: `Sources/WALIAppRuntime/WallpaperDetailView.swift`

**Steps:**

1. Draft the required public documents and have counsel review before enabling
   public UGC. Configure a minimal static GitHub Pages or equivalent publication
   for these documents only; do not build a second marketplace UI.
2. Link privacy, terms, creator license, copyright, account deletion, security,
   and support from the native app.
3. Require Creator Terms acceptance and store document versions before upload.
   Show exact license/attribution on every detail page and exported share record.
4. Generate SPDX SBOMs for Swift, Deno, Go, Python, OCI images, FFmpeg, and model
   artifacts. Compare to the dependency allowlist and fail unclear/incompatible
   licenses.
5. Create a seed-catalog provenance manifest. Each wallpaper needs source,
   rights holder, redistribution grant/license, attribution, artifact digests,
   reviewer, and date. An empty catalog is preferable to unlicensed media.
6. Ensure no Backdrop/Wallsflow assets/endpoints/cookies/manifests/credentials/
   branding or proprietary wallpaper remains in fixtures, seed, docs, or history
   added by this sprint.
7. Run license, secret, generated-file, and repository-wide provenance checks.

### Task 22: Add backup, restore, key rotation, moderation, and incident runbooks

**Files:**

- Create: `Services/WALIMediaWorker/internal/maintenance/backup.go`
- Create: `Services/WALIMediaWorker/internal/maintenance/reconcile.go`
- Create: `docs/runbooks/backup-and-restore.md`
- Create: `docs/runbooks/signing-key-rotation.md`
- Create: `docs/runbooks/signing-key-compromise.md`
- Create: `docs/runbooks/malicious-release.md`
- Create: `docs/runbooks/rls-data-exposure.md`
- Create: `docs/runbooks/copyright-takedown.md`
- Create: `docs/runbooks/account-deletion.md`
- Create: `docs/runbooks/ranking-abuse.md`
- Create: `docs/runbooks/catalog-rollback.md`
- Create: `scripts/verify-restore.sh`

**Steps:**

1. Configure paid Supabase PITR for production and documented scheduled backups
   for staging. Export version-controlled schema/config independently.
2. Implement provider-neutral object mirroring from immutable catalog/private
   retained objects to a separately credentialed S3-compatible or GCS cold
   backup. The backup target is not an application dependency.
3. Verify source/destination digest and reference coverage; record a signed/
   auditable report. Alert on missing, corrupt, or unbacked published objects.
4. Restore into an isolated project/bucket and prove catalog/release/artifact
   referential integrity. Do not call a copy job a backup without restore proof.
5. Exercise signing-key rotation and surviving-trust-chain verification. Keep
   private key access separate from worker/database backups.
6. Walk through malicious release, RLS exposure, worker compromise, copyright
   notice/counter-notice, ranking abuse, account deletion, and catalog rollback
   using synthetic staging data. Record owner, trigger, commands, evidence,
   communication, and exit criteria.

### Task 23: Add CI gates, performance evidence, staging canary, and release proof

**Files:**

- Create: `.github/workflows/marketplace-ci.yml`
- Create: `.github/workflows/container-build.yml`
- Create: `.github/workflows/security-scan.yml`
- Create: `.github/dependabot.yml` or equivalent approved updater config
- Create: `scripts/test-catalog-load.sh`
- Create: `scripts/verify-worker-isolation.sh`
- Create: `docs/release/marketplace-public-beta-checklist.md`
- Create: `docs/release/marketplace-public-beta-evidence.md`
- Modify: `scripts/verify.sh`
- Modify: `Makefile`
- Modify: `README.md`

**Steps:**

1. SHA-pin all Actions and isolate untrusted fork jobs from secrets. Separate
   build/test from credentialed staging deploy. Prefer OIDC/short-lived deploy
   credentials.
2. CI runs architecture/contract checks, Swift build/tests, Supabase reset/
   pgTAP, Deno format/lint/tests, Go vet/race tests, classifier contract tests,
   hostile corpus, SBOM/license/secret scans, OCI vulnerability scan, and
   `git diff --check`.
3. Build/sign OCI images and record immutable digests. Production configuration
   consumes digests, never mutable tags.
4. Load-test catalog home/search/detail, upload-session issuance, queue
   backpressure, and ranking aggregation with synthetic data. Record hardware,
   dataset size, concurrency, duration, median, p95, error rate, and bottleneck.
5. Run a staging canary through account, upload, process, review, publish,
   manifest verify, install, offline playback, report, delist, and critical
   revocation. Verify monitoring produces actionable, privacy-safe events.
6. Run the existing WALI performance and live multi-display checks so marketplace
   work does not regress idle CPU/memory, playback, scaling, agent persistence,
   or Lock Screen behavior.
7. Build a Release archive, verify Hardened Runtime/entitlements/nested code,
   notarize, staple, and run `spctl`/`codesign` validation on the exact artifact.
8. Fill the public-beta evidence document with command output, environment,
   object/manifest/key IDs, restore evidence, known risks, and rollback point.
9. Do not enable public creator uploads until Gates A–E in the design document
   are all satisfied.

## Final verification sequence

Run from a clean authorized integration worktree:

```bash
make clean
make verify
make marketplace-verify
supabase db reset
supabase test db
deno fmt --check supabase/functions
deno lint supabase/functions
cd Services/WALIMediaWorker && go vet ./... && go test -race ./...
cd ../WALIClassifier && uv run pytest
cd ../..
./Services/WALIMediaSandbox/tests/run-corpus.sh
./scripts/check-licenses.sh
./scripts/generate-sbom.sh --verify-clean
./scripts/verify-worker-isolation.sh
./scripts/test-catalog-load.sh --environment staging
git diff --check
```

Expected: every command passes; the working tree changes only where a documented
generator intentionally refreshes checked-in evidence/SBOM files.

Then perform the signed/manual gates:

1. Sign in, upload, review, publish, browse, search, install, play offline,
   favorite/save, report, delist, and critical-revoke a generated staging item.
2. On the verified macOS build, exercise all displays, Fill/Center, pause/resume,
   close/reopen foreground app, restart agent, repeated Lock Screen, permission
   removal, and exact rollback.
3. Restore production-shaped synthetic DB/object backups into isolation and
   verify every published manifest/digest.
4. Rotate a staging signing key and verify old/current clients follow the trust
   transition; exercise compromise freeze/rollback.
5. Have product owner, security owner, moderation operator, and legal reviewer
   explicitly sign the public-beta checklist.

## Publication checkpoint

Only after explicit repository-owner authorization:

```bash
git add --all
git commit -m "feat: add secure wallpaper marketplace foundation"
```

Use `tess ship <feature>` for the owned integration feature, wait for CI, review
the final diff and generated artifacts, then merge through the repository's
normal protected path. Never bypass a red gate to meet the sprint boundary.
