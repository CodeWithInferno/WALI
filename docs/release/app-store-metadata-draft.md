# WALI App Store metadata and privacy draft

Status: preparation only, 2026-09-09. This packet describes inspected source at
`6723f24a706931a4177c480bed0ee7914f2efb21`; it is not a record of a submitted Store
build, deployed feature availability, legal approval, or completed user journey.
Read it with [the initial review](app-store-review-2026-09-09.md) and
[the remediation plan](../plans/marketplace-store-readiness.md). Every `PENDING`
item must be resolved before copying this packet into App Store Connect.

## Product-page copy

| Field | Draft | Basis / decision still needed |
| --- | --- | --- |
| App name | WALI | Existing product and branding; Store name availability unverified |
| Subtitle | Live wallpapers for your Mac | Describes the desktop wallpaper feature |
| Primary category | Lifestyle | Current `project.yml:55` declares `public.app-category.lifestyle`; confirm Store selection |
| Keywords | `live wallpaper,video,desktop,background,multiple displays,personalization,animation` | Draft search terms; no competitor names or unavailable features |
| Promotional text | Turn a video into your Mac's desktop wallpaper. Preview your library, choose your displays, and adjust how each wallpaper fits. | Use after the final Store build passes those journeys |
| Minimum macOS | PENDING final Store artifact; current source target is macOS 15.0 | `Config/Base.xcconfig:1`; do not substitute source target for signed-build verification |
| Version / build | PENDING selected release candidate | Source defaults are 0.1.0 / 1, but build overrides exist |
| Copyright / seller | PENDING actual rights holder and App Store Connect legal entity | Do not infer from a repository owner or GitHub organization |
| Age rating / content declarations | PENDING actual permitted catalog content and Apple's questionnaire | `everyone`, `teen`, and `mature` are internal enums, not App Store ratings |
| Price / availability | PENDING owner choice and countries | No purchase, subscription, or paywall flow found; this does not determine the app's Store price |
| Privacy / support / marketing URLs | PENDING working public destinations | Required privacy and support destinations must be resolved; marketing URL only if used |
| Encryption / content-rights declarations | PENDING final archive assessment and rights evidence | No exemption, worldwide redistribution right, or compliance answer is assumed |

### Description: local wallpaper core

> Give your Mac a moving desktop with WALI.
>
> Import a video into your wallpaper library, preview it, and apply it to the
> displays you choose. Adjust the appearance with Fill Screen, Fit to Screen,
> Stretch to Fill, or Center.
>
> Keep prepared wallpapers together in your library and pause or resume playback
> when you need to. Local wallpaper use does not require a marketplace account.
> Importing creates a prepared WALI copy and leaves your original video in place.

This is candidate copy for the proposed Store product. The current direct
distribution artifact is not a Store candidate. Do not advertise Lock Screen
continuity, FileVault startup, HDR capability, low resource usage, supported
display counts, or offline marketplace operations without the applicable
artifact and evidence. Sources: `Sources/WALIAppRuntime/WALIAppRootView.swift`
(`sidebarImportControl`, `content`, keyboard actions),
`Sources/WALIAppRuntime/WallpaperDetailView.swift` (`Appearance`, `Displays`,
`actionFooter`), and `Sources/WALIAppRuntime/WALIAppCoordinator.swift`.

### Marketplace paragraph: include only after activation and verification

> Discover creator wallpapers, browse categories, and search the catalog. Sign
> in with Apple to save favorites and install wallpapers into your local
> library. Creator Studio lets eligible creators submit their own work for
> review before publication.

Omit this entire paragraph if the submitted product excludes marketplace
features. If marketplace is included, verify every sentence on the selected
production build. Do not call creators verified, licenses cleared, content
family-safe, or review responses timely without evidence. Relevant code is
`Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift`,
`MarketplaceWallpaperDetailView.swift`, and `Creator/CreatorStudioView.swift`.

## Public destinations and legal acceptance

| Destination | Current source / observation | Release value |
| --- | --- | --- |
| Privacy | `docs/legal/privacy-policy.md`; draft, no final operator; configured GitHub URL returned 404 anonymously during the initial review | PENDING effective public HTTPS URL |
| Terms | `docs/legal/terms-of-service.md`; draft | PENDING approved version and public URL |
| Creator license | `docs/legal/creator-content-license.md`; native `CreatorTermsDocument.current` is also explicitly draft version 2026-09-01 | PENDING approved matching content/version; acceptance binding verification |
| Content guidelines | `docs/legal/content-guidelines.md`; draft | PENDING allowed-content policy, enforcement and appeal contact |
| Copyright | `docs/legal/copyright-policy.md`; designated contact/intake not configured | PENDING approved private intake and public instructions |
| Account deletion | `docs/legal/account-deletion.md`; target workflow and operational gates | PENDING actual scope, completion timeframe, exceptions and confirmation |
| Support / privacy contact | Account's “Legal & Support” section contains six document links, no support endpoint | PENDING public support page and working private channel |
| Security reports | Existing `SECURITY.md` governs sensitive reports | PENDING verified private intake; do not substitute a public issue |

