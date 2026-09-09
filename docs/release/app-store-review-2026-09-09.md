# WALI Mac App Store initial review — 9 September 2026

Review baseline: `6723f24a706931a4177c480bed0ee7914f2efb21`, with the pending Fastlane dependency update inspected separately. This is a source and configuration review, not an App Store acceptance result. No product code was changed for this first pass. Apple guidance was checked on the review date. Findings are specific to macOS; iOS-only requirements are not assumed to apply.

## 1) Executive Summary

- WALI imports local video, renders animated desktop wallpapers through a background agent, and optionally offers a creator wallpaper marketplace. Local wallpaper use does not require an account or purchase.
- Approval risk 1: the current Release app is a non-sandboxed Developer ID product, and includes a helper that modifies private Apple wallpaper stores. It cannot be submitted unchanged to the Mac App Store.
- Approval risk 2: production marketplace reviewability is unfinished: public policies/contact, blocking, account deletion completion, Apple authorization revocation, and hosted operational evidence are missing or unresolved.
- Approval risk 3: no Store archive/export/upload configuration or verified App Store Connect metadata is available. The existing signing attempt stopped at missing provisioning profiles.
- Fast win 1: correct Swift dependency accounting and distribute the complete third-party license notices inside the app and release materials.
- Fast win 2: preserve a concrete review packet, with honest feature availability, verification steps, policy URLs, support information, and reviewer access.
- Fast win 3: separate direct-distribution and Store requirements before changing entitlements; retain the approved branded DMG for the signed GitHub release.
- Existing strengths include native Sign in with Apple and nonce protection, export/deletion UI, human moderation, reporting, and a tested local branding/installer pipeline. These do not prove hosted production or sandbox behavior.

## 2) Risk Register

P0 = submission blocker; P1 = high risk; P2 = medium or conditional risk. Effort: S/M/L.

| Priority | Area | Finding | Why Review Might Reject | Evidence | Recommendation | Effort | Confidence |
|---|---|---|---|---|---|---|---|
| P0 | Permissions | Current executable wrappers are not sandboxed | The submitted Mac app must use App Sandbox | `Config/WALI.entitlements`, `Config/WALIAgent.entitlements`, `project.yml:278` | Add and validate a separate Store distribution configuration | L | High |
| P0 | Permissions | Embedded helper reads and rewrites private Apple wallpaper stores | This behavior is incompatible with the Store sandbox and supported API boundary | `Sources/WALILockScreenHelperRuntime/FixedWallpaperStore.swift:25,242`; ADR 0013 | Exclude helper, registration, adapters, and continuity routes from the Store artifact | L | High |
| P0 | Technical | Fastlane only exports Developer ID builds | Current artifact is not a Store upload candidate | `fastlane/Fastfile:59–88`; `scripts/validate-signature-metadata.rb:35` | Add separate Store signing/export/upload and verification after architecture approval | M/L | High |
| P1 | Permissions | Agent startup requires both launch services; current Mach service lacks group prefix | Removing the helper or enabling sandbox alone can break startup and IPC | `Sources/WALIAppRuntime/IPC/AgentLifecycleController.swift:22`; `Config/Release.xcconfig:7` | Distribution-specific lifecycle, group-prefixed IPC, signed sandbox tests | L | High |
| P1 | Technical | Sandbox import and runtime behavior remain unproven | Core import/render lifecycle could fail during review | ADR 0013; `Sources/WALITranscoderRuntime/WALITranscoderServiceRunner.swift:199` | Validate scoped file access, desktop windows, Spaces, reconnect, cancellation, and relaunch | L | High |
| P1 | Privacy | Policy URL returns 404 anonymously; policies remain draft; no private support contact | Reviewers and users cannot access effective privacy/support information | `Config/Base.xcconfig:22`; `docs/legal/privacy-policy.md:4,63`; `Sources/WALIAppRuntime/Marketplace/AccountView.swift:382` | Publish approved policies and an actual support/contact destination | M | High |
| P1 | Content | Reporting exists but no end-user creator blocking was found | UGC safeguards are incomplete | `MarketplaceWallpaperDetailView.swift:280`; `202609040009_report_resolution.sql:123`; scoped source search | Add persistent blocking and enforce it across discovery, search, and detail | L | High |
| P1 | Account | Apple credential revocation is absent | Deleting Supabase identity alone does not complete Apple authorization handling | `Sources/WALICatalogRuntime/AppleSignInCoordinator.swift:90`; `supabase/functions/request-account-deletion/index.ts:205` | Implement token revocation or Apple's documented manual fallback where no token is available | M/L | High |
| P1 | Account | Deletion completion and public UGC removal are not demonstrated | A request without reliable completion or appropriate content removal is insufficient | `docs/runbooks/account-deletion.md:6`; migration `202609010012_edge_commands.sql:2290,2370`; privacy policy:48 | Prove the full workflow, confirmation and retention policy; resolve public-object cleanup | L | High for missing proof; medium for retention assessment |
| P1 | Technical | Swift packages are absent from SBOM; shipped notices are incomplete | Distribution obligations and the submitted dependency inventory are not satisfied | `scripts/generate-sbom.rb:78`; `project.yml:28`; `THIRD_PARTY_NOTICES.md:9`; built app resources | Inventory the resolved graph, correct licenses, bundle complete notices | M | High |
| P1 | UX | Production services and reviewer access are not ready | Submitted features must work for review | Production schema/functions deployed; auth/worker/signer/legal activation still unverified | Complete configuration and record actual production journey evidence | L | High |
| P2 | Account | Apple-only users must enroll a new authenticator to request deletion | This may make deletion unnecessarily difficult | `Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift:929–949` | Review fresh Apple reauthentication as an alternative; test a new account | M | High for behavior; conditional review impact |
| P2 | Content | Queries request mature content without an evident content control | Suitability depends on actual content and the declared age rating | `MarketplaceCoordinator.swift:398`; `Sources/WALICatalogRuntime/CatalogGateway.swift:55` | Set the content policy/rating and enforce consistent filtering | M | High for behavior; conditional review impact |
| P2 | Privacy | Archive privacy resources/disclosures and encryption answers are unverified | Incorrect disclosures or export answers can delay submission | No tracked first-party manifest; Swift Crypto resource observations; CryptoKit/Supabase use | Inspect the signed archive, complete the data inventory and export questionnaire | M | High |
| P2 | UX | Background registration consent and complete quit behavior lack signed evidence | Background/login activity must match user expectations | `WALIAppCoordinator.swift:65`; launch plists `RunAtLoad` | Verify consent, launch, and stopping all processes in the Store build | M | Medium |

