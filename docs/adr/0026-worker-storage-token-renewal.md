# 0026: Renew worker Storage credentials through the authenticated database session

- status: accepted
- date: 2026-09-13
- owner_role: security_responder
- accepted_by: project_owner
- approval_reference: owner completion directive on 2026-09-13 following the concrete 15-minute Vault renewal proposal; implementation authorized in the active release task, hosted activation and provider proof recorded separately

## Context

The control worker loads one Storage JWT from its protected environment and
retains it for all HTTP requests. It has no renewal path. Expiry therefore
interrupts Storage even while its dedicated database login remains healthy.
Production currently uses HS256; increasing token lifetime does not solve this.

## Decision

Add a private, no-argument `wali.renew_storage_worker_token()` SQL function.
It maps the real `session_user` (both role OID and name) to one enabled worker ID,
requires the existing restricted LOGIN/NOINHERIT member of `wali_worker`, and
rejects privileged roles and Data API sessions. Only `wali_worker` can execute it;
there is no public RPC, user JWT, caller-selected identity, role, expiry or claim.

A deployment-owned binding identifies the exact project Storage origin and a
Vault reference to the already accepted HS256 issuer secret. The function uses
existing pgcrypto HMAC-SHA256 to issue only role `wali_storage_worker`, audience
`authenticated`, that worker ID, fixed issuer, and a **15-minute** lifetime.
The secret never leaves Vault through this interface. It returns only
`access_token`, `expires_at`, and `worker_id` over the existing verified TLS
PostgreSQL connection. Existing path/lease/generation Storage RLS is unchanged.

Explicit `WALI_STORAGE_AUTH_MODE=database_renewal` replaces the static token
setting for opted-in deployments; mixed inputs fail. Existing static mode stays
available for a reviewed rollback without extending any token. The worker caches
only the issued token in memory, refreshes with five minutes remaining, serializes
concurrent refreshes, and bounds issuance calls to ten seconds. Failed renewal
uses an unexpired cached token only while at least 30 seconds remain, then fails
closed. Failed issuance is backed off for 30 seconds. Storage-dependent queue
reads pause without claiming jobs when credentials are unavailable; readiness
reports a safe unavailable state. Existing in-flight failures retain normal
lease/retry recovery. There is no credential polling thread or new network host.

## Invariants

No project/service/issuer key reaches the worker or media sandboxes. No token,
secret, object path, or raw database exception enters logs. The binding table and
Vault material are deployment-only, with no worker/user table access. Disabling
a binding stops new issuance; outstanding tokens expire within 15 minutes and
still require an active exact-path lease. No immediate revocation is claimed.

## Alternatives considered

Longer JWTs or scheduled manual VM restarts retain the outage and enlarge
credential exposure. A new public token broker adds another network credential
and service. The existing authenticated database session already proves the
restricted machine identity and supports a bounded private function.

## Consequences

Vault gains custody of the existing project-wide HS256 issuer material. Although
the function issues one narrow role, compromise of that issuer secret can sign
broader claims; activation therefore needs explicit owner approval and verified
Vault/function grants. This supports the current issuer only, not an automatic
migration to asymmetric Auth keys. Database restores must rebind role OIDs;
missing/stale bindings fail closed.

## Migration and rollback

Migration `202609130005` creates an inert binding table and function; it creates
no login, binding, secret, or enabled worker. After focused tests and the approved activation guards,
the operator provisions the exact Vault reference/binding, deploys the reviewed
binary and explicit auth mode, then proves a real renewal across two token
windows and a scoped Storage operation. Rollback restores the prior immutable
worker snapshot with a still-valid scoped token and disables issuance; it never
lengthens a token, deletes user data, or changes media sandbox policy.

## Verification

Use synthetic issuer material and a rollback-only local restricted-login fixture
to verify signature/claims, login binding, privilege denials, disabled/stale
bindings, and non-disclosure. Go tests cover refresh before expiry, concurrent
single issuance, cancellation/timeouts, expired-token refusal, safe retry/backoff,
no unauthorized HTTP request, and queue admission/readiness. Re-run affected
Storage/config/queue tests; hosted renewal remains separate acceptance evidence.

References: [Supabase signing keys](https://supabase.com/docs/guides/auth/signing-keys),
[Vault access](https://supabase.com/docs/guides/database/vault),
[PostgreSQL identities](https://www.postgresql.org/docs/current/functions-info.html),
[HMAC primitive](https://www.postgresql.org/docs/current/pgcrypto.html).