`Config/Base.xcconfig:22` sets `WALI_LEGAL_BASE_URL` to
`https://github.com/TryCleanMcp/WALI/blob/main/docs/legal`.
`MarketplaceLegalLinks` in `AccountView.swift` appends the six `.md` document
names to `WALILegalBaseURL`. A future legal website must support those paths or
the adapter must change; supplying an arbitrary homepage is insufficient.
Test all destinations without GitHub, WALI, or App Store authentication.

## Privacy data inventory for the final questionnaire

This is a mapping from source behavior to candidate disclosure categories, not
preselected App Store Connect answers. Check actual app, SDK, Auth, CDN, worker,
logging, retention, and support-provider behavior. Apple's collection test
includes off-device access beyond real-time request servicing; optional
marketplace participation alone does not exempt collection from disclosure.
[Apple privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)

| Data / trigger | Source evidence and recipients | Candidate label / linkage / purpose | Verification still needed |
| --- | --- | --- | --- |
| Ordinary local videos, local filenames, display selection, assignments and playback state | Local app/agent/transcoder; `WALIAppCoordinator.swift`, local import path; ADR 0016 excludes desktop observation from ranking | Local processing; do not declare as server collection solely because stored locally | Final Store file access and network observation; keep explicit Creator Studio upload separate |
| Apple identity, account UUID, session and MFA state | `AppleSignInCoordinator.swift:26` requests name/email scopes; only ID token and nonce go through `AuthSessionStore.signInWithApple`; Supabase Auth handles sessions | User ID and Email Address; linked; App Functionality. Name only where actually supplied/retained | Apple provider/audience, returned claims and provider retention; do not claim Apple full-name persistence because a scope is requested |
| Public handle, display name, optional avatar; creator bio and website | `202609010002_identity_and_roles.sql:3,38`; public projection vs account/admin roles | User ID, Name where identifying, Photos or Videos for uploaded avatar, Other User Content; linked; App Functionality | Final profile editing availability and public fields; distinguish schema capability from active user collection |
| Submitted source video, original upload filename, submission title/description and metadata | Creator upload coordinator/resumable transport; private Storage, Supabase and worker; `202609010005_creator_processing.sql`; Account disclosure at `AccountView.swift:120` | Photos or Videos, Other User Content; linked to creator; App Functionality | Source may include audio before canonicalization; assess Audio Data disclosure for uploaded sound, even though published video is silent; verify enabled processing providers |
| License, rights holder, attribution, source URL and terms acceptance | Catalog/submission migrations; `CreatorSubmissionEditor.swift`; `terms_acceptances` stores document/version/time/request ID | Other User Content and relevant identifying/contact data; linked; App Functionality | Rights-proof upload remains deferred; do not imply proof documents are currently collected. Approve legal purpose/retention and publication fields |
| Favorites, saves and install events/receipts | `202609010007_engagement_and_ranking.sql:3,13,34,48`; bounded RPCs; user UUID linked before aggregation | Product Interaction, User ID; App Functionality; assess Analytics/Product Personalization against active ranking | Verify actual emitted event kinds and jobs; stored follows/interest-profile capability is not proof that every corresponding UI/algorithm is active |
| Locale, content preference and personalization choice | `user_preferences`, same identity migration:66; private account data | Other Data Types / Product Interaction as appropriate; linked; App Functionality and any active Product Personalization | Native opt-out/content controls and their effective server enforcement; do not advertise a switch solely because a schema column exists |
| Search text | `CatalogSearchRequest`; `catalog_search_v1` processes bounded queries | Search History only if retained beyond servicing the request; linkage/purpose depend on logging | No persisted search-history collection established by this audit; inspect provider/request logs without exposing customer queries |
| Reports, details, reporter UUID, moderation decisions/notes | `202609010006_moderation_and_reports.sql:61`; `report-wallpaper`, `resolve-report`; reporter-safe status and moderator/admin access | Other User Content, User ID; Customer Support where applicable; linked; App Functionality | Real triage staff/channel, retention and deletion exceptions; never expose private notes/reporters in public projections |
| Copyright notice name/email/address and attachments | `copyright_cases` schema:81; public intake is not operationally established | Contact Info and Customer Support / Other User Content when intake is enabled; linked; App Functionality / other justified purpose | Approved intake, processor, legal retention and disclosure; fields in a table are not proof of live collection |
| Requests, audit/security facts, processing errors and timings | `audit_events`, processing attempts, rate limits; OSLog locally; safe Edge responses | Other Diagnostic Data, Product Interaction or Other Data Types according to actual retained payload; linked where actor IDs remain | SDK/provider IP and access-log practices, crash/performance uploads, redaction, retention; local OSLog is not itself a remote analytics integration |
| Account export/deletion receipts and export objects | `AccountPrivacyGateway`; private `exports-private`; deletion worker/operator finalizer | Same underlying disclosed categories plus account-operation metadata; linked; App Functionality | Private export expiry, completion notification, public-media removal, backup expiry and recovery |