## 3) Detailed Findings

### Privacy & Data Handling

**Policies and support.** The configured GitHub policy URL was inaccessible anonymously, and the privacy/terms documents explicitly remain drafts. Publish effective documents with the real operator, contact, retention and deletion details, then test every link while signed out and from the final app. The source audit cannot supply legal approval or invent a company identity. [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/)

**Disclosures and SDK resources.** Inspect the final archive's privacy report and reconcile marketplace account, upload, report, diagnostic and operational data with the actual production setup. No first-party manifest is tracked; Swift Crypto resources require verification. This is not, by itself, a proven macOS required-reason API violation: Apple's current platform list for that requirement omits macOS, and these packages are not named on the required SDK list. [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)

**Encryption.** WALI verifies signatures through CryptoKit and uses authentication dependencies. Complete Apple's export questions from the actual build and intended distribution. Set an exemption declaration only if the answers support it; retain the determination with the release evidence. [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

### Permissions & Entitlements

**Store boundary.** The direct-distribution app, agent and private Lock Screen helper do not form a sandboxed Store product. A Store variant must exclude private-store behavior throughout the binary graph and presentation, adjust service registration and IPC names, and retain only necessary entitlements. A proposed ADR must describe these security, compatibility and runtime changes before implementation. Validate the exported app's complete embedded executable graph and signed entitlements. [App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [App Groups and IPC](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)

**File access and lifecycle.** The transcoder resolves bookmarks without the security-scope resolution option and currently continues if scope acquisition fails. The sandbox variant needs explicit valid access to source media, shared artifacts and containers. The renderer uses public AppKit/Core Graphics APIs; source does not prove it impossible under sandboxing. Test user-selected import, agent/worker access, multi-display windows, Spaces, sleep/wake, reconnect, cancellation and relaunch. Registration consent and complete Quit WALI behavior need interactive evidence.

