# Automatic publication v1

Accepted under ADR 0025. This is a server workflow, not a user or worker
signing capability. Ordinary and staff-curated admissions keep their actual
rights document kind/version and actor authentication.

## Flow and authority

Completion binds actual metadata and rights, then the existing hostile-media
worker verifies all four artifacts for the current generation. The ready
transition inserts one durable `wali.automatic_publication_jobs` row per
submission/generation. A lease holder rechecks account, consent, license,
category, rights, byte verification and visibility, and writes an immutable
`automatic_publication_decisions` snapshot with explicit system authority.
No human moderator/AAL2 claim is manufactured.

`POST /functions/v1/automatic-publication` accepts exactly
`{"api_version":"publication_worker.v1"}` with header
`x-wali-publication-token`. The dedicated 32-byte hex credential is compared
before any database access. User tokens cannot select a job or actor. Each
invocation handles at most four jobs while its 45-second admission budget
remains; each database HTTP operation has a 10-second timeout. Leases last
three minutes. A crashed invocation is recovered by lease expiry.

The dispatcher uses only these service-only RPCs:

- `wali_edge_claim_automatic_publication_v1()` → null or a job/lease pair.
- `wali_edge_prepare_automatic_publication_v1(job_id, lease_token)` → promotion
  wait, exact signing snapshot, or a consumed publication receipt.
- `wali_edge_finalize_automatic_publication_v1(job_id, lease_token, manifest_body,
  metadata_body, manifest_digest, metadata_digest, manifest_signature,
  signing_key_id)` → committed publication receipt.
- `wali_edge_finish_automatic_publication_v1(job_id, lease_token, outcome,
  safe_error_code)` → acknowledgement; completion requires committed publication.

Existing promotion leases independently verify copied immutable bytes. Edge
signs with the existing online-primary custody and canonical signing helper.
The final transaction revalidates the decision, revisions, rights snapshot,
artifact set and signature envelope. Lost final replies replay a consumed
intent without another signature/publication. A genuine human publication of
the same generation can satisfy the queued job without another policy decision.
Failure to acknowledge leaves a queued retry or an expiring lease. Retries are
bounded to 12 attempts, with delay capped at five minutes; exhausted work stays
visible and can be retried by the actual creator.

Human publication endpoints still require genuine moderator/admin AAL2 and an
independent review. Reports, revocation and delisting remain unchanged. A system
policy decision does not certify legal rights or content safety. Classifier
absence is explicit; a valid creator-selected category remains required.

## Deployment

Apply migration `202609130001`, then deploy `create-upload`, `complete-upload`,
`creator-command`, `submit-wallpaper`, `publish-release`, and
`automatic-publication` from the matching source. Its completion draft is an
intentional coordinated client change. Activate the actual current Creator
Terms (`2026-09-12`) and eligible licenses with their reachable terms URLs.

Reuse the existing `WALI_CATALOG_SIGNING_KEY_ID`,
`WALI_CATALOG_SIGNING_PRIVATE_KEY_PKCS8`, and `WALI_APPROVED_CDN_HOST`; never
provide signing keys to the media worker or client. Supply the same random
32-byte hex value as Edge `WALI_AUTOMATIC_PUBLICATION_TOKEN` and Vault secret
`wali_automatic_publication_token`. No credential belongs in source, command
arguments, receipts or logs.

The migration registers the minute cron `wali-automatic-publication`, calling
private `wali.dispatch_automatic_publication_tick()`. It uses pg_net only when
jobs are due and the Vault token and exact Supabase project origin are valid.
No token means no network call. The origin must be
`https://<20-character-project-ref>.supabase.co`; the fixed catalog Storage
suffix is removed before validation. This follows Supabase's documented
[Vault/cron scheduling path](https://supabase.com/docs/guides/functions/schedule-functions).
Service-role Edge cannot invoke the Vault reader. Runtime/HTTP bodies contain
no user identity; the response contains aggregate counts only.

A deployment receipt is not product acceptance. Prove the real authenticated
upload, worker processing/promotion, signed publication, public Browse, and
native verified installation separately. Rollback must drain or pause the
scheduler before removing this workflow; do not delete immutable published
releases, user media, decisions or queued jobs.
