# 0004: Host engine-owned use cases in the agent

- status: accepted
- date: 2026-08-30
- owner_role: architecture_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- supersedes: [0001](0001-process-topology.md)
- supersedes_scope: shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback
- related: [0003](0003-agent-owned-runtime-state.md)

## Context

The existing `WALICore` scaffold combines values, wire payloads, policies, and
future service interfaces. Leaving orchestration in runtime controllers would
spread command ordering, job lifetime, and persistence policy across the main
app, agent, and worker. Splitting every possible feature into a service now
would add process and module boundaries before behavior exists.

WALI needs one testable authority that survives the foreground app, while
keeping stable values and cross-process contracts independent from system
frameworks.

## Decision

Build an engine-centered modular monolith and initially host its sole Engine
instance inside `WALIAgent.app`.

This supersedes three scoped clauses in ADR 0001: the broad `WALICore`
shared-core boundary; any reading of “embedded transcoder” that permits the
foreground app to host or launch the worker; and the migration fallback that
allowed the main app to host agent authority. A broken helper must fail closed
or recover the agent; it cannot move Engine authority into `WALI.app`. ADR
0001's three-product separation remains in force.

Split the shared package by responsibility:

- `WALIModel`: stable immutable values, identifiers, policies, and reducer
  state;
- `WALIWire`: explicit bounded/versioned DTOs and stable wire errors; and
- `WALIEngine`: transport-neutral use cases, durable jobs, command ordering,
  revisions, and orchestration policy.

`WALI.app` sends intentions through `AgentGateway` and renders versioned
snapshots. It never owns accepted jobs, renderer state, SQLite, or persistent
writes. Runtime static modules remain composition adapters. The transcoder is an
agent-private executor that returns untrusted immutable artifact claims.

The stable seams are `AgentGateway`, `LibraryUseCases`,
`PresentationUseCases`, `RuntimeStore`, `WallpaperRenderer`,
`TranscodeExecutor`, `AssetPackageVerifier`, `SystemEventSource`, and
`DiagnosticsLease`.

Do not create empty catalog, sync, lock-screen, or plugin modules. Do not use
generic CRUD interfaces or mirror each Apple framework with a protocol.

## Invariants

- Exactly one Engine instance owns logical mutable state, command ordering,
  revisions, jobs, and persistent mutations.
- The foreground app is disposable without cancelling rendering or accepted
  jobs.
- Engine and model modules import no UI, media, database, filesystem-global, or
  process-lifecycle framework.
- Runtime adapters translate wire DTOs and system events at the boundary.
- AppKit and SwiftUI objects remain main-actor owned.
- Revalidation occurs after suspension before a result can mutate state.
- Executable targets do not import one another's implementation.

## Alternatives considered

- Keep expanding `WALICore`: fewer targets initially, but no stability boundary
  between model, wire, and orchestration.
- Put use cases in the main app: simpler UI calls, but accepted work and
  authority disappear when the app closes.
- Put business rules directly in agent controllers: avoids a package target,
  but couples deterministic policy to AppKit, XPC, and storage adapters.
- Start with independent feature services: stronger isolation, but unnecessary
  deployment, IPC, and recovery complexity before real scaling evidence.

## Consequences

Use cases can be tested without launching macOS processes, and the agent remains
the single authority. The package has more explicit targets and runtime
adapters must translate types. The Engine host could move later, but only
behind the same seams and through a new ADR.

Feature modules are introduced only when behavior and ownership justify them.
The existing broad `WALICore` target is transitional rather than a compatibility
alias to preserve indefinitely.

## Migration and rollback

Hardening Task 3 introduces the three package targets, migrates callers, then
removes `WALICore` after no source imports it. During migration, the module
manifest may allow both old and target imports while recording current imports
separately.

If the split blocks the build, callers can remain on `WALICore` temporarily
without moving authority back to the main app. Rollback removes unused new
targets and restores the last green import graph; no user data format changes
as part of this ADR.

## Verification

- Architecture fixtures require current and planned module entries.
- Package graph checks reject forbidden frameworks and dependency cycles.
- Engine contract tests cover idempotency, expected revisions, cancellation,
  stale completions, and one terminal job result.
- Adapter tests prove main-app disconnect does not cancel accepted work.
- `scripts/check-architecture.sh` and `make verify` gate the checked-in graph.
