# Marketplace Defaults and Creator Terms Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Deliver a visible, versioned Creator Terms acceptance flow that reliably unlocks Creator Studio, and populate the private staging catalog from the supplied wallpaper folder without misrepresenting ownership or bypassing WALI's security pipeline.

**Architecture:** Keep terms content as a version-matched native presentation model in `WALIAppRuntime`; the server remains authoritative for the current version and acceptance record. Diagnose and repair only the failing async boundary in the existing `creator-command` flow. Build a deterministic staging manifest from local media, then send eligible fixtures through the existing creator upload, isolated media worker, moderation, publication, signed catalog, and client verification path.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Supabase Auth/Postgres/Storage/Edge Functions, Deno tests, Go media worker, ffprobe/sha256, `tess` worktrees.

## Outcome

- Creator Terms review, explicit consent, bounded retry behavior, authenticated-subject binding, and revoked-role protection are implemented and covered across Swift, Edge Function, and database tests.
- All 24 supplied videos were processed outside Git by the isolated media image into 24 verified private candidates and 96 digest-verified silent artifacts with zero failures.
- The supplied media remains `third_party_unverified`, `publication_allowed=false`, and was not uploaded to Supabase or exposed by catalog RPCs.
- Staging import and publication are blocked until redistribution rights are documented. Production consent is additionally blocked until the draft Creator Terms are replaced by counsel-approved immutable content bound by version and digest.

---

### Task 1: Prove the acceptance failure boundary

**Files:**
- Inspect: `Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift`
- Inspect: `Sources/WALICatalogRuntime/SupabaseCatalogGateway.swift`
- Inspect: `supabase/functions/creator-command/index.ts`
- Inspect: `supabase/migrations/202609010012_edge_commands.sql`
- Update evidence: `findings.md`

**Steps:**

1. Query recent staging `terms_acceptances`, `command_idempotency`, `role_grants`, and `audit_events` without printing secrets.
2. Compare record timestamps with the failed UI attempt to determine whether the Edge command committed.
3. Exercise the relevant read RPCs with bounded timeouts and inspect safe error codes.
4. Record whether the stall is command invocation, authorization refresh, or metadata refresh.
5. Do not commit; owner authorization is required.

### Task 2: Specify native terms review and reliable state transitions

**Files:**
- Create: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorTermsDocument.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorTermsReviewView.swift`
- Modify: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorStudioView.swift`
- Test: `Tests/WALIAppTests/CreatorTermsDocumentTests.swift`
- Test: `Tests/WALIAppTests/MarketplaceCoordinatorTests.swift`

**Steps:**

1. Add a failing test proving only a bundled document whose version exactly matches the server-advertised version can be accepted.
2. Add a failing coordinator test proving success exits `.acceptingTerms` and enables Creator Studio.
3. Add a failing coordinator test proving a timeout or safe remote failure exits loading and exposes retry.
4. Run the focused tests and confirm the expected failures.
5. Do not commit; owner authorization is required.

### Task 3: Implement terms review and the root-cause fix

**Files:**
- Create: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorTermsDocument.swift`
- Create: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorTermsReviewView.swift`
- Modify: `Sources/WALIAppRuntime/Marketplace/Creator/CreatorStudioView.swift`
- Modify only if evidence requires: `Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift`
- Modify only if evidence requires: `Sources/WALICatalogRuntime/SupabaseCatalogGateway.swift`

**Steps:**

1. Present the exact supported Creator Content License in a native scrollable sheet before network mutation.
2. Show the document version and require an explicit consent checkbox.
3. Disable acceptance for an unsupported server version and direct the user to update WALI.
4. On acceptance, dismiss only after the server confirms the same version; preserve a retryable error on failure.
5. Apply the smallest evidence-backed timeout/state fix at the failing boundary.
6. Run the focused tests and confirm they pass.
7. Do not commit; owner authorization is required.

### Task 4: Validate and describe the supplied staging media

**Files:**
- Source input: `/Users/pratham/Desktop/down/*.mp4`
- Create: `docs/content/staging-catalog.local.example.yml` only if a reusable redacted format is needed
- Create outside Git: a generated staging ingestion manifest containing filenames, hashes, dimensions, duration, codec, and provenance

**Steps:**

1. Run `ffprobe` and SHA-256 over all 24 files with bounded execution.
2. Reject files outside `media-policy.yml` before upload.
3. Derive human-readable draft titles without deleting the original source name.
4. Mark the source as third-party/unverified and never assert WALI ownership.
5. Confirm the manifest count and digest are deterministic.
6. Do not commit media files or credentials.

### Task 5: Import eligible fixtures into private staging

**Files:**
- Reuse: `supabase/functions/create-upload/index.ts`
- Reuse: `supabase/functions/complete-upload/index.ts`
- Reuse: `supabase/functions/submit-wallpaper/index.ts`
- Reuse: `supabase/functions/moderate-submission/index.ts`
- Reuse: `supabase/functions/publish-release/index.ts`
- Modify/create an operator script only if the existing interfaces cannot batch the normal path.

**Steps:**

1. Verify the staging service identity and worker health without touching the production project.
2. Create staging submissions with truthful provenance and rights state.
3. Upload via opaque resumable grants; do not write raw objects directly into the public bucket.
4. Wait for isolated processing and verify canonical silent video/poster/preview artifacts.
5. Keep unverified-rights entries private; publish only fixtures that the staging policy explicitly permits.
6. Verify any published staging release is signed and returned by catalog RPCs.
7. Do not commit or promote production configuration.

### Task 6: Verify the full staging experience

**Files:**
- Update: `progress.md`
- Update: `findings.md`

**Steps:**

1. Run `make check-architecture`.
2. Run focused `WALIAppTests` and `WALICatalogRuntimeTests` sequentially.
3. Run targeted Edge Function and database contract tests.
4. Build WALI with staging configuration and launch the app plus helper.
5. Confirm Creator Terms are readable, acceptance terminates, Creator Studio unlocks, and retry works.
6. Confirm marketplace cards/details load only verified published staging fixtures.
7. Report exact imported/published/rejected counts and any rights blocker; do not claim production readiness from staging evidence.
8. Do not commit, push, or deploy production changes without explicit owner authorization.
