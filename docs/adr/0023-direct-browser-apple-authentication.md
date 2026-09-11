# 0023: Browser Apple authentication for the direct release

- status: proposed
- date: 2026-09-11
- owner_role: catalog_maintainer
- accepted_by: pending
- approval_reference: project-owner session 2026-09-11 requested restoration of Apple login through the described browser and production Supabase flow, then directed autonomous execution: "Who are you waiting for then? Come on, start working. You are autonomous." Concrete proposal and unresolved registration values await coordinating maintainer review; this record does not itself claim acceptance.
- supersedes: 0022
- supersedes_scope: 0022=direct_release_email_only_authentication

## Context

The owner downloaded the GitHub release and reported failed email-session
completion, missing Apple login, and an absent production catalog. Email and
catalog repairs proceed independently. Restoring Apple login to Developer ID
requires a browser flow; the supported no-native-Apple entitlement decision in
ADR 0021 remains effective. Store and Development retain native Apple.

Current source has one shared foreground `CatalogAuthAuthority`, an isolated
email-attempt `AuthClient`, and checked Keychain admission. Its only configured
methods are `disabled`, `email_otp`, and `native_apple`. There is no browser
callback or Services ID in the repository. The pinned `supabase-swift` 2.54.1
at `b118484ae0eb4a6b6ce1b216711d660baf6ec1aa` already supports S256 PKCE,
`getOAuthSignInURL`, and `exchangeCodeForSession`; no SDK upgrade is needed.

Apple's [web configuration instructions](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/)
require a Services ID associated with a primary App ID enabled for Apple
sign-in. Apple's [website/platform usage guidance](https://developer.apple.com/sign-in-with-apple/usage-guidelines-for-websites-and-other-platforms/)
separately states an App Store prerequisite for its JavaScript API. This design
uses the Supabase-hosted REST OAuth integration, not Apple JavaScript. Neither
an unverified portal capability nor a draft Store record establishes successful
provider eligibility. Verify the actual primary-app association and live flow;
do not claim that a new Store record resolves every Apple prerequisite.

## Decision

Add browser Apple sign-in alongside working email codes in direct production.
The proposed new compiled method is `email_otp_apple_web`. Preserve the existing
`email_otp` production mode as a valid fallback and keep local preview disabled.
Only the direct foreground may select the combined method. Store, Development,
and Debug keep their current policies; no Apple native entitlement is added to
Developer ID.

The flow is:

```text
Direct WALI foreground
  -> isolated PKCE AuthClient -> production Supabase /auth/v1/authorize
  -> ASWebAuthenticationSession -> Apple consent
  -> production Supabase /auth/v1/callback
  -> current WALI web session receives one authorization code
  -> isolated client exchanges code with its own PKCE verifier
  -> shared CatalogAuthAuthority admits verified Supabase session
  -> existing account snapshot and owning-window intent update
```

