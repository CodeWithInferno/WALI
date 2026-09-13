# 0029: Autonomous account deletion and signed-out status

- status: accepted
- date: 2026-09-13
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner approval of exact privacy SCOPE version 3 on 2026-09-13; reply call_iEZMKltIq60K30S3aWTn4SjK explicitly authorizes implementation and deployment
- related: ADR0011, ADR0012, ADR0014, ADR0019, ADR0025

## Context

The product must complete ordinary deletion without requiring its owner to run a cleanup command. Current processing reaches `awaiting_auth_cleanup`; only a genuine admin/fresh-AAL2 finalizer removes the Auth identity. Normal authenticated status stops working after the request revokes sessions. The merged native pending/sign-out fix and deployed provider-body fix do not close these gaps.

Add a named system authority within the existing Supabase/Edge control plane. Human administrative actions keep AAL2. No actor, consent or MFA event is fabricated. This replaces the operator-only delivery policy in the deletion runbook; it preserves the accepted local-library, private-schema and signed-byte invariants. This adds a named system finalizer; existing human administrator and moderator actions retain their AAL2 requirements. It does not change local-media ownership or authorize rewriting signed release bytes.

## Decision

### Request, consent and identity

Keep current real requester authentication, explicit confirmation, expected profile revision and fresh-AAL2 checks unchanged. A new versioned request binds the verified subject, policy version, idempotency identity, status-capability hash and admission to `automatic_account_deletion_v1`. The caller never selects a subject. Atomically freeze the account's new publication/interactions and retain the existing durable session-revocation checkpoint.

Return accepted/pending, never completed. The foreground persists a 256-bit status capability before submitting its hash commitment, so it can find the accepted operation after a lost response and revoked session. Same-operation retry reuses the commitment; changed-payload idempotency reuse conflicts. Do not silently backfill old requests into automation: any historic consent/policy admission requires an explicit reviewed migration; existing manual recovery remains available.

### Independent scheduler capability

Add `automatic-account-deletion`: POST only, exact body `{ "api_version": "account_deletion_worker.v1" }`, maximum 1 KiB. Require a new random 256-bit secret in `x-wali-account-deletion-token`, fixed-length validated and compared in constant time before any RPC. Anonymous/publishable credentials, user JWTs and the publication token are rejected. No user ID, deletion selector, arbitrary operation, SQL or URL is accepted.

Secret names: Edge `WALI_ACCOUNT_DELETION_DISPATCH_TOKEN`, protected scheduler `wali_account_deletion_dispatch_token`. A dedicated private Cron invoker reads only this value and calls the fixed production endpoint every minute. No `anon`, `authenticated` or `wali_worker` execute/read grants. This random dispatch secret is unrelated to—and does not approve—the held worker HS256 issuer/Vault binding.

Only Edge uses the existing server Auth admin credential for the exact prepared identity. Cron, the Mac and the media worker never receive it. Do not reuse `WALI_AUTOMATIC_PUBLICATION_TOKEN`, mint admin JWTs, create a new platform role, or claim the system action is a human AAL2 action.

### Private job and exact execution limits

Add `wali.account_deletion_finalization_jobs`, one row per request: request/policy binding, stage, revision, lease token/expiry, attempt counter, next-attempt time, bounded safe error and timestamps. RLS/default-deny grants; no direct client or media-worker access. Named service-only claim/prepare/checkpoint/finish RPCs are the only access. Add one private singleton `wali.account_deletion_dispatch_state` holding the global run lease and last-start time. A begin-dispatch RPC admits at most one new run per minute and one live 60-second run lease. Repeated/replayed scheduler calls return busy/no-work; they cannot multiply provider concurrency. Receipt claims/checkpoints also bind the current run lease. Neither table is part of a public catalog projection.

Claim takes no subject selector. SQL selects only due, automation-admitted requests whose consent, revoked sessions, current rights/legal holds and verified private/public cleanup pass. Use row locks/`SKIP LOCKED`; one live **three-minute lease** per receipt. Prepare derives its Auth subject exclusively from the same durable request. Every later call is bound to job, lease and revision. No generic Auth-admin RPC is added.

Each **one-minute** invocation processes at most **four receipts, serially, for 45 seconds**. Bound each DB/provider call to **eight seconds**; start a provider phase only with enough remaining budget and support cancellation. Lease loss stops further writes. Overlapping invocations cannot process one live receipt. These are engineering limits, not a one-minute completion promise.

Transient failures back off **1, 2, 4, 8, then 15 minutes**. After eight consecutive failures, retry at most hourly and expose a safe attention state. A real prerequisite change or authorized recovery can reset backoff. Keep one current counter/next-attempt record, not unbounded per-tick history. A bounded reconciliation requeues expired leases and newly satisfied requests. No foreground app or routine manual queue polling is required. Global missing provider configuration, applicable holds and identity mismatch stay nonterminal; they never become fake completion. Missing per-account Apple token material follows the documented fallback below and does not independently hold WALI data deletion forever.

