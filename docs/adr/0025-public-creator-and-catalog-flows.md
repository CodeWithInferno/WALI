# 0025: Complete public Creator, automatic publication, and personalized catalog flows

- status: accepted
- date: 2026-09-12
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: repository-owner directive in the active product-flows conversation, 2026-09-12: any logged-in account can upload, uploads automatically appear, saves persist, completed downloads increase the displayed count, and Discover follows user categories; use production for local development and fix or remove blocking MFA
- supersedes: 0014, 0015, 0016, 0023
- supersedes_scope: 0014=mandatory_human_publication_approval,deployment_trust_bootstrap;0015=mandatory_human_publication_approval;0016=displayed_engagement_totals,explicit_category_preferences;0023=closed_public_creator_intake,mandatory_human_curated_review

## Context

The existing production configuration intentionally closes ordinary Creator
intake. Verified processing stops before a human review and a separately invoked
publication operation. Bookmarks have no Library reader, displayed counters use
historical aggregates, and Discover has no working preference writer. These
policies and incomplete integrations do not satisfy the owner's stated product.
The latest explicit directive authorizes the behavior described here. The owner
also explicitly approved the server-only automatic-publication scheduler token
and activation in the same conversation (reply "ye", 2026-09-12). It does
not authorize invented identities, authentication claims, content rights, or
verification results.

## Decision

An active account authenticated through the production account system can accept
versioned effective Creator Terms and use Creator at ordinary AAL1. Email accounts
must have verified ownership. MFA remains available for sensitive administrative
operations; it is not a prerequisite for publishing one's own uploads.

Admission binds actual creator-entered title, description, category, license,
rights attestation, rights holder, and required attribution before processing is
enqueued. Own-work and licensed-work attestations retain their distinct meanings.
The already authorized paid initial catalog keeps its negotiated license and
source/publisher credits. A publisher is not mislabeled the original author.

A durable server-owned publication workflow can publish an eligible submission
after independent media verification and affirmative rights attestation. It
records a system policy decision with its policy version and exact revision,
generation, artifact set, and rights snapshot. It does not insert a human review,
set a fake reviewer ID, or claim AAL2. The worker never receives signing keys or
human authority. A protected Edge dispatcher prepares immutable promotions, waits
for their verified completion, signs using existing signing custody, and commits
publication transactionally. Retries are bounded and idempotent, survive app
closure, and revalidate all bindings after asynchronous work. Explicit human
review and reports remain available; a human moderator cannot self-review.
Failures and rights/account restrictions remain actionable rather than becoming
published placeholders. For new processing messages, the bounded execution
budget starts at the first server-owned queue lease and is persisted on the
attempt. Queue wait does not spend encoding time; redelivery cannot reset the
budget. Already issued unmarked messages retain their original deadline. The
existing versioned deadline field carries the frozen value to the worker. Automatic verification is not claimed to prove legal
rights or content safety.

Library presents server-saved bookmarks alongside agent-owned downloaded media.
Only the agent owns local installed state. Displayed download totals count unique
successful install acknowledgements after verified local publication, including
the publisher's own real installation. They are distinct from ranking eligibility
and cannot be incremented by a request or failed download. Save/favorite totals
reflect currently active records. A per-wallpaper aggregate preserves completed
download totals after private authorization receipts are retired. Its only
fields are wallpaper identity and count: no installer identity, receipt, or
additional event history. Backfill counts only retained proven completions;
receipt consumption and aggregation remain one idempotent transaction. Server acknowledgements refresh visible values;
failed acknowledgement work is recoverable without duplicating counts. A bounded
foreground-owned acknowledgement outbox contains only subject, release, receipt,
digest, and idempotency bindings after agent-confirmed installation. It is separate
from agent-owned library state, scoped to edition and backend project, written
atomically with private file permissions, and never contains bearer credentials.
Pending records are retried only for the matching authenticated subject; terminal
or expired receipts are surfaced and cannot become fabricated completion events.

A bounded revision-controlled set of explicit category interests becomes part of
account preferences. When supplied, personalized suggestions stay in those
categories; otherwise existing active saves and verified installations may inform
bounded deterministic affinity. No new view/click tracking is introduced. Existing
personalization opt-out and content-rating choices apply. With no signals,
Discover still offers truthful New/Trending/editorial sections. Browse can show
the complete eligible catalog and preserves search/category/sort filters across
pagination. Categories are user-visible and selectable; classifier suggestions
are auxiliary and never rights/publication authority.

A one-time deployment bootstrap may register the exact already reviewed public
production trust anchors and pre-signed initial empty revocation document through
the privileged production deployment connection. It refuses nonempty trust state,
verifies signature/hash and compiled-anchor equality before execution, identifies
the authorizing repository owner, and records deployment execution with no claimed
human authentication assurance. It creates no private key, role, session, or
security-response grant. Existing interactive key rotation, revocation and
security-document administration retain their actual AAL2 requirements. This
exception removes an unnecessary interactive MFA dependency from the initial
owner-authorized production deployment, not from future administrative actions.

## Invariants

- Preserve private-schema RLS, fixed search paths, explicit grants, real subject
  checks, revision/generation binding, and audit records.
- No client service-role keys, invented admin/creator claims, synthetic human
  reviewers, or fabricated engagement events.
- All published bytes retain independent hostile-media verification, immutable
  promotion, signed manifests, license/credit metadata, and revocation support.
- Account switching clears subject-bound state. Anonymous clients cannot read
  another user's saves, interests, uploads, or private account state.
- Local production development uses normal production authentication and the
  signed direct identity without copying privileged backend credentials into the
  app. Tests do not erase user data or alter Apple's live wallpaper store.
- Existing media formats remain enforced until an explicit complete compatible
  still-image path is implemented and verified. MIME acceptance alone is not
  still-wallpaper support.

## Alternatives considered

Keeping Creator closed and manually publishing every item fails the requested
product behavior. Removing all authorization or inserting approved records with
fictional moderator identities would conceal authority and is rejected. A new
clickstream or opaque recommendation service is unnecessary for this initial
category-based algorithm.

## Consequences

Publication no longer depends on the foreground app or a person repeatedly
pressing publish. Automated policy decisions must be distinguished from reviews,
and the dispatcher needs narrowly scoped scheduled invocation. Additional
preference fields and authoritative count readers require additive migrations.
Normal users can upload without managing an authenticator.

## Migration and rollback

Add versioned RPCs, an auditable automatic-publication decision/outbox, and bounded
category preferences. Preserve existing human decisions and immutable published
releases. Enable actual effective Creator Terms only when native consent and
backend admission agree. Bootstrap reviewed public trust material through audited
deployment authority, never by fabricating a user session. A disabled automatic
scheduler or null effective terms stops new work without deleting uploaded or
published media. Roll back clients/API additively; do not delete user preferences,
bookmarks, library objects, or already acknowledged downloads.

## Verification

Focused regressions cover admission and metadata binding, stale/duplicate jobs,
publication resumption after promotion, distinct machine/human authority,
private-state isolation, category constraints, current counters, and saved-item
retrieval. End-to-end acceptance uses the locally editable signed app and real
production services: email OTP, terms/Creator, upload then app closure, publication,
Discover/Browse/detail, verified download, immediate count refresh, Library and
account preferences after relaunch, and every navigation destination/Settings.
Source inspection, local tests, deployment, and observed native behavior are
reported separately. A stable release follows demonstrated behavior.
