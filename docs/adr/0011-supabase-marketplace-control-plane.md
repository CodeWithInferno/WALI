# 0011: Use Supabase as the marketplace control plane

- status: accepted
- date: 2026-09-01
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01

## Context

WALI needs accounts, creator submissions, moderation, catalog discovery,
immutable media delivery, and auditable publication without operating a fleet
of public services. The local wallpaper engine must continue to work offline
and must not inherit backend credentials or backend authority.

## Decision

Supabase is the only public marketplace control plane. Separate staging and
production projects provide Auth, Postgres, Storage/CDN, Queues, Cron, and
short-lived Edge Functions. Authoritative records live in a non-exposed
`wali` database schema. The Data API exposes only the reviewed views and
bounded RPCs documented in `docs/api/catalog-v1.md`,
`docs/api/creator-v1.md`, and `docs/api/moderation-v1.md`.

One replaceable Linux worker consumes queue leases and moves opaque bytes
between private Storage and fresh, rootless media sandboxes. It has no public
listener and is not another product backend. Long media work, model inference,
and polling never run in Edge Functions. No GCP runtime, Kubernetes, Redis,
Kafka, or search cluster is introduced for the beta foundation.

The macOS app contains only the public Supabase URL and publishable key. A
service-role key, database password, catalog signing private key, worker
credential, or moderator secret is never embedded in the application, a
fixture, a log, or the repository.

## Invariants

- Staging and production have distinct project IDs, data, buckets, queues,
  credentials, signing keys, and worker service accounts.
- Schema changes are ordered migrations; production is never the place where
  a migration is authored or tested.
- Every authoritative table has RLS enabled even when it is outside the
  exposed schema. Default grants to `anon` and `authenticated` are revoked.
- The public schema is an allowlist, not a mirror of internal tables.
- Privileged functions re-check current database roles; JWT display claims are
  never the final authorization source.
- The service-role key stays in bounded server secret stores and is never used
  for ordinary public catalog reads.
- Database PITR does not substitute for object backup. Referenced catalog
  objects and protected legal evidence have an independently verified backup.
- WALI's installed local library continues to render while Supabase or the
  worker is unavailable.

## Alternatives considered

- A bespoke API, database, queue, object store, and auth service would add
  operational surface without improving the beta's product boundary.
- Running Supabase on the existing worker VM would couple public state to media
  processing and complicate replacement and recovery.
- A multi-cloud or microservice deployment would make a small app-only
  marketplace harder to understand and operate.
- Direct raw-table exposure would reduce boilerplate but make least privilege,
  API stability, and data minimization materially weaker.

## Consequences

The system has one managed control plane and one replaceable media plane.
Supabase availability and platform changes become external dependencies, so
API contracts, migration replay, exports, object backup, and restore drills
are release requirements. Contributors can still run the backend locally with
the Supabase CLI and a no-op classifier.

## Migration and rollback

Marketplace functionality is additive and stays feature-gated until its RLS,
Storage, queue, and restore gates pass. A failed rollout disables creator
uploads and catalog network access without changing installed local media. A
project move replays migrations, restores immutable objects, imports bounded
data, rotates environment credentials, and changes only environment-specific
client configuration.

## Verification

- Architecture policy rejects marketplace network/runtime code before this ADR
  and the corresponding compatibility entries are accepted.
- Local reset replays every migration and synthetic seed without production
  credentials.
- RLS tests exercise visitor, user A, user B, creator, moderator AAL2, admin
  AAL2, and worker access.
- Restore evidence covers Postgres, Storage objects, signing public-key history,
  and environment configuration.
