# Marketplace readiness for the Mac App Store

Status: proposed remediation plan, 2026-09-09. Implementation and release work
are authorized, but this document does not approve schema, security, identity,
retention, IPC, or distribution changes. It prepares concrete decisions and
work packages from the [initial review](../release/app-store-review-2026-09-09.md).
Source baseline: `6723f24a706931a4177c480bed0ee7914f2efb21`.

The owner must record architecture approval through the process in
`GOVERNANCE.md` and `docs/adr/README.md` before affected implementation. Accepted
ADRs 0011, 0012, 0013, 0014 and 0016 remain authoritative. Amend policy through
new proposed ADRs with explicit supersession scopes; do not rewrite accepted
history. The metadata/privacy handoff is
[app-store-metadata-draft.md](../release/app-store-metadata-draft.md).

## Minimum owner decisions

These are the missing decisions and real-world facts. Routine implementation
details can proceed within the approved outcome; no separate permission is
needed for each test or reversible document correction.

| ID | Decision / input needed | Concrete proposed direction | Why it is needed |
| --- | --- | --- | --- |
| D1 | First Store product scope: local wallpaper core only, or core plus working marketplace/Creator Studio; whether moderator UI belongs in the Store app | Approve an explicit Store feature matrix alongside the separate sandbox/distribution ADR. Include marketplace only when this plan's release gates pass | Determines binary graph, visible routes, review access, disclosures and copy; cannot silently infer permission to remove features |
| D2 | Actual legal operator/rights-holder name, public legal/support host, private support/privacy/security/copyright intake, approved document versions and relevant jurisdictions | One stable public legal base with six compatible document paths and a distinct support destination; private intake for personal data and security matters | Existing policies are drafts; public privacy URL returned 404. Repository organization names and generated addresses are not legal facts |
| D3 | Allowed content and creator eligibility, including whether any mature material is permitted | Prefer a clearly bounded approved-content policy with a consistent default ceiling; determine actual App Store age rating using Apple's questionnaire | Current home/search requests permit mature content; internal ratings do not identify an App Store rating or establish age verification |
| D4 | Deletion/retention outcome: removable public UGC and attribution, legally required holds, real completion timeframe/channel; approval of proportional reauthentication and Apple authorization handling | Fulfill deletion independently of revocation retries; remove public access to affected UGC, then purge eligible copies under an approved retention/backup process. Prefer fresh Apple reauthentication for Apple-only accounts where the approved security model permits it | Existing immutable-release/retention policy and TOTP rule cannot be silently changed; “licensed to retain” and “legally required to retain” need reconciliation |
| D5 | Review access and sample rights, assigned operational responders, intended countries and Store price | Rights-cleared sample plus a documented Apple-only review path; give role access only where the submitted feature needs it | No demo mode, reviewer credentials, moderation staffing, price, territory, or distribution rights are established by source |

Encryption answers require a technical assessment of the final archive and an
owner-approved determination, not a guessed exemption. App Store Connect legal
agreements and identity are separate from GitHub signing/notarization.

## Work packages and acceptance

### M1. Effective policies, public links and content acceptance

Invariant: people and reviewers can read the effective rules and reach the
operator; every creator acceptance refers to the same approved document shown
to that creator.

Seams: `Config/Base.xcconfig` / environment-specific public configuration,
`project.yml` (`WALILegalBaseURL`),
`Sources/WALIAppRuntime/Marketplace/AccountView.swift` (`MarketplaceLegalLinks`),
`Creator/CreatorTermsDocument.swift`, `CreatorTermsReviewView.swift`,
`supabase/migrations/202609010015_creator_terms_subject_binding.sql`, legal
document/runtime configuration operations, and `docs/legal/`.

After D2, publish approved documents; add a real support destination and safe
failure presentation for unavailable links. Pin accepted content/version (and
digest where required by the approved contract), update native rendering and
server current-version checks together. A legal-document change must not cause
old accepted bytes to be rewritten. Existing source policies are not proof of
counsel approval or production activation.

