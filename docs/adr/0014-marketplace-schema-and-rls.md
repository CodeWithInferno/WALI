# 0014: Keep marketplace truth behind a private schema and explicit RLS API

- status: accepted
- date: 2026-09-01
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01

## Context

Marketplace records combine public catalog facts with private account,
submission, rights, moderation, security, and ranking data. Exposing tables as
an accidental API or trusting client-side roles would make authorization and
future schema migration unsafe.

## Decision

Authoritative tables live in the non-exposed `wali` schema. The exposed
`public` schema contains only versioned allowlisted views and bounded RPCs.
Every authoritative table enables RLS as defense in depth; default schema and
table privileges are revoked. Public contracts are documented independently
from storage tables.

Stable logical wallpapers have immutable published release editions. Creator
input, system-derived media facts, model suggestions, moderator decisions, and
publication facts are separate records. State transitions use expected
revisions, current processing generations, idempotency reservations, database
constraints, and append-only audit actions. Publication is one transaction
that accepts only the current approved generation, freezes release/artifact
claims, signs a canonical manifest, and advances `current_release_id`.

Moderator and administrator actions require a current role grant plus AAL2.
Service credentials are limited to named worker/function operations; they do
not weaken user-facing RLS contracts.

## Invariants

- `anon` and `authenticated` receive no implicit access to `wali` tables.
- Public views expose only published, active, non-sensitive columns and use
  invoker semantics where supported.
- Security-definer functions fix `search_path`, schema-qualify every object,
  perform no dynamic SQL, and re-check identity, role, AAL, revision, and state.
- A creator cannot read or mutate another creator's drafts, uploads, rights
  evidence, or processing records.
- A moderator cannot approve their own submission or publish a stale generation.
- Published release and artifact identity fields are immutable; changes create
  a new edition.
- Rights evidence, claimant/contact data, moderation private notes, raw uploads,
  idempotency internals, eligibility flags, and audit payloads never enter a
  public catalog response.
- Client enum additions decode as unknown and never grant capability.
- Every state transition, role change, rights decision, publication, suspension,
  key change, export, and deletion request has a bounded append-only audit fact.

## Alternatives considered

- Exposing tables directly through PostgREST would bind client compatibility to
  storage and make column additions easy to leak.
- A service-role API for all requests would bypass RLS and concentrate every
  authorization mistake in application code.
- Embedding all submission state in JSON would simplify early migrations but
  weaken constraints, indexes, review history, and stale-generation protection.
- Trusting custom JWT roles alone would delay revocation and permit stale
  privilege after a database role change.

## Consequences

Migrations and RPCs are more explicit, and database tests become part of every
backend change. The design supports public catalog evolution without exposing
internal storage. Operators must manage role grants, retention, and audit data
as security-sensitive records.

## Migration and rollback

Every migration is ordered, replayable, and forward-only in production.
Destructive changes use expand/backfill/verify/contract and retain a restore
path. Public API versions coexist during client migration. A failed feature
deployment can revoke grants or disable functions while preserving immutable
published releases and audit history. No migration may silently reset unknown
newer data.

## Verification

- pgTAP tests exercise the full authorization matrix and every privileged
  negative path.
- Schema policy rejects any exposed table/view/function absent from the API
  allowlist.
- Transition tests cover duplicate commands, stale expected revisions,
  stale worker generations, self-review, AAL1, revoked roles, and immutable
  publication columns.
- A fresh local database reset replays migrations and synthetic seed fixtures.