### Irreversible provider stages and recovery

1. Prepare rechecks consent, session revocation, cleanup, publication freeze and holds under the shared account/deletion lock order. Commit the finalization authorization checkpoint before the provider call. A hold ordered before this checkpoint wins; a later hold cannot undo a completed provider operation and must protect any still-required restricted evidence.
2. Revoke each applicable stored Apple authorization for this exact account/client. Atomically checkpoint its safe result and purge the token. The legacy no-token fallback is separate from confirmed Apple revocation.
3. Reuse the reviewed Supabase adapter: exact prepared subject, JSON `should_soft_delete:true`, redirects denied, bounded response and same-subject provider verification. No identity can be supplied in the scheduler body.
4. Complete by CAS only when request/job/lease/revision and every required checkpoint still agree. Audit authority is `automatic_account_deletion_v1`; no invented actor/MFA. Manual admin+AAL2 recovery uses the same request fence.

Apple success followed by checkpoint failure replays the same token revocation. Supabase success followed by a lost DB reply re-verifies the same bound identity. Already-deleted/completed replay reconciles the existing request, never selects a replacement user. Queue ACK, timeout, provider failure, lease loss and `awaiting_auth_cleanup` are not completion.

### Pending status and thirty-day completion receipt

Generate 32 random bytes in the foreground and persist them before submission in edition/project-isolated Keychain storage, separate from the Auth session cleared by sign-out. Server stores a unique SHA-256 commitment bound to that one request. **The capability remains valid while the request is nonterminal; the same transaction that records durable completion sets expiry to exactly completed_at + 30 days.** Pending expiry is null, not a rolling timestamp that requires the app to renew. Retries, reads, provider intermediate successes and completion replays cannot extend this deadline. The minimum terminal receipt is retained through that deadline even if the account/profile rows are already removed; private identity mappings are purged as their cleanup purpose ends.

`account-deletion-receipt` is a separate exact versioned HTTPS POST. Capability is in the bounded body, never URL/log/export. Hash lookup chooses one receipt; no account selector is allowed. Maximum request **1 KiB**, response **4 KiB**, **120 checks/hour** per valid capability plus existing anonymous abuse limits. Return only safe request state/stage, request/completion/expiry times, approved retention categories and Apple legacy-action flag. No user/creator/Apple identifier, email, export, session, delete/cancel/finalize or account-recovery authority. Invalid capabilities must not reveal account existence.

Native receipt checks are foreground-only, resume after relaunch/lost response, back off from five seconds to one minute, and stop when hidden, cancelled, terminal or expired. A verified completed response is persisted as a minimal local confirmation (completion time, safe outcome and approved retained categories only), displayed in the deletion receipt surface and retained until the person dismisses it; this is not continued server access or an account recovery key. The client removes the live capability on completed confirmation or expiry. Pending receipts survive sign-out and app closure without renewal. Receipt presentation stays separate from a subsequently signed-in person's private account state.

Purge expired capability hashes and their status-only projection in the next bounded daily pass, independently of any justified restricted audit record. The **30-day post-completion window is not an audit-retention period or deletion SLA**. A hold that clears after 30, 90 or more days leaves the receipt usable until actual completion and for the same 30-day confirmation window afterward. The cost is the owner-approved request-lifetime exposure of a very narrow bearer capability; its hash/state are kept only because the consented operation remains unfinished. No extra email retention, notification provider, rolling renewal secret or ordinary operator action is needed.

This cannot promise that a person absent for more than 30 days after completion will still retrieve the server result. The confirmation surface explains the window before submission and shows the exact deadline once completed; after expiry it reports only that status access ended, never infers completion. Local confirmations already obtained remain available until dismissed. Apple requires completion confirmation but does not prescribe this technical retention window; actual in-app completion/relaunch acceptance must establish the mechanism before making a compliance claim. Any later requirement for out-of-app notification would need its own minimal contact/delivery design, not an invented SLA or silent retention extension.

### Hosted UGC cleanup

Bind removal to all publisher-owned ordinary and curated submissions/releases: public entries, public personal attribution/manifest projections, canonical media, posters and thumbnails. Current profile status hides listings but leaves public object URLs; the present cleanup allowlist excludes `catalog-public`.

Add exact-object intents containing bucket/path/digest, owning releases, reference revision, approved reason and verified outcome. Recheck all live references and serialize new reference/promotion admission against the same digest deletion fence. Only a committed, unheld intent grants deletion of that exact object; no broad bucket deletion or caller-chosen path. Media-worker authority may cover those storage intents, never Auth.

Do not erase another independently authorized publisher's bytes. A shared immutable public URL cannot be called fully erased: separate remaining lawful delivery references without rewriting signed bytes, or preserve an explicitly disclosed justified exception pending policy resolution. A continuing license alone is not a blanket exemption for deleted-user UGC. Freeze/recheck publication and new delivery so late worker/promotion results cannot revive it.

