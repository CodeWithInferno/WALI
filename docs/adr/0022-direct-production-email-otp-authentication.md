# 0022: Production email-code authentication for the direct release

- status: accepted
- date: 2026-09-10
- owner_role: architecture_maintainer
- accepted_by: project_owner
- approval_reference: project-owner session approval 2026-09-10 after the pending auth and VM approval requests: "i mean i will allow this time go ahead"
- supersedes: 0021
- supersedes_scope: 0021=direct_release_local_only_activation_condition

## Context

The owner now requests a GitHub release connected to WALI's production Supabase
project, rather than a staging or local-only build. This request motivates the
proposal; it does not record approval of its authentication boundary changes.
ADR 0021 currently requires direct Release marketplace `NO` because Developer
ID cannot use native Sign in with Apple. Its supported entitlement policy must
remain intact.

Read-only inspection of source `664fd4f` found only native Apple authentication:
`AppleSignInCoordinator` obtains an ID token and `AuthSessionStore` exchanges it
with Supabase. The installed, pinned `supabase-swift` 2.54.1 SDK already supports
email OTP request and verification. The app has no email sign-in interface.
The production owner's current `/auth/v1/settings` observation reports email
enabled, signup enabled, email confirmation required, and social providers
disabled. Those fields do not prove SMTP delivery, account operations, or a
release-ready marketplace. The current production catalog-security-state
request returned 503 and remains a separate activation blocker.

