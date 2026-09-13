# Account privacy and Apple binding

Accepted ADR0029 governs migrations `202609130014_apple_authorization_custody.sql`
and `202609130015_autonomous_account_deletion.sql`. Existing `account.v1` recovery
remains available. This contract describes implemented boundaries, not provider
configuration, deployed jobs or a completed deletion claim.

## Request and status

`request-account-deletion` accepts the existing bounded JSON envelope with
`api_version: account.v2`, `request_id`, `idempotency_key`,
`expected_profile_revision`, `confirmation: DELETE MY WALI`,
`status_capability_hash` (64 lowercase hex SHA-256) and `policy_version: 2026-09-13`.
Real session authentication, current subject, confirmation, quota and fresh AAL2
remain required. `wali_edge_request_account_deletion_v2` atomically admits that
consented request to automation. Older requests are not silently backfilled.
Existing session-revocation checkpoint completes before native scoped sign-out.
Acceptance/pending, holds, retry, Auth cleanup and durable completion are distinct.

The foreground generates 32 random bytes and stores the capability before the
request in edition/project-isolated Keychain, separate from Auth storage. Local
records are bounded to eight and 64 KiB. Sign-out cannot remove them. A later
account cannot replace the request identity. `account-deletion-receipt` is POST
only, exact JSON `api_version: account_deletion_receipt.v1`, `request_id` and
`capability` (64 hex characters), at most 1 KiB. The hash selects one receipt;
request ID is correlation only and confers no access. No bearer session survives
or is needed. The service-only `wali_edge_account_deletion_receipt_v1` returns
only state/stage, request/completion/expiry timestamps, bounded retention categories
and `apple_action_required`; it never returns an account ID or content. Response
is at most 4 KiB, checks at most 120/hour per valid capability. Unknown/expired
capabilities do not expose account existence.

Pending status has no expiry; durable completion sets exactly `completed_at +
30 days`, unaffected by reads or retries. A bounded daily pass purges expired
status hashes. Foreground receipt checks stop when hidden, back off five seconds
to one minute, and resume after relaunch. Completed confirmation replaces the
capability with minimal local outcome until dismissed. Expiry is not proof of
completion. The 30-day access window is neither an audit period nor a deletion SLA.

## Apple authorization

`bind-apple-authorization` accepts exact JSON up to 24 KiB:
`api_version: apple_authorization.v1`, `request_id`, `client_id`, `id_token`,
`nonce`, `authorization_code`. The only client IDs are `com.wali.store.WALI` and
`com.wali.store.development.WALI`. The Edge handler authenticates the actual
candidate WALI session, verifies Apple's issuer/audience/nonce/signature, binds
its linked Apple subject, and exchanges only at Apple's fixed endpoint. Native
admission waits for successful binding; failure preserves the prior account.

Named service-only RPCs are `wali_edge_begin_apple_authorization_v1`,
`wali_edge_complete_apple_authorization_v1`, and
`wali_edge_cancel_apple_authorization_v1`. Per-account/client leases and revision
checks fence code reuse and concurrent deletion. AES-GCM ciphertext and key version
stay private; neither clients, exports, logs nor media workers receive tokens.
The fixed per-client signing inputs are `WALI_APPLE_STORE_KEY_ID` and
`WALI_APPLE_STORE_PRIVATE_KEY_P8` for Store, and
`WALI_APPLE_DEVELOPMENT_KEY_ID` and `WALI_APPLE_DEVELOPMENT_PRIVATE_KEY_P8` for
Store development. The encryption inputs remain
`WALI_APPLE_CREDENTIAL_KEY_VERSION` and `WALI_APPLE_CREDENTIAL_KEY_BASE64`.
Separate existing primary App IDs use their matching key; no audience or grouping
is changed. These names document custody, not provisioning or secret values.

After confirmed Apple revocation, checkpoint and purge material. A legacy account
without usable material receives truthful manual Apple revocation instructions;
that fallback does not indefinitely block WALI data deletion.

## Autonomous finalizer

`automatic-account-deletion` accepts POST with only
`api_version: account_deletion_worker.v1`, at most 1 KiB, and a dedicated 256-bit
`x-wali-account-deletion-token`. Publication tokens, user JWTs, public keys and
body selectors cannot substitute. Three Edge routes above use `verify_jwt=false`
only because each validates its own exact capability/session boundary in the
handler; this is not anonymous database authority. No secret is embedded in SQL.

The approved service-only RPC closure is:
`wali_edge_begin_account_deletion_dispatch_v1`,
`wali_edge_end_account_deletion_dispatch_v1`,
`wali_edge_claim_account_deletion_v1`,
`wali_edge_prepare_automatic_account_deletion_v1`,
`wali_edge_checkpoint_account_apple_revocation_v1`,
`wali_edge_authorize_account_identity_deletion_v1`,
`wali_edge_finalize_automatic_account_deletion_v1`,
`wali_edge_retry_account_deletion_v1`, and the existing human recovery fence with
`wali_edge_retry_automatic_account_deletion_v1` (actual admin/fresh AAL2).

A singleton allows one new run/minute with a 60-second run lease; each invocation
processes at most four receipts serially for 45 seconds. Receipt leases last
three minutes; DB/provider calls are bounded to eight seconds. Prepare chooses
only due policy-admitted requests, derives the identity from their durable request,
and checks sessions, holds, current cleanup and publication freeze. Every provider
phase and checkpoint binds current run/job/lease/revision. Retry backoff is 1, 2,
4, 8, then 15 minutes; after eight consecutive failures retry at most hourly.
Timeout, lease loss and provider response alone never mark completion.

Exact digest/reference-fenced intents authorize hosted object cleanup, including
public catalog bytes. Shared lawful references and restricted holds are explicit
exceptions; local downloaded copies remain unchanged. Apple revocation precedes
same-subject Supabase soft deletion using JSON `should_soft_delete:true`, bounded
fixed endpoints and independent verification. CAS records completion only when
all prerequisites/checkpoints still agree. Manual recovery retains real AAL2.

Rollback stops new scheduler admission and preserves existing status access,
leases/checkpoints and required recovery evidence. It never recreates deleted
identities, restores removed UGC, weakens personal blocks or exposes a generic
provider-admin API. Production activation requires the reviewed exact deployment
packet; source tests are not evidence of actual privacy completion.
