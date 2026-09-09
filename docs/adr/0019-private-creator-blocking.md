# 0019: Private creator blocking for marketplace viewers

- status: proposed
- date: 2026-09-09
- owner_role: catalog_maintainer
- accepted_by: pending
- approval_reference: explicit project-owner approval required for schema and privacy boundary
- related: [0011](0011-supabase-marketplace-control-plane.md), [0012](0012-signed-remote-catalog-releases.md), [0018](0018-sandboxed-mac-app-store-distribution.md)

## Context

WALI already has reporting and moderator enforcement, but viewers cannot block
individual creators. The owner approved a Store product retaining marketplace
and creator features. Apple's user-generated-content guideline requires
reporting, blocking, moderation, and reachable contact information.
[App Review Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)

A viewer's block relationship is private account data. Adding a persistent
relation, authenticated operations, and personalized catalog filtering requires
explicit approval under [GOVERNANCE.md](../../GOVERNANCE.md). Approval of the
Store sandbox in ADR 0018 did not approve this separate marketplace boundary.
This proposal adds to ADRs 0011 and 0012 without superseding their authorization,
remote-media validation, publication, or local installation rules.

## Decision

### Meaning and user experience

Add **Block Creator** beside Report on wallpaper detail and creator pages.
The confirmation explains that the creator's catalog content will disappear
from discovery and saved/favorite views and that existing local wallpapers
remain installed. Offer **Blocked Creators** in Account for review and unblock.
Blocking never sends a notification to the creator or makes a public report.
Report remains available as a separate action before and after blocking.

An authenticated block applies to the viewer's account on every device. A
signed-out viewer can block locally without creating an account; the app stores
only bounded creator IDs in its own container, excludes those creators from
catalog presentation, and offers a local unblock list. Anonymous install and
engagement commands retain their existing authentication requirements. Local
anonymous preferences are separate from every account's block list. Signing in
or switching accounts does not upload or copy them; signing out restores the
anonymous preferences. Neither path touches the agent's authoritative library.

Unblocking restores ordinary visibility. Existing favorite/save/follow records
are retained while blocked, so they may become visible again after unblock.
A viewer can still remove their own saved/favorite/follow state during a block,
including after relaunch, through the private cleanup controls described below.
There is no automatic media removal, playback change, public delisting,
moderator sanction, or grant of additional account authority.

### Private relation and operations

Add `wali.creator_blocks` with `(user_id, creator_id)` as its primary key,
`active`, monotonic `revision`, and creation/update timestamps. Both IDs refer
to existing profiles; self-block is invalid. A private viewer index supports
bounded active-list pagination. Use RLS and explicit grants: account owners can
read only their outgoing relationships through an allowlisted projection;
ordinary clients cannot directly insert/update/delete the table. There is no
incoming-block list, public block count, notification, or creator-visible API.
A second private relation, `wali.creator_block_preferences`, stores one
monotonic generation per viewer. Every effective block/unblock increments it
in the same transaction as the relationship mutation; an idempotent replay
does not increment it again. Owners can read only their own generation through
the block-list RPC, and clients cannot write either relation directly.

Add explicit versioned `set_creator_block_v1` and `my_creator_blocks_v1` RPCs
using the existing bounded DTO, optimistic revision, idempotency, and interaction
quota conventions. The actor is always `auth.uid()` from a verified active
session, never a caller-selected user ID. AAL1 is sufficient for this reversible
preference; existing privileged/moderation AAL2 checks remain unchanged. Reject
null/invalid values, self-blocks, inaccessible new block targets, malformed pagination,
and cross-account attempts with safe errors. Retry of the same completed
operation returns the same result; conflicting reuse is rejected. An owner can
unblock an existing relationship even if its target is no longer publicly
accessible. `my_creator_blocks_v1` returns the viewer generation with its first
page and binds every subsequent cursor to that generation; a concurrent change
invalidates pagination and requires a fresh first page. A first-time relation
uses expected revision zero; a previously created relation retains its nonzero
revision even while inactive.

Use a hard bound of 10,000 active blocks per viewer and pages of at most 100.
At the limit, existing blocks and unblock remain functional. Display an
explicit limit error rather than evicting an existing choice. The anonymous
list uses the same bound. This cap and its native/server refusal behavior are
part of the published contract, not an unbounded client-controlled allocation.

### Enforcement and races

Authenticated catalog queries apply the current account's blocks in the
server's reviewed projection/RPC layer, including home/editorial rows, browse,
search, related items, direct detail, creator pages, collections, favorites,
and saved lists. Filter before pagination and compute returned visible counts
consistently. Personalized responses must not enter shared anonymous caches.
The anonymous public catalog remains public; the foreground applies its own
anonymous preference before rendering or starting preview downloads.

Add an owner-only bounded `my_hidden_interactions_v1` cleanup projection for
retained saves/favorites/follows hidden by a block. It returns only target IDs,
interaction kinds, current revisions and active state, with pages of at most
100 bound to the viewer generation. It does not return wallpaper media or
creator-private data. Account cleanup controls can use those revisions with
the existing removal commands after relaunch, without unblocking or relying
on a hidden detail response. Reporting remains callable for a known target
under the existing report contract.