[Supabase email OTP](https://supabase.com/docs/guides/auth/auth-email-passwordless)
uses a code entered in the application and requires an appropriate email
template. The default mail service restricts delivery to project-team addresses
and is not a production sender; [custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp)
and actual delivery evidence are prerequisites. Apple web OAuth is not assumed
available: Apple's [web authentication prerequisites](https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple)
include an existing App Store app using Sign in with Apple, which has not been
established for WALI.

## Decision

Implement native email-and-code authentication for
**direct Release only**, using the existing Supabase SDK and production project
`afgxvhhubqzgpijcstsv`. Keep Development and both Store configurations on their
existing native Apple path. Debug retains its existing configuration policy.
No new package dependency, executable, IPC message, local persistence schema,
database schema, or process owner is introduced by this authentication change.

The foreground presents an email field, requests a one-time code, then presents
a code field with explicit verify, resend, change-email, and cancel actions.
`AuthSessionStore` wraps the pinned SDK's
`signInWithOTP(email:shouldCreateUser:)` and
`verifyOTP(email:token:type: .email)`. Account creation is an explicit part of
this sign-in flow (`shouldCreateUser: true`), matching production signup policy;
only successful verification establishes an authenticated account. Code entry
uses HTTPS SDK requests; there is no browser OAuth, app callback URL, custom URL
scheme registration, or app-managed PKCE flow in this proposal. The SDK may
include its normal PKCE parameters internally.

Add a narrow email-auth interface with the real SDK adapter and a deterministic
test adapter. Keep session observation, refresh, and existing Keychain storage
scoped by bundle identifier and canonical Supabase origin. Codes and pending
email/attempt state remain transient and never enter logs, preferences, IPC,
analytics, or release receipts. Bound input sizes, request durations, and resend
behavior. One shared foreground auth service owns session transitions across
windows; each window keeps its own presentation and pending marketplace intent.
This remains foreground ownership, not agent-hosted authentication.

Each email verification attempt uses an isolated SDK AuthClient with in-memory
storage and automatic refresh disabled. Its session and SDK events are private:
they cannot reach the shared Keychain-backed client or the app's account-state
stream directly. Before admission, cancellation, owning-window teardown,
changing email, sign-out, or replacement invalidates the attempt. A late request
or verification result is discarded without publishing a shared session or
resuming a marketplace action. Do not consume the SDK's process-wide notification
as account authority; observe only the shared service's accepted session stream.

Admission has an explicit commit point. In a serialized session transition,
verify that the attempt is still current and has not been cancelled, then mark
admission committed before invoking the shared client's supported `setSession`.
Show a brief **Completing sign-in** state in which Cancel is not offered. Use
bounded transport and serialized transitions; actor isolation alone does not
prevent reentrancy across suspension. The SDK can persist and emit while
`setSession` is running, so generation checks cannot promise to cancel that
write after admission begins. The UI must not label a committed or completed
login as cancelled.

Sign-out or a new attempt received after the commit point is an ordered
subsequent transition. It cannot race the in-flight admission. Window teardown
after that point detaches that window and discards its pending marketplace
intent; it does not retroactively cancel the admitted login. Only the still-live
owning intent for the accepted subject may resume after successful admission.
An admission failure/timeout is reported as a failure, never a completed login;
do not release a still-running admission to race the next transition. Never
invoke shared-client global sign-out to clean up an obsolete isolated attempt,
because that could revoke a newer valid session. These semantics distinguish
cancel-before-commit from a login that has already committed to completion;
no SDK patch or stronger post-commit cancellation guarantee is proposed.

### Explicit release modes and production binding

Record an explicit compiled authentication method, for example
`WALI_AUTHENTICATION_METHOD` / `WALIAuthenticationMethod`, with only reviewed
values. Preserve fail-closed unavailable UI for disabled or incomplete builds.
The direct policies are separate:

| Direct mode | Marketplace flag | Authentication | Publication eligibility |
| --- | --- | --- | --- |
| Local preview | exact `NO` | disabled | Local inspection only; cannot satisfy production publication |
| Production connected | exact `YES` | exact `email_otp` | Eligible only after every production and native release gate passes |

Development and Store remain `native_apple` when configured; production email
selection must never fall back to native Apple or silently alter those editions.
Direct Release keeps `Config/WALI-Release.entitlements` without
`com.apple.developer.applesignin`. An enabled flag alone is insufficient.

Add a reviewed, versioned public production configuration manifest under
`Config/` (proposed `Config/Marketplace.production.json`). It binds the exact
production project reference, API origin
`https://afgxvhhubqzgpijcstsv.supabase.co`, public publishable-key identity,
reviewed CDN origins, active and recovery catalog key IDs/public keys, and auth
method. Use exact allowlists; staging, localhost, arbitrary HTTPS hosts,
unresolved substitutions, unknown methods, incomplete keys, SDK-conditional
setting overrides, or mismatched app/agent trust values fail validation.
A publishable key is not proven production-correct by its textual prefix:
verify its use against the exact production service and record a fingerprint
and non-sensitive result. Never place privileged credentials in this manifest.

Verify the same canonical configuration through the source manifest, generated
and resolved Xcode settings, actual foreground Info.plist, the agent's applicable
CDN/trust Info fields, and archive/package/publication receipts. The agent needs
no Auth client, publishable key, or account tokens. Record the canonical
configuration digest and release mode in the existing receipts and revalidate
at archive, notarization, and publication boundaries. Continue binding receipts
to the exact source and signed app bytes. A local-preview or staging artifact
cannot be relabelled production by changing a command-line option or receipt.

### Account and provider policy

ADR 0011 requires Supabase, environment separation, least privilege, and
foreground account ownership; it does not mandate an Apple-only provider.
Existing WALI profile creation and authorization use the verified Supabase
subject, not the provider or an email-derived role. Email verification establishes
normal AAL1. Preserve all current TOTP enrollment, fresh AAL2, role, revision,
and current-subject checks for deletion and privileged actions. An email OTP
must not be treated as an MFA challenge or replace fresh AAL2.

Use the existing account ID and existing Supabase identity behavior. Do not add
custom email-based linking, merge accounts, transfer roles, or migrate Store
sessions. Verify behavior for an existing email account and any existing linked
identity without promising that Apple relay and personal email addresses refer
to the same WALI account. Store Apple authorization/revocation readiness remains
a separate requirement; email auth does not resolve it.

Account deletion remains the existing provider-neutral operation: request with
fresh AAL2, transactionally revoke Supabase sessions and WALI roles, process
content/retention work, then perform the existing admin-AAL2 identity finalization
and verify Supabase deletion. Its `awaiting_auth_cleanup` state is not completion.
This proposal neither automates that operator step nor weakens retention or legal
holds. Production worker processing and the authorized cleanup runbook must be
verified before claiming deletion works for new email accounts.

## Invariants

- No SMTP password, service-role key, database password, private catalog key, or
  provider secret enters the app, repository, fixtures, logs, or receipts.
- Preserve direct identities, App Group, peer validation, helper boundaries,
  signature/profile checks, hardened runtime, timestamping, and notarization.
- Preserve Store entitlements, native Apple behavior, sandbox isolation, and
  separate bundle/origin Keychain namespaces. No account or library migration.
- Supabase/RLS remains authoritative. Installed local media continues to work
  when authentication, catalog services, or the worker is unavailable.
- Failed security-document verification continues to block catalog installation;
  enabling authentication must not bypass trust, rights, or revocation checks.
- This proposal authorizes no new paid service commitment. Production SMTP
  configuration and credentials require a verified existing service or separately
  authorized setup; successful public send/receive must be demonstrated.
- Approval permits implementation. It does not establish production readiness,
  waive existing acceptance gates, or authorize publishing an unverified build.

## Alternatives considered

- Native Apple in Developer ID remains unsupported; adding its entitlement or
  weakening profile checks cannot fix the distribution limitation.
- Browser Apple OAuth has additional eligibility, Services ID, callback, secret,
  and rotation requirements. Browser OAuth is supported by the pinned SDK, but
  no production social provider is currently enabled. It adds a larger boundary
  than email codes for this release.
- Magic links require redirect/deep-link handling. Password accounts add password
  collection and recovery flows. Neither is needed for the chosen email-code UI.
- Shipping marketplace `NO` does not meet the owner's revised production request.
  Keep it only as an explicitly identified local preview and rollback state.

## Consequences and implementation boundaries

Implement the smallest tested slices, with exclusive file ownership agreed
before concurrent edits:

- Auth adapter: `Sources/WALICatalogRuntime/AuthSessionStore.swift`,
  `CatalogEnvironment.swift`, `SupabaseCatalogGateway.swift`, and a narrow new
  email-auth interface if needed. Preserve `AppleSignInCoordinator.swift` behavior
  and `CatalogAuthKeychainNamespace.swift` isolation.
- Foreground flow: `Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift`,
  `AccountView.swift`, a new email-code sheet, `WALIAppRootView.swift`, and
  `WALIConnectedAppRootView.swift` for shared foreground session composition.
  `Sources/WALIUI/CatalogPresentationModels.swift` changes only if presentation
  values need an explicit email-flow state. Preserve unavailable-route guards.
- Configuration/policy: the proposed public manifest, `Config/Base.xcconfig`,
  `Config/Release.xcconfig`, `Config/Marketplace.example.xcconfig`,
  `project-common.yml`, `scripts/check-architecture.rb`,
  `scripts/verify-bundle.sh`, `fastlane/release_support.rb`, `fastlane/Fastfile`,
  and `scripts/ci-release.rb`. Existing signing verifiers must retain the direct
  no-native-Apple rule; no new entitlement exception is required.
- Public contract: module/surface inventories, threat model, release instructions,
  and edition-accurate privacy/support text describing email and hosted accounts.
  Hosted SMTP/email-template changes are explicit production configuration steps,
  not a migration or secrets checked into source.

The existing SQL/Edge account contract has no provider-specific schema change
required by email OTP. If implementation finds one necessary, stop and propose
that additional scope instead of silently expanding this ADR.

## Migration and rollback

On acceptance, record reciprocal scoped supersession of ADR 0021's **direct
Release local-only activation condition only**. Retain all of ADR 0021's
supported entitlements and all ADR 0020 identity/data decisions. Until acceptance
and verification, the existing marketplace-NO policy remains effective.

No user/library/account migration is introduced. Production and staging sessions
remain isolated. Rollback disables marketplace networking/auth in a newly
verified local-preview build and keeps installed local content usable; it does
not revoke unrelated accounts, delete source media, or restore unsupported
native Apple entitlements. Previously signed artifacts and their receipts are
immutable and retain their original mode.

## Verification and activation gates

1. Adapter/interface tests cover bounded email/code input, explicit signup,
   no shared session after code request alone, successful verification,
   wrong/expired/reused code, rate limiting, and timeout. A cancelled or replaced
   pre-admission attempt must not write shared storage, emit an accepted account
   event, or resume an action even when its SDK operation completes late. Pause
   admission deterministically across `setSession` suspension: assert Completing
   sign-in offers no Cancel, later sign-out/new attempts remain ordered, and
   closing the owning window prevents action resumption without retroactively
   cancelling the committed login. Cover failed admission, storage failure,
   multi-window broadcast/observer teardown, and cleanup that never globally
   signs out a newer session. No raw server text or codes reach presentation or
   logging. Use injected transport, storage, and clock fixtures; no fixed sleeps.
2. Extend `Tests/WALIAppTests/MarketplaceCoordinatorTests.swift` and add focused
   `Tests/WALICatalogRuntimeTests/` cases for email flow, disabled/unknown method,
   stale navigation, resumed install/favorite/save/report only after current
   authentication, existing-session refresh, and preserved native Apple selection.
   Keep current deletion TOTP/AAL2 and early-completion refusal tests.
3. Extend architecture, bundle, release-support, and ci-release fixtures to reject
   wrong project/API/CDN/key/trust manifest, conditional overrides, app/agent
   mismatch, unknown or native-Apple direct auth, altered receipts, and a
   local-preview artifact presented for production. Validate generated Release
   settings and an actual signed universal bundle. Store suites remain green.
4. Verify production SMTP sender configuration and receive a real code at an
   authorized address outside the Supabase project team. Verify both new-account
   confirmation and existing-account email templates actually deliver an entered
   code, not an unusable link. Keep confirmation enabled; verify expiry, resend,
   and abuse/rate-limit behavior. Do not infer public delivery from settings or
   a project-team-only test. Record no address, code, token, or SMTP secret in
   public evidence.
5. On the exact signed candidate, verify production signup/login, cancellation,
   restart/session refresh, sign-out, account profile isolation, fresh TOTP/AAL2,
   and the existing deletion/export operational path using authorized test
   accounts. Preserve Store isolation and complete Quit/native playback checks.
6. Restore a valid production catalog security document and verify its signature,
   recovery trust, freshness, and app/agent agreement. Retain published-content
   rights, worker readiness, media validation, backup/restore, legal/support,
   and operational gates. Authentication success alone does not clear them.
7. Preserve exact-final-source CI, reviewed candidate bytes, native acceptance,
   notarization/stapling, package manifests/checksums, and normal publication
   requirements. The initial release remains a prerelease until its existing
   broader release criteria are satisfied. No test writes the live Apple
   wallpaper store; no staging evidence substitutes for production verification.
