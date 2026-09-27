# 0030: Identity-bound renewal of transient Store bookmarks

- status: accepted
- date: 2026-09-13
- owner_role: architecture_maintainer
- accepted_by: project_owner
- approval_reference: owner reply "ok" to exact Store file-access scope on 2026-09-13 (call_PIIzYfnl1PeCOraNiBOdI3VD)
- supersedes: 0018
- supersedes_scope: worker_transient_bookmark_staleness

## Context

The signed Store app downloads real production bytes and admits picker-selected PNG/video files, but its private worker rejects fresh agent-container bookmarks as stale. Native v5–v7 show the exact expected URL, successful scoped access, and fresh resolution after recreating an ephemeral bookmark under that access. Re-resolving identical bytes stays stale; larger bookmark data does not fix it. No successful media processing is claimed. Apple's [URL initializer documentation](https://developer.apple.com/documentation/foundation/url/init(resolvingbookmarkdata:options:relativeto:bookmarkdataisstale:)-3ic6f) instructs recreating stale bookmark data from the returned URL; [implicit cross-process scope](https://developer.apple.com/documentation/browserenginekit/accessing-files-in-browser-extensions) remains the selected mechanism.

## Decision

Supersede only ADR 0018's unconditional worker rejection of stale transient current-attempt bookmarks. The agent explicitly includes file-resource and volume identifiers when creating each implicit source/staging bookmark. The worker may renew once, in memory, only after the received URL exactly matches the request, explicit scope acquisition succeeds, and both recorded identifiers are present (not NSNull) and match current resource values. Validate the expected regular-file/directory type and reject symlinks. Recreate an implicit bookmark while that received access remains active; resolve it once and require non-stale status, the exact same URL, and unchanged file/volume identities before media work. Missing identity metadata, renewal failure, repeated staleness, mismatch, or denied scope fails closed. Old peers can still complete fresh grants; old stale grants lacking identifiers cannot renew.

## Invariants

Persistent agent source authorization still rejects stale bookmarks. No entitlement, XPC envelope, actor/ownership, persistence, path fallback, or worker authority expansion changes. Source remains read-only and its write-denial check remains mandatory. Staging remains the exact job and generation directory. Renewed data is never persisted or returned. Every original, implicit, explicit, and renewed scope closes exactly once on success/failure/cancellation. The agent still independently verifies bytes before publication.

## Alternatives considered

Reject-all is the current native failure. Ignoring stale, granting an enclosing container/group, or trusting a matching path alone is rejected. Full bookmarks were tested and failed. Re-resolving original bytes was tested and remained stale.

## Consequences

Valid received authority can survive Foundation metadata staleness. There is one bounded extra bookmark creation/resolution only for stale grants. This does not promise recovery for moved, replaced, revoked, or unidentifiable resources.

## Migration and rollback

No stored schema or wire version changes. New agent-created transient data carries Foundation resource properties inside the existing bounded Data fields. Revert the agent inclusion and worker renewal to restore fail-closed rejection; never rewrite/delete existing source bookmarks, runtime journals, media, or user containers. Remove temporary diagnostic probes and the failed full-bookmark comparison from the final source.

## Verification

The smallest failing test will create a real temporary source and staging directory, include both identity properties in its bookmarks, simulate the observed first-resolution stale flag through the existing worker adapter, and assert that a fresh same-identity renewal is required before success. Paired real-file replacement, missing identity, repeated stale, wrong URL/type/symlink, denied scope, writable-source and cleanup cases remain failures. Signed native acceptance must prove production catalog install, local PNG/video import, rendering, normal complete Quit/relaunch, and source write denial. A successful fixture or signature check is not native acceptance.