Acceptance: anonymous HTTPS checks for every exact destination; native link
opening; displayed-document versus accepted-document identity; unsupported
version refusal; stale subject/session rejection; reacceptance when necessary;
private intake test using non-sensitive synthetic content. Update source
policy, native document and deployed version evidence consistently.

### M2. Persistent creator blocking across the client and service

Invariant: an account's block choice prevents ordinary discovery and new
marketplace interactions with that creator on every device without revealing
the blocking relationship to the blocked person. Reporting remains available.
No block path may mutate another person's preferences or grant moderation
authority. This privacy/schema/API addition requires an approved ADR.

Current gap: detail has Report but no Block action; reports can be closed,
hidden or delisted by moderators. No end-user blocking relation, command or
filter was found. Administrative suspension is a different operation.

Proposed implementation seams:

- Native presentation: `MarketplaceWallpaperDetailView.swift` for Block and
  confirmation, `AccountView.swift` for a manageable block list, and
  `Sources/WALIUI/CatalogPresentationModels.swift` for bounded state. Final UI
  names are to be chosen during implementation, not advertised now.
- Orchestration and transport: `MarketplaceCoordinator.swift`,
  `Sources/WALICatalogRuntime/CatalogGateway.swift`, `CatalogDTOs.swift`,
  `CatalogMapper.swift`, `SupabaseCatalogGateway.swift`. Add explicit versioned
  block/list/unblock operations; actor comes from authenticated session, never
  a caller-supplied owner. Preserve idempotency and current-subject checks.
- Backend: new ordered migration in `supabase/migrations/`, an RLS-private
  owner/creator relation with bounded constraints and index, reviewed public
  projection/command contracts, and service entry point only if needed by the
  accepted API design. Reuse current RPC/idempotency patterns; names here are
  proposals, not existing endpoints.
- Enforce on home, browse, search, related results, direct detail, saved/favorite
  lists, creator projections, new install grants and engagement mutations.
  Catalog public views and RPCs are in `202609010008_public_api.sql` and later
  overrides; Edge commands include `request-install` and current install RPCs.
  Follow the latest definition, not just the original migration.
- Invalidate displayed results, pagination, detail, caches and pending requests
  after block or account switch. Old public media URLs may remain public;
  blocking is personalized access/visibility, not global content revocation.
  Already-installed local wallpaper must not be deleted as a side effect.
  Preserve removal actions such as unfavorite/unsave and the ability to report;
  do not make blocking prevent a person from clearing their own saved state.

Decisions to record in the ADR: signed-out behavior; self-block rejection;
unblock restoration; cached/offline state; pre-existing favorites/saves/follows;
new install grant races; whether a privacy request can reveal a block list;
and account deletion/export of the relation. Do not weaken CDN signature or
revocation checks, and do not make authenticated personalized responses shared
public-cache entries.

Acceptance: two users/two creators plus anon/admin matrix; own-list access only;
cross-user read/write denial; self-block rejection; duplicate and retry-safe
block/unblock; every surface above including direct IDs and pagination; a stale
request cannot reinsert blocked content; account switching cannot inherit the
previous account's block state; no private block data in public projection;
deletion/export behavior; offline/local library unchanged. Extend
`Tests/WALIAppTests/MarketplaceCoordinatorTests.swift`, catalog contract tests,
`supabase/tests/database/001_identity_rls.test.sql`,
`008_public_api_exposure.test.sql`, and purpose-built command/visibility tests.

### M3. Complete account deletion and justified public-media cleanup

Invariant: deletion reaches an observable terminal outcome, removes associated
data/UGC except approved legally required records, preserves unrelated data,
and never deletes the user's original or installed local videos.

Current path: `AccountView` confirmation →
`MarketplaceCoordinator.requestAccountDeletion` →
`AccountPrivacyGateway` / `SupabaseCatalogGateway` →
`supabase/functions/request-account-deletion/index.ts` → queue →
`Services/WALIMediaWorker/internal/jobs/processor.go`
(`AccountDeletionProcessor`) and SQL store methods in `lease.go` →
`wali.worker_begin_account_deletion` / `worker_complete_account_deletion`.
The worker cleans private upload/export objects, pseudonymizes records and stops
at `awaiting_auth_cleanup`. An AAL2 operator's `finalize_identity` operation
soft-deletes/verifies Supabase identity. The native gateway polls status only.
`docs/runbooks/account-deletion.md` records missing operational completion and
notification evidence; deployment status must be refreshed by the release
owner before implementation is called missing or live.

