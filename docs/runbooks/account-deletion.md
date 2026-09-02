# Marketplace account deletion

**Owner:** privacy operator
**Approver:** security responder for exceptional holds

**Implementation status:** source-complete locally, not deployed or exercised
end to end. The development client includes fresh-TOTP request/status UX. The
local backend includes queue, cleanup, database pseudonymization, durable Auth
session revocation, and an admin-only `finalize_identity` operation. A dedicated
operator identity/trigger, hosted credentials, authenticated completion
notification, retry rehearsal, and end-to-end evidence do not yet exist. A
request at `awaiting_auth_cleanup` with `operator_cleanup_required` is a
nonterminal operator gate and must never be shown as completed.

1. Require a fresh authenticated request and issue an opaque receipt. Support
   idempotent retries and reject requests for another user.
2. Revoke durable Supabase Auth sessions plus creator/moderator grants, verify
   the session-family deletion, freeze new uploads, and review any open
   legal/security hold. Never treat access-token expiry alone as revocation.
3. Delete eligible private upload/export objects unless a documented hold
   applies. Include rights proofs only after that separate workflow is enabled.
   Anonymize or delete profile, favorites, saves, follows, and bounded event
   identifiers according to the data inventory.
4. Delist creator items when rights no longer permit distribution. Preserve
   immutable releases only when a continuing license and policy permit it;
   remove personal attribution where possible and required.
5. After a real backup system exists, queue deletion into backup expiry rather
   than editing immutable historical backups. Record only receipt, status,
   policy version, completion time, and any legally required retention category.
6. From a dedicated admin/operator session with fresh AAL2, call
   `request-account-deletion` using `operation=finalize_identity`, the deletion
   receipt, its expected revision, and a unique idempotency key. The Edge
   executor soft-deletes the provider identity, verifies the provider result,
   then atomically marks the receipt completed. The user-facing app must only
   learn completion from a later authenticated status response.
7. On timeout or retryable provider failure, keep the receipt at
   `awaiting_auth_cleanup`; retry the same logical operation with the same
   idempotency key after checking the current receipt revision. On revision
   conflict, reload status before retrying. A 404 or already-soft-deleted
   identity must be reconciled through the same finalizer, never by manually
   editing the receipt.
8. Notify completion through an authenticated product channel and retain only
   the policy-approved receipt fields. This notification channel and its hosted
   reconciliation job remain deployment gates. Never request a password,
   authenticator code, admin JWT, or service token over email or support chat.

The operator credential must live only in the production secret manager and
must not be shipped in the macOS app, CI artifacts, logs, issue attachments, or
the repository. Production enablement requires a successful soft-delete,
idempotent retry, already-deleted reconciliation, and failure-recovery drill in
staging with evidence attached to the release record.

The operation affects server-side marketplace data only. It must not delete
local wallpapers or settings from a Mac.
