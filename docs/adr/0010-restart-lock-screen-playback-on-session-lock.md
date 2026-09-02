# 0010: Restart active Lock Screen playback on each session lock

- status: partially_superseded
- date: 2026-09-01
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: project-owner autonomous Lock Screen completion directive 2026-09-01
- supersedes: 0009
- supersedes_scope: 0009=refresh_only_after_required_mutation
- superseded_by: 0013
- superseded_scope: 0013=lock_screen_privileged_process_ownership

ADR 0013 supersedes only the clause assigning the allowlisted Apple wallpaper
process refresh to `WALIAgent`. The distinct-lock coalescing, read-only
preflight, and refresh behavior in this record remain accepted and move to the
narrow Lock Screen helper.

## Context

Live validation on macOS 26 build 25G83 showed that the linked Aerial selection
and WALI-owned media remain valid across repeated session locks, but Apple's
renderer maintains one playback timebase beyond a short custom asset's end.
The first lock displayed an 11.08-second WALI video. Later locks were black
while `WallpaperAerialsExtension` reported a 14-to-176-second timebase and zero
queued frames.

A controlled restart of `WallpaperAgent` and `WallpaperAerialsExtension`
reopened the same WALI file and reset the timebase to zero without changing the
manifest, Index, rollback journals, or desktop renderer. ADR 0009's refresh-only-
after-mutation rule therefore prevents correct repeat-lock playback.

## Decision

While Lock Screen continuity is enabled and the current main-display assignment
still passes the complete build, schema, path, and ownership preflight,
WALIAgent requests one Apple wallpaper-process refresh on every distinct
unlocked-to-locked session transition. Duplicate workspace and distributed
notifications for the same locked state are coalesced before reaching the
coordinator.

This refresh reuses ADR 0009's injected refresh handler. It does not create a
store transaction, update timestamps, recopy assets, or quiesce for a write when
the managed state is already current. Ordinary wake, unlock, Space, display,
and store-monitor reconciliation remains idempotent and does not force a
playback restart.

## Invariants

- The behavior remains limited to the authenticated current user's session
  Lock Screen on exact allowlisted builds; FileVault preboot and loginwindow
  remain unsupported.
- Disabled continuity, a missing main-display assignment, unsupported input,
  or lost WALI ownership never terminates Apple wallpaper processes.
- Each distinct lock transition requests at most one refresh even when macOS
  publishes the same state through multiple notification centers.
- The coordinator completes the same read-only preflight used for reconciliation
  before a refresh-only restart.
- A restart never authorizes a manifest or Index write by itself. ADR 0009's
  transaction, compare-and-swap, journal, rollback, and quiesce rules remain
  unchanged.
- Desktop rendering and its lock-triggered pause remain independent. A private-
  adapter failure becomes a warning and cannot roll back an applied desktop
  wallpaper.

## Alternatives considered

- Repeat every imported video into a several-minute Lock Screen artifact. This
  wastes storage and transcode time, still has a finite end, and changes the
  accepted media strategy to compensate for renderer lifecycle behavior.
- Periodically restart Apple wallpaper processes. Polling would cause needless
  background work and visible churn while the Mac is unlocked.
- Rewrite or toggle the Apple selection on every lock. That expands private
  store mutation and rollback risk when a read-only process refresh is enough.
- Preserve ADR 0009 unchanged. This deterministically leaves short assets black
  after their first playback lifetime.

## Consequences

Every authenticated session lock begins the selected WALI video at its first
frame, including clips shorter than the interval between locks. Locking causes
a bounded Apple wallpaper-process restart, so the private adapter remains
experimental and may need revalidation on future macOS builds.

## Migration and rollback

No persisted schema, fixture encoding, media file, or journal migration is
required. Rolling back this behavior removes the session-lock callback and
returns to ADR 0009's mutation-only refresh policy; existing WALI ownership and
rollback records remain valid.

## Verification

- A coordinator test activates a synthetic WALI selection, requests a session-
  lock restart, and proves the refresh count advances without a second quiesce
  or any manifest/Index byte change.
- A system-event/renderer test proves duplicate lock signals yield one callback
  and a later unlocked-to-locked transition yields one new callback.
- Live validation checks two separate session locks and confirms the same WALI
  video starts rather than returning a black frame.