After D4 and the policy ADR, complete these pieces:

1. Choose and implement the operator trigger/reconciliation path, bounded
   retries and escalation. Do not embed privileged credentials in the Mac app.
2. Provide an approved confirmation mechanism that still works after durable
   Auth sessions and identity are removed. Define a scoped receipt capability
   or other authenticated channel in the security design; do not expose status
   by an enumerable deletion UUID. Show a real timeframe and completion/hold
   information without requiring the person to email support to delete.
3. Define the complete artifact graph: original uploads, processing outputs,
   posters/previews/video releases, public attribution, exports, derivatives,
   CDN caches, protected evidence and backups. Existing cleanup enqueues only
   `uploads-private` and `exports-private` in the account path. An inactive
   profile disappearing from public views does not prove object deletion.
4. Reconcile immutability and revocation with removal: stop new access/grants,
   revoke/delist as approved, preserve minimum legal/audit facts, and remove
   eligible bytes with digest/reference/hold checks. Account deletion cannot
   purge an object still legitimately referenced by someone else. Final policy
   must distinguish remote copies from copies already downloaded to users.
5. Update `docs/security/data-inventory.yml`, public deletion/privacy policies,
   API contracts, compatibility inventory and operational runbook. Existing
   seven-year windows or permanent-release rules cannot become automatic new
   legal justifications.

Acceptance: disposable-account full native journey; session revocation; worker
restart and lease expiry; duplicate requests; operator idempotency and already-
deleted identity; provider timeout/partial failure; held cases and release;
all eligible private/public objects removed and unrelated/shared objects intact;
bounded backup expiry/reappearance prevention; inability to obtain new grants;
successful completion notification after identity removal; original local
library unchanged. Use `supabase/functions/tests/marketplace-functions.test.ts`,
database queue/retention and edge-security tests, worker processor tests, native
coordinator tests, and a separately recorded staging drill before production.

### M4. Apple authorization lifecycle and proportional deletion verification

Invariant: Apple authorization is handled separately from Supabase session
deletion; unavailable Apple revocation must not prevent the user's data deletion.
Fresh identity proof must bind to the current WALI account and action.

Current gaps: `AppleSignInCoordinator` returns ID token/nonce only;
`AuthSessionStore.signInWithApple` calls `signInWithIdToken`;
`request-account-deletion.softDeleteAndVerifyIdentity` only calls Supabase Auth.
No authorization-code exchange, Apple `/auth/revoke`, manual fallback guidance,
or Apple credential-state/revocation observation was found. An Apple-only user
without a factor is enrolled into TOTP by
`MarketplaceCoordinator.prepareAccountDeletionAuthorization`; this is a
proportionate-authentication decision to review, not permission to weaken all
moderator/admin AAL2 enforcement.

The ADR must choose the Apple revocation route: securely exchange a fresh
authorization code and revoke the resulting token, or use Apple's documented
manual fallback when no token/code exists. Define subject/audience/nonce,
expiry, replay prevention, token handling/erasure and a narrowly scoped server
endpoint. Private Apple signing material belongs in the approved secret store.
Do not log or add tokens to generic account exports. Observe credential
revocation and clear/reconcile local sessions. Any deletion-only alternative
to TOTP must not grant creator/moderator privileges or accept an unrelated
Apple account.

Acceptance: first Apple sign-in; hide-email account; wrong audience/subject;
nonce/code replay; expired code; Apple cancellation; token exchange/revocation
success, retry and outage; no-token manual fallback; credentials revoked outside
the app; deletion proceeds despite revocation failure; no retained tokens in
logs/exports; moderator/admin AAL1 still denied. Run a disposable staging account
through new-account deletion without prior TOTP, then verify production with
explicit release-owner coordination. Hosted provider settings are unverified:
the previous read returned 403, not evidence of misconfiguration.