The accepted inventory is `docs/security/data-inventory.yml`; its own
`implementation_status` says policy contract, not deployment evidence. It
specifies, among other periods, 13 months for engagement, two years after report
closure, seven days for ready export objects, and seven-year/legal-hold windows
for some audit records. These are existing policy targets requiring legal
reconciliation and enforcement evidence, not newly approved public promises.
Resolve its ordinary-local-filename prohibition explicitly with the distinct
original filename sent by an intentional creator submission.

No advertising/tracking SDK or cross-company advertising flow was found in the
scoped source. Do not turn that observation into a final “no tracking” or “data
not collected” answer until SDK/provider and archive review are complete. No
contacts, location, device advertising identifiers, payments, or purchases were
found in the inspected product flow. Provider logs and optional submitted media
still need review. No raw customer records are needed to complete this packet.

## Roles and reviewer access

| Role | Implemented access | Review requirement |
| --- | --- | --- |
| Signed-out visitor | Public catalog projections and local wallpaper core | Confirm the submitted feature scope works without forced sign-in |
| Signed-in account | Own profile, favorites/saves, install grants, reports, export/deletion request/status | Use native Apple sign-in; no reviewer bypass or demo mode currently established |
| Creator | Current creator authorization and terms acceptance; own submissions/uploads | Provision review access safely if shipped; source `CreatorStudioModel`/`CreatorAuthorizationSnapshot`; do not claim open public uploads |
| Moderator | Current grant, AAL2, review/report queues; no self-approval | If these routes ship, provide a reproducible private access path or obtain approval to remove them from the Store product |
| Admin/operator | Privileged grants and identity-deletion finalizer; not ordinary client authority | Never distribute operator credentials in the app, screenshots, public notes, or this packet |
| Worker | Bounded queue leases and object/processing operations | An operational dependency, not a reviewer login |

Authorization source: ADRs 0011/0014, `AuthSessionStore.swift`,
`MarketplaceCoordinator.swift`, `Creator/CreatorGateway.swift`, and backend
role checks. App Store review instructions may use private review fields for
task-specific access; do not place personal Apple Account passwords or live MFA
secrets in repository documents. Resolve Apple-only and role-gated access with
the actual supported review workflow before submission.

## Reviewer walkthrough to verify, then paste privately

1. Install **PENDING final Store build/version** on **PENDING tested macOS**.
   Follow the final sandboxed background-service consent steps. The proposed
   Store artifact must exclude the direct-distribution private Lock Screen
   helper; no such final artifact is asserted here.
2. Choose **Import Video** in the sidebar (or Command-O), select **PENDING
   rights-cleared sample**, and observe processing under **Downloads**.
3. Open **Library**, select the prepared item, preview it, choose connected
   displays and Scaling, then choose **Apply**. Exercise **Pause or Resume**
   through the final verified control. Confirm the source file remains intact.
4. If marketplace ships, open **Discover** or **Browse**, search, inspect a
   wallpaper and its license/attribution, and install it. Open **Account** for
   **Sign in with Apple** when authentication is required. Verify **Show in
   Library**, Favorite and Save on the selected candidate.
5. In wallpaper detail, choose **Report**, select a category, add a safe test
   explanation, and **Submit Report**. **PENDING implemented blocking** must
   be documented here after its final control and behavior are verified.
6. In **Account → Your Data**, choose **Request Export**, refresh until ready,
   and **Save Export**. Use only a disposable test account; never screenshot its
   export contents.
7. On a separate disposable account, choose **Account → Delete Account…**,
   confirm with `DELETE MY WALI`, and complete the verified authentication path.
   Current code may require TOTP enrollment; remediation and **PENDING real
   completion timeframe/notification/Apple revocation steps** must be settled
   before presenting these instructions as a passing flow.
8. If Creator Studio ships, use **Review Creator Terms**, then the final upload,
   metadata and submit controls with approved original test content. If
   moderator routes ship, use the private provisioned review access to exercise
   them. **PENDING verified account and role setup**.
9. Open the effective privacy/support pages. Check disconnect/retry, empty
   library/catalog, cancellation, relaunch and final Quit behavior.

Prepare screenshots from the actual submitted build: library with selected
wallpaper/display controls; wallpaper preview; and verified discovery/detail
only if marketplace ships. Include an account/privacy view only with synthetic
non-sensitive presentation. Use rights-cleared images and avoid TOTP secrets,
private exports, identifiers, beta-only features, staged dialogs and mock
production claims. Final screenshot dimensions and localized assets remain
PENDING App Store Connect validation.

## Submission handoff

Record the exact commit, archive hash, bundle IDs, signed entitlements, version,
tested OS/hardware, production configuration revision and each reviewer journey
result. Fill legal identity/contact, URLs, content/age declarations, access,
privacy labels and encryption answers from evidence, then remove all PENDING
markers. The checked-in Fastlane path currently exports Developer ID; Store
export/upload requires the separately approved distribution work.

Apple references checked 2026-09-09: [metadata fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/),
[review preparation](https://developer.apple.com/app-store/review/guidelines/#before-you-submit),
[account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/),
[Apple credential revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).