The [Supabase Swift API](https://supabase.com/docs/reference/swift/auth-signinwithoauth)
supports a custom browser launcher. Use a small retained main-actor
`ASWebAuthenticationSession` adapter and the pinned SDK's lower-level methods.
The pinned convenience overload ignores the result of `start()` and has no
caller-cancellation wiring. It also hands the callback directly to the SDK.
WALI must check start failure, cancellation, and callback shape first.

### Exact configuration and unresolved values

| Item | Evidence or required value |
| --- | --- |
| Production Supabase project | `afgxvhhubqzgpijcstsv`, from the reviewed production manifest |
| Apple website domain | `afgxvhhubqzgpijcstsv.supabase.co` |
| Apple HTTPS return URL | `https://afgxvhhubqzgpijcstsv.supabase.co/auth/v1/callback` |
| Apple team | `UH5Z2K4G9H`, recorded in accepted ADR 0020; confirm selected portal team |
| Candidate primary WALI App ID | `com.wali.store.WALI`, from `Config/AppStore.xcconfig`; portal registration and native-Apple capability remain unverified |
| Apple Services ID | Not established. Read the team's existing Services IDs and their primary-app association before selecting or registering a value. Do not treat a guessed identifier as provisioned. |
| Supabase-to-WALI callback | Not established. Select one exact direct-only custom-scheme URL during review, record its canonical scheme/host/path, and add that exact value to the production redirect allowlist. No wildcard, staging, or localhost callback. |
| Apple signing key/client secret | Server-only configuration; existing key availability and expiry remain unverified |

The two callback URLs have different owners. Apple returns to Supabase's HTTPS
URL; Supabase returns a PKCE code to WALI's selected custom URL. Do not register
the custom URL as Apple's return URL.

[Supabase's Apple integration](https://supabase.com/docs/guides/auth/social-login/auth-apple)
requires the Services ID first in its Apple client-ID list for web OAuth.
Preserve the production Store native audience in the same list; native token
exchange accepts configured audiences independently of order. Retain existing
project separation when deciding whether development audiences belong there.
The server-side Apple client secret needs renewal before its six-month expiry.
Record its expiry and responsible operator privately; never embed the secret
or signing key in WALI, source, logs, or release receipts.

Bind the new method and exact WALI callback to a reviewed production manifest
version and its canonical digest. Update source, generated/resolved settings,
foreground Info fields, archive/package receipts, and publication validation
together. The browser does not need the private key or Apple client secret.
Keep existing production email manifests and previously signed receipts
interpretable under their original version; never relabel old bytes.
The agent receives no callback, Apple provider configuration, or credentials.

### Callback and PKCE boundary

- One foreground authority reserves one current authentication attempt across
  email and browser flows. A browser attempt owns a UUID, owning-window UUID,
  monotonic deadline, web-session identity, isolated SDK client, and isolated
  in-memory storage. Browser attempts cannot replace the shared session merely
  by opening a URL or receiving a callback.
- Explicitly configure the isolated client with `.pkce`, no automatic refresh,
  no persistent storage, and no SDK logger. Its verifier and exchanged session
  remain private until admission. Use the SDK's S256 challenge generation; do
  not implement a second verifier or use implicit access-token redirects.
- Supabase owns and validates its OAuth `state` with Apple. WALI must not
  override that value or assume arbitrary provider parameters are echoed.
  WALI's callback correlation is the active web-session object and current
  attempt generation; the code exchange is additionally bound to that
  attempt's verifier. A code from another attempt fails rather than switching
  identities.
- Retain the system web-session object, present from the initiating window,
  require `start()` to succeed, and finish its continuation at most once.
  Apple documents [session-specific callback delivery](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).
  Do not add a process-wide URL event handler that admits unsolicited login.
  If platform testing proves scheme registration necessary, register only the
  reviewed direct callback scheme and keep admission exclusive to the live
  `ASWebAuthenticationSession` completion.
- Before exchange, require the exact configured scheme, host, and path; reject
  userinfo, port, fragments, duplicate keys, extra credential fields, and
  oversized URLs. The callback may contain one bounded nonempty `code`, or a
  bounded provider error. Reject access tokens, refresh tokens, and mixed
  success/error callbacks. Decode exactly once and reject ambiguous encoded
  structural characters. Never log the complete callback, code, verifier,
  Apple credentials, or raw server error description.
- Suggested bounds are a 16 KiB callback URL, an 8 KiB authorization code,
  15-second network request timeout, 30-second resource timeout, and a
  five-minute interactive attempt deadline. Use the existing redirect-rejecting
  HTTPS transport for token exchange against the exact production origin.
  Browser navigation itself remains owned by the system authentication session.
- Clear all isolated storage and invalidate the transport on failure,
  cancellation, replacement, deadline, or completion. Never call shared global
  sign-out to clean up an obsolete attempt.

### Shared-session admission and lifecycle

Generalize the internal candidate name from email-specific to provider-neutral
only where email and browser genuinely share it. Keep the existing checked
storage admission and transition gate as the only shared persistence path.
Do not call browser OAuth on the shared Keychain-backed SDK client.

A verified candidate is bounded and has a nonexpired session and Supabase
subject. Before committing, the authority revalidates the attempt, owning
window, cancellation state, and deadline while holding the transition gate.
It then uses the same explicit commit point and Completing sign-in state as
email. The gate stays held across the supported shared `setSession` and checked
storage commit. A browser callback never updates UI account state directly.

Cancel, replacement, sign-out, and window teardown before commit invalidate
the attempt; late browser and token-exchange completions are discarded. After
commit, cancellation cannot retroactively undo admission. Sign-out or another
login is an ordered subsequent transition. Closing the initiating window
removes its pending action but does not report an admitted login as cancelled.
Other windows observe only the authority's accepted session stream.

An admission failure reports a safe retryable failure and preserves checked
storage rollback semantics. Fix the reported email admission failure through
that same seam before enabling the browser path. Do not duplicate or bypass
its protection to make one provider appear to work.

### Account identity and Store isolation

The verified Supabase subject remains the account key. Preserve existing
provider linking behavior; do not link on an email match in WALI, merge Apple
relay accounts, move roles, or copy another edition's Keychain data. Apple
consent is AAL1, not fresh MFA. Keep existing TOTP/AAL2 and current-subject gates.

Existing Keychain service names remain bound to the foreground bundle ID and
canonical Supabase origin. A shared cloud account does not authorize shared
local sessions or libraries across direct and Store products. Store keeps
`AppleSignInCoordinator` and its native nonce/ID-token exchange. Do not enable
the direct callback handler or combined method in Store composition.

Preserve the existing account-deletion checkpoints. Before claiming Apple
account lifecycle complete, confirm the hosted integration's Apple token
revocation path; Supabase session revocation alone does not prove Apple grant
revocation. If that needs new token retention, Edge endpoints, persistence, or
permissions, propose that extra boundary explicitly instead of silently adding
it here. This proposal authorizes no such schema or backend change.

## Invariants

- Foreground account ownership, agent runtime ownership, package dependencies,
  IPC, library schemas, signed-catalog trust, media rights, and local playback
  remain unchanged.
- Email sign-in and public catalog repair do not depend on Apple provisioning.
- Store sandbox, identities, native Apple entitlements, helper exclusion, and
  data separation remain unchanged.
- No credential is included in diagnostics, artifacts, source, or shared group
  containers. The system browser collects Apple credentials.
- Production uses exact reviewed configuration; absent provider setup exposes
  a truthful unavailable Apple option and leaves email usable.

## Alternatives considered

- Native Apple in Developer ID contradicts ADR 0021's supported entitlement
  policy and does not solve the distribution constraint.
- Opening an arbitrary browser and accepting global URL callbacks loses the
  retained system session's lifecycle and correlation guarantees.
- Calling shared-client `signInWithOAuth` bypasses WALI's pre-admission
  cancellation and checked persistence boundary.
- Apple JavaScript plus a new hosted callback service adds another public
  service and is unnecessary for the chosen Supabase-hosted integration.
- Replacing email entirely would unnecessarily remove the existing login path
  and couple every user to Apple provider availability.

## Consequences

Apple login can return to the GitHub build without native Apple entitlements
or a new runtime dependency. The feature adds a browser callback boundary,
provider configuration, and secret-renewal responsibility. Exact callback and
Services ID values must be established before enabling it in a signed release.
No new database, IPC, or user-library migration is included.

## Migration and rollback

After review records acceptance, add the reciprocal scoped supersession to
ADR 0022 for its direct email-only method and no-browser-callback decision.
Its email lifecycle, isolation, production binding, and broader gates continue
to govern. ADR 0021's native entitlement prohibition is not superseded.

Existing email sessions remain in their current namespace. New browser
sessions enter through the same checked store. Rollback selects the validated
email-only method in a new artifact and preserves installed media and existing
accounts. Do not delete Apple keys, remove Store client audiences, revoke
unrelated sessions, or rewrite old release receipts during rollback.

## Verification

Use the new attempt/launcher seams to cover exact callback matching,
malformation, wrong/duplicate/mixed parameters, absent verifier, wrong-attempt
code, replay, launch failure, browser cancellation, deadline, replacement,
window teardown, and exactly one terminal callback. Deterministically pause
exchange and shared admission to test both sides of the commit point and
multi-window/sign-out ordering. Exercise storage failure through the real
shared admission adapter, not a bypass.

Verify mode selection and strict production-manifest/receipt rejection,
including unknown callbacks and a combined mode in Store. Preserve native
Apple and existing email tests. Run affected architecture, signing/bundle,
and release checks without changing the Developer ID entitlement policy.

On the final production-configured signed candidate, prove browser launch,
Apple consent, return to the initiating WALI session, admission, account
snapshot, relaunch/refresh, and sign-out with an authorized test account.
Confirm email still works and Store native Apple still has its configured
production audience. Record redacted outcomes and exact candidate identity;
do not equate fixture success or portal setup with successful real sign-in.
