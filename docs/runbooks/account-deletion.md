# Marketplace account deletion

**Owner:** catalog maintainer. **Exceptional policy holds:** security responder.

Accepted [ADR0029](../adr/0029-autonomous-account-deletion-and-apple-revocation.md)
defines the automatic path. Schema, Edge, worker and native changes require a
coordinated activation and disposable-account acceptance. Local tests and queue
acknowledgements do not establish production identity deletion.

## Normal operation

The native client stores 32 random bytes in its edition/project Keychain before
requesting deletion. `request-account-deletion` accepts `account.v2`, the existing
request/idempotency identity, profile revision, exact confirmation, policy
`2026-09-13` and SHA256 of the decoded bytes. Real subject authentication and fresh
AAL2 remain mandatory. No caller chooses an account ID. Acceptance commits the
consent, hash, profile freeze and automatic job together. A lost acceptance reply
is reconciled from that exact job, including durable session revocation.

The media worker removes only leased exact objects and pseudonymizes the account.
The automatic finalizer waits for verified cleanup, applicable holds and Apple
binding leases. It revokes each prepared Apple authorization, checkpoints and
purges that credential, then uses the existing Edge-only Auth admin key for the
exact prepared subject. The provider request is
`DELETE /auth/v1/admin/users/{id}` with JSON `{"should_soft_delete":true}`;
query parameters do not select soft deletion. Redirects are denied. A bounded
GET verifies the same subject's deleted state or confirmed 404 before CAS
completion. Cron and the media worker never receive Auth admin access.

Missing per-account Apple token material uses an explicit legacy-action flag;
it does not pretend Apple access was revoked or indefinitely block WALI deletion.
Global missing Apple configuration remains retryable. Keys are loaded only when
a prepared encrypted binding actually needs revocation.

## Status and retries

`account-deletion-receipt` accepts only the `account_deletion_receipt.v1` envelope,
request UUID and `capability` containing 64 lowercase hex characters. No account
selector or session is needed. The server hashes decoded bytes and exposes only
status/stage, request/completion/expiry times, safe retained categories and the
Apple-action flag. Limit: 120 checks/hour per valid capability. Do not log, export
or put the capability into URLs.

Pending receipt access does not expire during a long hold. Durable completion
atomically starts the 30-day server confirmation window; reads and replays cannot
extend it. A bounded daily purge removes expired capability records separately
from justified audit evidence. The native app keeps a received minimal completion
confirmation until dismissed and removes the live capability. Expired access is
not proof of completion. This window is not an audit-retention period or SLA.

The independent one-minute dispatcher admits one live 60-second run and no more
than one new run/minute. Each Edge run is serial, at most four jobs/45 seconds,
with eight-second DB/provider bounds and three-minute per-job leases. Retry
delays are 1, 2, 4, 8, 15 minutes, then at most hourly after eight consecutive
failures. A crash retains exact checkpoints for lease-expiry reconciliation.
Provider success followed by a lost reply must reconcile that same identity;
it cannot select another account or claim premature completion.

## Exact-object cleanup and holds

Deletion includes public media/poster/thumbnail objects and private staged media
from ordinary and curated submissions. Private intents bind the consented
request, exact bucket/path/digest and owning releases. Existing references and
new promotions share a digest fence. Storage deletion requires the matching
worker lease; it grants no arbitrary bucket access. A shared immutable object
referenced by an independently active publisher stays protected with a held
outcome. Do not report that URL erased.

Public listings and personal manifest projections cease to be eligible when the
profile freezes. Existing copyright-case updates and removal use the same lock
order; no new hold category is introduced. During an applicable hold, public
bytes can be removed only when verified canonical evidence remains privately.
Otherwise the request stays held; never claim erasure while bytes remain. Private
rights/audit evidence, source files, local wallpapers and previously downloaded
copies are preserved. Signed release bytes are not rewritten, and account
deletion does not issue security revocations.

The inventory records actual retained categories. Legal basis, retention periods,
backup expiry and operator response promises require their own approved facts;
this mechanism does not establish them.

## Activation and recovery

Migration015 is inert: `automatic_account_deletion_enabled=false`, no embedded
secret, no historic-consent backfill and no Cron activation. After coordinated
checks, the reviewed activation packet installs the independent Edge
`WALI_ACCOUNT_DELETION_DISPATCH_TOKEN` and protected scheduler
`wali_account_deletion_dispatch_token`, schedules only
`wali.dispatch_account_deletion_tick()` each minute plus a bounded daily receipt
purge, then enables admission. This token is not the publication token, an Auth
key or the separately held worker credential issuer.

For automatic requests, existing admin endpoint `operation=retry_automatic`
requires a real admin/fresh AAL2 and current request revision. It can reset the
same job's backoff only with no live lease; it cannot skip object or Apple checks.
Historic `account.v1` requests retain admin `finalize_identity` recovery and are
not silently admitted into the new authority.

Rollback disables new v2 admissions/dispatch claims and unschedules only this
dispatcher. Preserve checkpoints, immutable object fences and receipt access.
Never reactivate identities, restore erased UGC, clear user data to hide failures,
or bypass a live lease. A disposable email/Apple account needs separate explicit
authorization before any real deletion test; the publishing owner is never an
acceptance fixture.
