# 0016: Collect only explicit marketplace engagement for ranking

- status: accepted
- date: 2026-09-01
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01

## Context

Discover, trending, related, and personalized surfaces need useful ordering,
but a wallpaper utility can easily become invasive by observing desktop state,
playback, displays, applications, locks, or filenames. Early opaque machine
learning would also make abuse and editorial failures difficult to diagnose.

## Decision

V1 ranking uses versioned, deterministic SQL features, approved taxonomy,
bounded text/visual embeddings, editorial inputs, and explicit marketplace
actions only. The accepted event set is `detail_view`, `install_requested`,
`install_succeeded`, `favorite_added`, `favorite_removed`, `saved`, `unsaved`,
and `report_submitted`.

Trending uses time-decayed unique eligible installs and saves plus quality and
health terms. Search combines full-text relevance, semantic similarity, and
quality. Related combines approved taxonomy and normalized embeddings. Discover
mixes editorial, trending, fresh, and—when the user has enough eligible
interactions—an expiring interest profile. Post-ranking rules enforce creator,
category, and visual diversity.

Raw events and aggregates remain private. Public counts have stable definitions.
V1 may show verified installs, saves, and favorites; it never claims live or
current usage. Personalization can be disabled, which deletes the derived
profile and prevents regeneration.

## Invariants

- WALI never uploads local filenames, source media inventory, display geometry,
  assignments, playback position/history, foreground applications, window
  titles, sleep/lock events, or other desktop observation for ranking.
- Event eligibility is server-owned. Client payloads cannot mark themselves
  unique, trusted, or ranking-eligible.
- Install success consumes a bounded one-use receipt after local verification;
  duplicate receipts and repeated user/release/day contributions do not rank.
- Creator self-interaction, suspended accounts, known abuse, impossible time
  bounds, and rate-limited floods are excluded from ranking inputs.
- Formula/model/taxonomy changes increment a revision and preserve reproducible
  feature snapshots; weights never change silently.
- Model suggestions do not become public tags or publication decisions without
  accepted policy or moderator action.
- A user with insufficient history or personalization disabled receives the
  same non-personalized editorial/trending/fresh mix.
- Operational logs use request IDs and safe codes; tokens, contact data, paths,
  raw rights evidence, and uploaded metadata are redacted.

## Alternatives considered

- Continuous playback/device telemetry could improve engagement estimates but
  violates the product's local-computing trust boundary.
- An opaque collaborative-filtering service is premature, hard to self-host,
  and difficult to audit for abuse and cold-start behavior.
- Raw total downloads are trivial to manipulate and favor old content forever.
- Editorial ordering alone is safe but fails to surface useful new and related
  work at marketplace scale.

## Consequences

Ranking remains understandable, testable, and portable to self-hosted Supabase.
It will initially be less individually optimized than a telemetry-heavy system.
Storage, aggregation, rate limits, retention, opt-out deletion, and public-count
definitions become explicit product contracts.

## Migration and rollback

Event schemas and formula versions are additive. A bad formula is rolled back
by activating the last recorded version and rebuilding snapshots from eligible
retained inputs. If aggregation is unavailable, clients use editorial ordering
plus publication time. Personalization deletion removes derived profiles; the
minimum operational/audit facts retained for security or legal obligations stay
documented separately.

## Verification

- Golden ranking fixtures reproduce search, trending, related, diversity, and
  cold-start order from recorded inputs.
- Abuse tests prove duplicate receipts, creator self-events, suspended users,
  floods, and ineligible events do not affect score.
- Data-inventory policy rejects an undocumented data category or retention
  behavior.
- Privacy tests and payload contracts reject device-local and free-form event
  fields.
