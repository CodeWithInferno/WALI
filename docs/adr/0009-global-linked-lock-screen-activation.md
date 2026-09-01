# 0009: Supersede per-display Lock Screen activation with global linked activation

- status: accepted
- date: 2026-08-31
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: project-owner global linked activation directive 2026-08-31
- related: [0008](0008-session-lock-aerial-adapter.md)

## Context

ADR 0008 established the safety boundary for the authenticated-session private
Aerial adapter. Live validation on macOS 26 build 25F80 showed that its assumed
per-display activation path does not describe the current store: valid stores
may have empty `Displays` and `Spaces` maps, while WallpaperAgent consumes the
linked `AllSpacesAndDisplays` and `SystemDefault` values. Synthesizing display
nodes is therefore not an accepted compatibility mechanism.

The verified linked nodes contain `Type`, a `Linked.Content` choice plus opaque
option data and shuffle mode, and daemon-maintained `LastSet` and `LastUse`
dates. WallpaperAgent can race a writer and later advance those dates.

## Decision

This decision supersedes ADR 0008's per-display activation and rollback
mechanism while retaining its scope, ownership, version gate, and prohibited
behaviors.

WALIAgent selects exactly one Lock Screen asset: the current main display's
active WALI assignment. It registers only that WALI-owned master and poster in
the verified Aerial manifest. While enabled, the adapter replaces the choice in
both `AllSpacesAndDisplays` and `SystemDefault`, preserves each node's opaque
`EncodedOptionValues`, `Shuffle`, and unrelated fields, updates `LastSet` and
`LastUse` on first activation or target change, and sets `Displays` and `Spaces`
to empty dictionaries. It never synthesizes display or Space nodes.

Before preference persistence, preflight validates the exact build and schema,
input and destination paths, ownership, generated poster, both planned
journals, and their bounds. A transaction journal records the exact original,
source, and target values of the four managed roots before any Index
replacement. The writer reparses staged output and uses compare-and-swap file
replacement. The live adapter asks WallpaperAgent to terminate and waits one
second immediately before a required manifest or Index mutation, then refreshes
WallpaperAgent and the Aerial extension after commit. A noncooperating process
can still change the store between the final validation and atomic exchange;
the compare-and-swap detects that race and fails without accepting ownership.

## Invariants

- Scope remains the authenticated current user's session Lock Screen after
  login. FileVault preboot, loginwindow, other users, direct protected-UI
  drawing, root, SIP bypass, and UI injection remain excluded.
- Build 25F80, manifest version 1, provider and WALI identifiers remain exact
  allowlisted compatibility inputs. Unknown variants fail before writes.
- Only the main display assignment becomes the global Lock Screen selection.
  Desktop assignments and playback timelines remain independent.
- The four managed root values are `AllSpacesAndDisplays`, `SystemDefault`,
  `Displays`, and `Spaces`; every unrelated top-level value is preserved.
- While WALI owns the selection, only WallpaperAgent changes to the Date values
  at `Linked.LastSet` and `Linked.LastUse` are tolerated. Provider,
  configuration, choices, opaque content options, shuffle mode, override maps,
  and every other managed field must still match.
- Disable restores the exact four-value preimage. External structural changes
  fail closed and remain untouched.
- Prepared and committed choice journals are encoded and checked against the
  4 MiB bound during preflight, before preference persistence or Apple writes.
- Quiescing and refreshing are performed only for a required managed mutation;
  automated tests use injected handlers and never terminate live processes.

## Consequences

The authenticated Lock Screen consistently follows one predictable source—the
main display—across the verified global store. Per-display Lock Screen choices
are intentionally unavailable because the verified macOS surface is global.
Enabling temporarily suppresses the current user's display and Space overrides;
disabling restores their exact prior values when ownership validation succeeds.

The integration remains private, experimental, Full-Disk-Access-gated, and
liable to stop after a macOS update until a new fixture-backed revision is
accepted. A failure never stops or rolls back already committed desktop
playback.

## Migration and rollback

Compatibility surface epoch 1 revision 1 replaces revision 0. No released
installation should own revision-0 choice journals because the adapter remained
default-off and live mutation was prohibited during development. Ambiguous old
prepared journals are rejected rather than guessed.

Disabling revision 1 restores its journaled four-root preimage only after exact
managed-state validation with the timestamp exception above, then removes only
WALI-owned Aerial records and files. The persisted preference continues to
decode as disabled when absent.

## Verification

- The redacted fixture records the exact global linked keys, binary-data
  placeholders, active empty override maps, main-display selection rule, and
  four-root rollback scope.
- Existing WALIAgent tests cover activation, exact rollback, activation and
  disable crash recovery, timestamp drift, structural conflicts, journal bounds,
  main-display choice, quiesce ordering, and refresh reentrancy.
- Architecture checks bind revision 1 to ADR 0009 and reject changes to the
  build, provider, global policy, selection, rollback, or fixture structure.
- All automated editor and coordinator tests use synthetic temporary roots.