The applicable review rules require sandboxing, supported APIs and user-consistent background behavior. They do not justify declaring all live-wallpaper apps ineligible. [App Review Guidelines, performance](https://developer.apple.com/app-store/review/guidelines/#performance)

### Monetization (IAP/Subscriptions)

No payment, subscription, paywall or purchase restoration flow was found in the inspected product. Do not add IAP or claim missing restore purchases as a current defect. Verify the submitted build and listing do not advertise unavailable paid features. If monetization is added later, perform a separate StoreKit review.

### Account & Authentication

**Apple sign-in and deletion.** Sign-in uses native Apple identity and nonce protection. Deletion UI, progress, worker cleanup and an operator identity-cleanup function exist. However, the native status path does not finalize identity cleanup, the runbook lacks operational completion/notification evidence, and no Apple token revocation or manual fallback was found. Finish and exercise the complete workflow with a disposable account; communicate completion and a real timeframe. Where no Apple token is available, follow Apple's documented fallback without withholding deletion. [Account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/), [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)

**Retention and friction.** The draft permits some licensed public releases to remain after deletion, while the implemented private-object cleanup does not prove removal of public bytes. Reconcile public UGC, attribution and legally justified retention; test actual storage outcomes. Also assess the requirement for a new Apple-only user to enroll TOTP solely to delete an account. Identity confirmation is legitimate, but the complete experience needs a proportionate path.

Hosted Apple provider/audience/MFA configuration remains unverified: the attempted authenticated configuration read returned HTTP 403. This is not evidence that those settings are wrong.

### Content / UGC / External Links

Human moderation, reports, reason validation and audited hiding/delisting are implemented. End-user creator blocking was not found. Add it with server enforcement and tests across discovery, search and detail. Establish a real report-response contact and operation. Review the mature query ceiling against actual content and the selected age rating; no harmful production content was inferred from source. These are applicable UGC controls, not a requirement to add an automated classifier. [App Review Guidelines, user-generated content](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)

### Technical Stability & Performance

**Distribution.** The Fastlane path requires Developer ID and exports a direct-distribution app. Add a separately verified Store archive/export/upload path after approval of the Store architecture. GitHub distribution still requires Developer ID signing, notarization, stapling, and validation of the final DMG. A local Debug DMG is preview evidence only. [Uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

**Dependencies and notices.** The SBOM parser recognizes `version` but the project pins Supabase using `exactVersion`; it therefore omits the resolved Swift graph. The license map also labels Supabase Apache-2.0 although its pinned source is MIT. The app lacks complete bundled third-party notices. Fix graph accounting, use the actual pinned license texts, and assert those resources exist in the final exported archive. Separately, the pending Fastlane upstream pin removes the Rubyzip security finding; it needs fresh CI on the final commit.

**Evidence.** The branding baseline passed `make verify`, including native/package suites, coverage, architecture, bundle/signature fixtures and real Finder layout checks. These checks do not establish signed sandbox behavior, sustained hardware performance or production marketplace journeys. Record those separately against the release candidate.

### UX & Reviewability

The reviewer needs a working core loop, understandable first launch, accessible support, and access to every feature actually submitted. Prepare a rights-cleared sample and exact navigation instructions, with the real marketplace availability and permissions explained. Provide credentials only through App Store Connect's private review fields. Do not reuse historical staging evidence as production proof. [App Review preparation](https://developer.apple.com/app-store/review/guidelines/#before-you-submit)

## 4) Reviewer Experience Checklist

| Action | Current evidence / gate |
|---|---|
| Install and launch | Branded Debug DMG verified in Finder; signed/notarized release and Store installation pending |
| Understand first run | Native local wallpaper core exists; final signed first-run walkthrough pending |
| Grant required permissions | Direct-distribution helper and future Store sandbox must be tested separately |
| Import and apply wallpaper | Implementation and automated suites exist; final candidate end-to-end evidence pending |
| Purchase and restore | Not applicable to inspected build |
| Sign in / marketplace | Native sign-in exists; hosted production configuration and reviewer access unverified |
| Report/block content | Reporting exists; creator blocking absent |
| Export/delete account | Request/progress exists; complete production workflow and Apple authorization cleanup pending |
| Open privacy/support/legal links | Fails current public URL check; effective public destinations needed |
| Offline, empty state, interrupted import | Automated coverage is not a substitute for the final interactive walkthrough |

## 5) Suggested Reviewer Notes (Draft)

> WALI is a macOS animated desktop wallpaper application. Its local import/apply workflow does not require an account or purchase.
>
> Build and minimum macOS: [FINAL BUILD / CONFIRMED MINIMUM].
>
> Local workflow: open WALI, choose the library import action, select [RIGHTS-CLEARED SAMPLE], wait for processing, and apply it to [DISPLAY SELECTION]. Use [FINAL VERIFIED MENU ACTION] to stop playback or quit.
>
> Store permissions and background behavior: [ACTUAL SANDBOXED BUILD BEHAVIOR AND USER CONSENT STEPS]. The submitted Store artifact must not include the direct-distribution private Lock Screen helper.
>
> Marketplace availability: [ACTUAL SHIPPED AVAILABILITY]. If included, sign in using [PRIVATE REVIEW ACCESS IN APP STORE CONNECT] and follow [VERIFIED DISCOVERY/REPORT/BLOCK/ACCOUNT NAVIGATION]. Role-gated features: [PRIVATE ACCESS DETAILS OR EXPLICITLY ABSENT FEATURES].
>
> Purchases: no in-app purchases are present in the reviewed source; confirm this remains true for the submitted build.
>
> Support: [PUBLIC URL AND PRIVATE CONTACT]. Privacy: [PUBLIC EFFECTIVE POLICY URL]. Account deletion: [VERIFIED STEPS, COMPLETION TIMEFRAME AND CONFIRMATION].

These notes contain placeholders deliberately and are not ready to submit.

## 6) Next Pass

The owner has authorized remediation and releases. Proceed with dependency/license fixes and concrete release preparation; propose the Store architecture and obtain the repository-required approval for its security/runtime boundary changes. Complete missing identity, policy, authentication and signed runtime evidence before publishing a release or submitting an App Store request. Track each finding as fixed, tested, pending or explicitly out of the submitted product; do not mark this initial report as acceptance.