Preserve only minimum justified private audit/rights/hold evidence, with an approved category and period. Holds do not justify continued public distribution. Local wallpapers, source files and other users' already downloaded copies remain untouched; ordinary account/policy removal does not misuse security revocations to erase local media.

### Apple binding and custody

For new Apple accounts, validate native authorization-code/token material against a real WALI session and its exact linked Apple subject; verify issuer, audience, nonce and signature, and exchange only at Apple's fixed endpoint. Encrypt account/client-bound revocation credentials with key version. No client read, raw-token export/logging or arbitrary subject. Revalidate on async completion and handle native credential-revoked notifications without clearing another account.

Scope: Apple team **UH5Z2K4G9H**, existing foreground IDs **com.wali.store.WALI** and **com.wali.store.development.WALI**, Supabase **afgxvhhubqzgpijcstsv**. Inventory public key eligibility, then select/create only the necessary Apple key bindings and record exact key IDs/secret locations before provisioning. Keys/tokens stay in the auth Edge boundary. No Service ID, callback, extra audience or media-worker access. Prior Apple-provider enablement did not authorize this custody.

Derive revocation only from the same request/stored binding. Verify all applicable retained authorizations; do not assume an unrelated one was revoked. Purge token material after durable success. Active-account retention serves this lifecycle only; exceptional unresolved credential retention belongs in the reviewed policy, with no invented legal basis.

For existing accounts without usable token/code material, follow Apple's documented fallback: complete WALI data deletion, provide manual Apple access-revocation instructions and handle its native notification. Do not indefinitely block WALI deletion or claim Apple authorization was revoked. This recovery exception does not replace new-account token handling.

## Invariants

- Only a real consented request with satisfied prerequisites can authorize a provider operation; never a caller-selected identity.
- Scheduler, status, user and publication capabilities are non-interchangeable.
- Auth admin credentials remain Edge-only; human recovery retains actual admin+AAL2.
- Holds, live object references, signed-byte integrity and local-library ownership survive the change.
- Pending, attention, receipt expiry and completed deletion remain distinct.
- Engineering intervals imply no staffing, legal obligation, backup availability or SLA.

## Alternatives considered

Manual queue processing conflicts with the ordinary autonomous product goal; retain it only for recovery. Reusing publication credentials couples unrelated destructive authorities. Worker Auth admin access unnecessarily crosses the media boundary. A UUID/revoked JWT is not a receipt secret. Expiring access from acceptance can strand a valid held request before completion. Keeping status-only access through the unfinished request and for 30 days afterward is simpler than a second recovery key, periodic renewal or retaining email solely for notification. Indefinite post-completion access would conflate audit storage with access authorization.

## Consequences

Ordinary completion survives app closure without operator work. New private jobs/receipt hashes/Apple credentials, a scheduler secret, narrow RPCs/Edge routes, native receipt UI and exact-object cleanup need coordinated schema, privacy inventory and compatibility records. The existing Auth admin key is powerful: fixed-subject admission must be tested, not assumed.

Minimum audit is receipt/policy/timestamps and safe checkpoint/retention facts, with only the mapping needed for unfinished recovery. No raw token, email, Apple ID, source file or arbitrary provider error. Existing seven-year request-audit labels are not established legal obligations; minimization/retention approval remains separate from receipt expiry.

## Migration and rollback

The owner approved this decision on 2026-09-13. Add migrations, allowlists/contracts and tests together. Ship inert schema/code first: no automatic backfill, live Cron or embedded secret values in migrations/fixtures. Activate only the approved production bindings through a concrete reviewed execution packet after affected checks pass. The owner's implementation-and-deployment approval covers this bounded activation; it does not request deletion of an existing publishing account. Keep legacy requests/recovery compatible.

Rollback stops new scheduler claims/admission but preserves durable checkpoints and already-issued receipt access when safe. Never reactivate deleted identities, restore removed UGC, discard recovery evidence, drop personal-block enforcement or weaken manual authorization. Unrelated worker Vault/namespace, still/V2, registry, legal-publication and Store-submission holds remain intact.

## Verification

Focused proof must cover wrong/publication scheduler tokens, exact-body selector denial, real-role negatives, consent/hold/cleanup admission, both publication/removal race orders, one global minute/run lease plus per-receipt lease/stale CAS, scheduler flood/replay admission, manual-versus-system fencing, provider-success/lost-DB-reply reconciliation, retry/timeout/completed replay, shared-object protection, receipt recovery, a hold longer than 30 days with the app closed, completion-clock atomicity, non-extending replays, 30-day post-completion expiry, persisted local confirmation, relaunch/account switch and absence of secret data in responses/logs/exports.

Separately authorize a disposable email and Apple identity for real acceptance: consent → revoked sessions → verified private/public cleanup → Apple result/fallback → provider identity deletion → durable completed receipt after app closure/relaunch. Prove actual public-object removal/cache behavior before publishing that promise. Never use the real publishing owner as a deletion test subject.
