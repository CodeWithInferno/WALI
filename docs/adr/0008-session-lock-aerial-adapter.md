# 0008: Use a version-gated Aerial adapter for session Lock Screen continuity

- status: partially_superseded
- date: 2026-08-31
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: user-directed autonomous implementation mandate 2026-08-31
- superseded_by: 0013
- superseded_scope: 0013=lock_screen_privileged_process_ownership

ADR 0013 supersedes only the clause assigning private Apple-store access and
Full Disk Access to `WALIAgent`. The compatibility scope, verified formats,
transaction rules, ownership identifiers, rollback, and prohibited behavior in
this record remain accepted and move to the narrow Lock Screen helper.

## Context

macOS has no public API for third-party live wallpaper content inside the
protected Lock Screen. On verified macOS 26 build 25F80, the authenticated
user's Lock Screen is rendered by Apple's WallpaperAgent from the per-user
Aerial manifest and wallpaper choice store. This is private compatibility, not
a platform contract, and must never weaken normal desktop playback.

## Decision

Add an opt-in WALIAgent adapter for the exact build 25F80, Aerial manifest
version 1, and provider `com.apple.wallpaper.choice.aerials`. The adapter copies
agent-verified WALI masters and generated PNG posters into the current user's
Aerial directories, registers at most eight records, and updates only matching
display and Space-display choices. When the verified store has no top-level
node for a connected display, the adapter may create only that display's
`Linked/Content/Choices` override using the fixture-backed node shape; it does
not create Space nodes or modify `AllSpacesAndDisplays`, `SystemDefault`, or
Space defaults. WALI owns category
`57414C49-0000-4000-8000-000000000001`, subcategory
`57414C49-0000-4000-8000-000000000002`, and shot IDs prefixed
`CUSTOM_WALI_`.

The adapter validates the entire supported shape before mutation, journals
original choices and installed assets under WALI's own metadata directory,
stages sibling files, reparses staged output, synchronizes it, and atomically
replaces the destination. A build, schema, path, bound, or ownership mismatch
fails closed before an Apple-store write.

## Invariants

- Support means the authenticated current user's session Lock Screen after
  login. FileVault preboot, unauthenticated loginwindow, fast-user-switch users,
  direct Lock Screen drawing, SIP bypass, root, and UI injection are excluded.
- The agent remains the only WALI process that reads or writes this surface.
- Enabling the adapter requires Full Disk Access for WALI Agent; desktop
  rendering remains permission-free and independent.
- Global, all-user, and Space-default choices are never changed.
- A missing top-level display override is journaled as node absence. Disable
  removes the synthesized node only while its complete shape and exact managed
  WALI choice remain unchanged; otherwise the external node is preserved.
- Unrelated manifest fields, categories, assets, choices, and files are
  preserved. Reserved-ID conflicts stop the transaction.
- Disable restores a recorded choice only while it still points to the exact
  WALI asset recorded for that node.
- Interrupted prepared transactions are recovered idempotently from WALI-owned
  journals. Unknown builds and schemas are never guessed or rewritten.
- WallpaperAgent is refreshed only after a committed change, and desktop
  rendering continues if the private adapter fails.
- Desktop and Lock Screen players use independent timelines; frame continuity
  is not promised.

## Alternatives considered

- A screen saver extension: public and safer, but it does not provide the
  requested Lock Screen wallpaper behavior on current macOS.
- A custom full-screen overlay: visually misleading, bypass-prone, and not the
  protected Lock Screen.
- loginwindow injection, elevated helpers, or FileVault modifications: rejected
  as unsafe and outside WALI's authority.
- Writing every observed Apple format: rejected because private layouts require
  one verified, fixture-backed compatibility epoch at a time.

## Consequences

Users on the verified build can explicitly mirror active WALI assignments into
the authenticated Lock Screen after granting WALI Agent Full Disk Access. The feature may stop working after any macOS
update until a new build/schema is independently verified and registered. It
adds private per-user storage writes and WALI rollback metadata, but no daemon,
server, elevated helper, Screen Recording permission, or all-user state.

## Migration and rollback

The preference decodes as disabled for every older wire and persisted record.
Enabling starts with validation and ownership preflight. Disabling or removing
the last desired assignment restores journaled display choices only when still
WALI-owned, removes an absent-before-enable top-level display node only when it
is still exactly WALI-owned, removes only WALI manifest records and UUID-named
copies, and keeps external changes intact. A future supported Apple layout requires a new
compatibility revision or epoch, fixture, checker update, and ADR review.

## Verification

- The architecture registry records epoch 1 revision 0, build 25F80, manifest
  version 1, provider, ownership IDs, bounds, and the redacted fixture.
- Architecture mutation tests reject changed build, provider, ownership, scope,
  or fail-open policy.
- Editors operate on injected roots and are exercised only on synthetic or
  copied temporary stores during automated verification.
- Live verification is manual and opt-in; automated checks never edit the
  user's Apple wallpaper store or terminate WallpaperAgent.