New install authorizations and positive favorite/save/follow mutations reject
blocked creators. Use a consistent account/creator lock ordering with the block
command so concurrent operations have a defined transaction order: a grant
committed before a block remains an already-issued grant; a grant ordered after
it is refused. Do not revoke another viewer's grant or change signed manifests.
An already-issued grant, already-downloaded public URL, or local installation
is not retroactively revoked by a personalized block. The client cancels its
pending catalog downloads/install initiation where cancellation remains
possible, and does not automatically uninstall accepted local work.

After block/unblock or subject change, cancel stale catalog tasks, discard
pagination/detail/preview state, and reload for the current subject and block
generation. Refresh the authenticated block snapshot on initial sign-in,
account switch, return to a visible foreground window, and catalog navigation
or an explicit catalog action before reusing personalized cached content.
These event-driven boundaries do not claim real-time push synchronization or
introduce background polling. The server applies current blocks to every
supported catalog query regardless of client cache age. A completion captured
under an older foreground request or preference generation cannot reintroduce
hidden content. Authenticated catalog actions fail closed while that subject's
required preference refresh is unresolved; present a retry state. Account
switching never displays the previous person's block list or personalized
results. The local library remains available offline regardless of catalog
preference refresh.

Server enforcement also applies to older clients using supported versioned
catalog and interaction APIs. UI-only filtering is insufficient. Reporting
and cleanup operations stay available without exposing another person's
private block relationship. Moderators retain their separately authorized
work queues; a personal block is not a moderation bypass or assignment filter.

### Retention and export

An account export includes only that account's outgoing block IDs, active
state, revisions, and timestamps. It never includes people who blocked them.
Account deletion removes the viewer preference generation and outgoing and
incoming relationships as part of the
existing idempotent deletion workflow. No public creator profile or content
attribution is expanded by this change. This ADR does not alter other account
retention, legal holds, Apple authorization, or public-media deletion policy;
those unresolved review findings remain separate release gates.

Inactive relationships retain their minimal nonzero revision tombstones until
the viewer or creator account is deleted. Do not prune them merely because
a completed command expired: doing so would permit a delayed expected revision
zero to recreate an old choice. Keep only the current active state, revision
and necessary timestamps, never a per-action history. Completed command
receipts retain their existing expiry policy; the viewer generation survives
individual unblock operations. Document these distinct retention rules and
the fact that the active-list cap does not bound tombstone count in the data
inventory. Do not emit identifiable block events into ranking, analytics, or
public counters.

## Invariants

- The blocking viewer controls only their own private choice.
- Blocking does not disclose the relationship to the creator or other viewers.
- Anonymous and authenticated identities have separate preferences.
- Direct IDs and older clients cannot bypass authenticated visibility or new
  interaction enforcement; saved-state removal and reporting remain possible.
- Installed local media, original files, signed catalog integrity, moderator
  authority, and direct/Store data isolation retain their existing boundaries.
- No new tracking, notification provider, runtime dependency, or privileged
  client credential is introduced.

## Alternatives considered

- Rely on Report or administrative suspension: does not give viewers a private
  reversible blocking choice.
- Only filter the current screen: fails direct detail, other devices, in-flight
  responses, and existing API callers.
- Make block a global content revocation: gives ordinary viewers inappropriate
  authority and affects unrelated users and installed media.
- Copy anonymous preferences into an account automatically: creates unexpected
  cross-identity synchronization and additional remote data collection.

## Consequences

This adds two private relations, three bounded RPC contracts, catalog/mutation
filters, native controls, privacy inventory entries, and regression coverage.
The service must deploy enforcement before clients advertise account blocking.
A passing implementation does not establish moderation staffing, complete
account deletion, effective public policy, or App Store acceptance.

## Migration and rollback

Apply an additive ordered migration with no backfilled choices and no changes
to existing user content. Retain all versioned catalog response shapes except
explicit additive block APIs. Update the public API allowlist, data inventory,
backend/client contracts, and export/deletion paths together.

Test a clean replay and upgrade of an existing database before deployment.
Rollback the unshipped feature as a unit. Once viewers have recorded blocks,
do not silently drop the relation, disable server filters, or expose hidden
content to simplify rollback; retain enforcement while rolling the client back
or temporarily make affected account catalog operations unavailable with a
clear error. No destructive production rollback is authorized by this ADR.

## Verification

- RLS matrix for two viewers, two creators, anonymous, inactive accounts, and
  authorized moderators; cross-user reads/writes and incoming-list inference.
- Idempotency, revision conflicts, null/malformed inputs, cap boundaries,
  self-block, deletion, export, delayed revision-zero replay after command
  expiry, nonzero tombstone retention and monotonic viewer generations.
- Home, collection, browse, search, related, direct-detail, creator,
  favorite/save list, and pagination filtering before and after unblock.
- Block versus install/favorite/save/follow races in both transaction orders;
  removal after relaunch through the private cleanup projection and reporting
  still succeed; existing local media stays unchanged.
- Native in-flight response, preview cancellation, subject switch, sign-out,
  anonymous relaunch, cross-device refresh at each documented boundary,
  generation-bound pagination, offline library, and refresh-failure behavior.
- Cache controls and absence of private block data from public DTOs, logs,
  ranking events, exports belonging to another account, and notifications.
- Staging native journey and final production source/schema checks before
  advertising blocking in either distribution or Store review metadata.