Apple's deletion and fallback guidance:
[account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/),
[TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

### M5. Content policy, review access and Store integration

After D1/D3, enforce an approved content ceiling in `CatalogBrowseRequest`,
`CatalogSearchRequest`, home/browse/search/detail/related/install paths and
server policy. Current home and search allow `mature`; `user_preferences`
defaults to `teen` but the home call does not use it. An internal enum, a label,
or a client-only switch cannot establish age assurance or prevent direct-ID
access. If the approved policy prohibits mature content, prevent publication
and serving under that policy; do not invent an age-verification system for a
content category that will not ship.

Retain human prepublication review and reporting, make enforcement and appeal
intake operational, and record response responsibility. Automated classification
is not a substitute for those controls and is not mandated by this plan.
Test content-policy enforcement with crafted approved fixtures, role revocation,
direct IDs, old clients, cached responses and account switches; no real harmful
content is required. Prepare private reviewer access to all shipped role-gated
features without a backdoor and without personal Apple Account credentials.

Marketplace-specific Store dependencies belong in the separate distribution
ADR/work package: sandbox network-client entitlement in the foreground catalog
adapter; valid Apple sign-in entitlement/audience for the final bundle IDs;
distinct keychain namespace for environment/distribution where selected;
security-scoped creator-file upload and local install handoff; public production
configuration only; account-safe caches and exports in allowed containers;
removal of helper-dependent UI/lifecycle from the Store graph. The agent remains
the local install/runtime authority; do not move service-role access or the
catalog secret/signing authority into it. Confirm public privacy/support links
work through supported native URL opening.

## Execution and release evidence

1. Resolve D1–D5 and record any required accepted ADR(s). Prepare policy copy,
   contracts and tests before changing schema/runtime. The separate signed
   GitHub release remains owned by its release task.
2. Implement M1–M5 in dependency order with explicit file ownership. M2 and
   deletion work may proceed independently after their contracts are approved;
   coordinate shared gateway, coordinator, data-inventory and migration edits.
3. Run focused affected tests; then `make marketplace-contracts`,
   `make backend-test`, `make backend-lint`, `make edge-test`,
   `make worker-test`, and affected native/catalog suites as applicable.
   Backend targets operate on local Supabase. Never point fixture resets or
   synthetic seeds at hosted production.
4. Exercise signed staging journeys using only dedicated accounts and licensed
   original media. Record expected versus actual results and recovery checks.
   Historical staging evidence, fresh schema deployment, and passing unit tests
   are separate proof states.
5. Release owner performs reviewed production deployment/verification with
   explicit project selection; preserve the checkout's staging link. Capture
   schema/function/config revisions and active worker/signer/identity/policy
   evidence without recording secret values or customer rows.
6. Recheck the exact Store archive and complete the metadata packet. Record
   private App Store reviewer access, actual screenshots and all successful
   journeys. Upload and submission are separate from review approval.

| Gate | Required completion evidence | Initial status |
| --- | --- | --- |
| Decisions / ADRs | Owner choices, accepted records and exact supersession scopes | PENDING |
| Legal/support | Approved immutable documents, public HTTP success and private intake test | PENDING |
| Block creator | Server/RLS/native test matrix and two-account signed journey | Missing implementation |
| Deletion | Complete account/object/provider/notification journey and recovery drill | Parts implemented; operational proof pending |
| Apple revocation | Implemented chosen route, fallback and credential-state evidence | Missing implementation |
| Content/review access | Approved policy, consistent enforcement, rating and role walkthrough | PENDING |
| Data disclosures | Final SDK/provider inventory, policy retention verification, archive privacy assessment | Draft packet prepared |
| Store build | Approved sandbox topology, final signed archive and compatible marketplace journeys | Separate distribution work; PENDING |
| Production / submission | Exact candidate live checks, metadata completed, upload receipt and later review outcome | Release owner to record; not asserted here |

Mark a gate complete only when its evidence exists. Rollback preserves account
privacy decisions and does not resurrect blocked content, deleted identities or
removed media. Forward-only migration and deployed API compatibility follow ADR
0014; feature disablement must leave installed local wallpapers usable.
