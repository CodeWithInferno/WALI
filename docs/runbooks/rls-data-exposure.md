# RLS or data-exposure incident

**Severity:** critical
**Owner:** security responder with database operator

1. Disable the affected public RPC/view/function grant or place the marketplace
   API behind maintenance mode. Do not drop evidence tables.
2. Reproduce with the least-privileged `anon` and `authenticated` roles in an
   isolated database. Record request shape and policy/function versions.
3. Determine exposed columns, rows, identities, time window, logs, caches, and
   object URLs. Signed object URLs are credentials and must be revoked.
4. Rotate affected secrets/tokens, expire sessions when needed, and make private
   objects inaccessible before restoring catalog availability.
5. Add a failing pgTAP test for the exact cross-user or anonymous read/write,
   then fix RLS plus grants/default privileges. Test security-definer search
   paths and direct table access separately.
6. Follow applicable notification and preservation requirements approved by
   counsel. Do not put personal data in an issue or release note.

Exit after the exploit path is closed, storage policies and all exposed RPCs
are re-audited, affected users/authorities are handled, and monitoring detects a
synthetic recurrence.
