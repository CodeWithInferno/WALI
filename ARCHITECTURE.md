# WALI Architecture

**Status:** Architecture-hardening baseline, 2026-08-30  
**Scope:** Native macOS 15+ local-wallpaper foundation

The accepted target is an engine-centered modular monolith hosted by
`WALIAgent.app`. In that target, the agent is the sole runtime authority,
`WALI.app` submits intentions and renders snapshots, and
`WALITranscoder.xpc` is an agent-private worker.

The checked-in scaffold does **not** implement those runtime capabilities. It
has placeholder views, a permissive process-scoped transcoder listener, and no
app↔agent IPC, Engine orchestration, renderer, durable persistence, filesystem
behavior, or storage. WALIModel now implements Foundation-free immutable model
records and pure playback/import-job reducers. The transcoder is contained only
by the embedded agent.
[`modules.yml`](docs/architecture/modules.yml) separates current
presence/capabilities from target responsibility and is the authoritative graph
registry.

## System graph

Arrows have one meaning each:

- `-->` is a compile-time import/link dependency.
- `==>` is versioned IPC; it is never a source import.
- `-e->` is bundle containment only; the parent does not link the child.

### Current compile and containment graph

```text
WALI.app --> WALIAppRuntime
WALIAppRuntime --> {WALIUI, WALIModel, WALIWire}
WALIUI --> WALIModel

WALIAgent.app --> WALIAgentRuntime
WALIAgentRuntime --> {WALIUI, WALIModel, WALIWire, WALIEngine}

WALITranscoder.xpc --> WALITranscoderRuntime
WALITranscoderRuntime --> {WALIModel, WALIWire}

WALIWire --> WALIModel
WALIEngine --> WALIModel

WALI.app -e-> WALIAgent.app -e-> WALITranscoder.xpc

app <== no implemented IPC ==> agent
```

`WALICore` remains the local package reference and folder name only; there is
no imported `WALICore` module or product. All three products retain
package-scoped module-availability markers; no marker is public outside the
package. WALIModel additionally implements the Task 4 values and package-scoped
reducers inventoried in
[`2026-08-31-wali-model.md`](docs/design/2026-08-31-wali-model.md). WALIWire
and WALIEngine remain markers only: wire DTOs, use cases, persistence, and
orchestration are not implemented.

An `@_exported import` is a distinct re-export edge in addition to its ordinary
import edge. Internal WALI re-exports are denied unless the module manifest
explicitly allowlists them; every current allowlist is empty. A Swift package
product must export exactly one production target, every production target
must have exactly one product, and each module descriptor's product must export
its named target.

All runtime/UI surfaces above remain placeholders; the transcoder runtime has
only a permissive process-scoped listener. Agent-private containment does not
claim that the agent can invoke the worker yet. Current `project.yml` edges,
explicit package products, and copy destinations are checked exactly.

Debug, Development, and Release use distinct bundle and planned control-service
namespaces. Credential-free Debug and Release verification requires unsealed
wrappers; linker-produced ad-hoc Mach-O signatures are not bundle seals.
Debug has no app-group entitlement. Development uses the
`com.wali.development.*` namespace, strict Apple Development signatures, and
its own app group; Release retains the `com.wali.*` production identities.

### Target before product behavior

The compile-time package split shown above is complete. The sole machine
authority for package-target arrows is
`swift_packages.WALICore.current.targets[*].dependencies` in
[`modules.yml`](docs/architecture/modules.yml); the target graph records the
same boundary. There is no `WALIEngine --> WALIWire` edge. Future runtime
adapters will translate bounded wire DTOs into transport-neutral use-case
inputs.

Target process and containment graph:

```text
WALI.app == AgentGateway ==> WALIAgent.app == private XPC ==> WALITranscoder.xpc
    |
    `-e-> WALIAgent.app -e-> WALITranscoder.xpc
```

This graph is a boundary target, not a claim that use cases exist. The
app-to-agent transport is intended to be a launchd-published named Mach
service with peer authentication. That transport remains **proposed** until the
signed lifecycle spike required by
[ADR 0006](docs/adr/0006-named-authenticated-xpc.md) passes. A persisted
anonymous endpoint is not an acceptable fallback.

## Target module responsibilities

- `WALIModel` is reserved for stable immutable values, identifiers, policies,
  and reducer state. It has no UI, media, persistence, filesystem, or process
  code.
- `WALIWire` is reserved for explicit bounded/versioned envelopes, DTOs, and
  stable wire error codes. It does not expose engine or system-framework types.
- `WALIEngine` will own transport-neutral use cases, command ordering,
  revisions, durable job semantics, and orchestration policy.
- `WALIUI` contains reusable presentation only.
- Runtime static modules adapt the engine and model to SwiftUI, AppKit,
  AVFoundation, SQLite, ServiceManagement, launchd, and XPC.
- Executable targets are composition roots. They never import another
  executable target's implementation.

Do not add empty catalog, sync, lock-screen, or plugin modules. A new module
needs a real adapter boundary, an owner, and at least one caller.

## Target ownership and actor map

- `WALI.app` will own foreground SwiftUI/AppKit objects on `@MainActor`, a
  reconnectable gateway, and disposable snapshot presentation state. It owns no
  renderer, accepted job, artifact installation, or database connection.
- One Engine instance inside `WALIAgent.app` will be the logical owner of commands,
  monotonic revisions, assignments, durable jobs, storage transactions, and
  every persistent write.
- Agent AppKit/SwiftUI objects, wallpaper windows, players, and display
  reconciliation are `@MainActor` owned. Engine operations reach them through
  narrow adapters; the Engine does not import AppKit or AVFoundation.
- The agent will be the only WALI runtime process that opens SQLite.
- In the target, `WALITranscoder.xpc` operates on one bounded immutable attempt at a time. It
  may claim digests and media properties, but it cannot publish artifacts,
  mutate assignments, or edit the database.

Revalidate generation/revision after every suspension point. Accepted commands
and long-running attempts produce one durable terminal result. Teardown is
idempotent.

## Target stable seams

- `AgentGateway`: intentions, snapshots, sequencing, resync, and connection
  lifecycle between the app and agent.
- `LibraryUseCases`: library queries and commands with domain-specific names,
  not generic CRUD.
- `PresentationUseCases`: assignment, playback, and display intentions.
- `RuntimeStore`: Engine transactions, durable jobs, revisions, and install
  journal access; it does not leak SQLite handles.
- `WallpaperRenderer`: capability-based preparation, activation, and
  idempotent teardown.
- `TranscodeExecutor`: bounded immutable attempts and cancellable progress.
- `AssetPackageVerifier`: independently verifies worker claims before
  publication.
- `SystemEventSource`: normalized display, power, sleep, lock, and thermal
  events.
- `LockScreenContinuityCoordinator`: an agent-owned, opt-in compatibility
  adapter for the authenticated current user's Aerial and wallpaper stores.
  It uses injected roots, build/schema gates, WALI ownership IDs, rollback
  journals, and atomic replacement; it is not part of the desktop renderer.
- `DiagnosticsLease`: demand-driven, bounded diagnostics observation.

These are deep domain seams. Do not create generic repositories for every
record or one protocol per Apple framework.

## Target storage and compatibility

Artifacts will be immutable and addressed by SHA-256. Durable intent will
precede worker dispatch; installation then advances through the journals
defined by [ADR 0005](docs/adr/0005-content-addressed-artifacts.md).
The agent will copy/stream untrusted staging into a fresh same-volume
destination it alone creates, then hash and validate those destination bytes;
worker staging is never published directly.

```text
intent_recorded -> verifying -> verified -> prepared -> published -> committed
```

Only committed releases will appear in library queries. Recovery will reconcile
journal, filesystem, and database state idempotently; a stale worker completion
cannot publish.

Every persisted or external surface is inventoried in
[`surfaces.yml`](docs/compatibility/surfaces.yml). A format cannot ship until it
has an owner, explicit current/minimum-readable versions, golden fixtures, and
forward/rollback behavior documented in
[versioning](docs/versioning.md) and [migrations](docs/migrations.md).

## Extension strategy

Extend through capabilities and adapters:

- Additional wallpaper formats implement `WallpaperRenderer` without changing
  assignment semantics.
- Media workers implement `TranscodeExecutor`; the agent retains verification
  and installation authority.
- A future signed catalog translates manifests into model values at the agent
  boundary.
- Storage implementations remain behind `RuntimeStore`.

Desktop public APIs remain primary. ADR 0008 permits one private adapter for
authenticated-session Lock Screen continuity on exact verified macOS builds.
The agent registers WALI-owned copies with Apple's current-user Aerial provider
and patches only matching display and Space-display choices. Direct rendering
in protected Lock Screen UI, FileVault preboot, unauthenticated loginwindow,
other users, elevated helpers, arbitrary plugins, sync, a remote catalog, and
shared `/Users/Shared` storage remain unsupported or deferred.

## Gates

Compatibility:

- Protocol and message versions are independent and explicit.
- Requests carry request ID, idempotency key, expected revision, and bounded
  payload bytes.
- Snapshots are sequenced; a gap triggers full resynchronization.
- Unsupported newer critical data fails closed without destructive reset.

Security:

- Authenticate both IPC peers using code-signature requirements before trusting
  a message.
- Treat imported media, worker output, manifests, and diagnostics inputs as
  untrusted.
- Ordinary wallpaper operation requires no root, Accessibility, Screen
  Recording, or Full Disk Access.
- WALI supports the current user's desktop. It does not bypass SIP, FileVault
  preboot, protected login UI, or another user's consent.

Performance:

- No continuous work lacks an off/suspend path.
- Decoding pauses for sleep, display sleep, lock, invisibility, serious thermal
  pressure, and configured low-power policy while preserving a poster.
- Diagnostics samples exist only under a lease and keep bounded history.
- Optimization claims require reproducible median and p95 evidence against the
  budgets in the [detailed design](docs/design/2026-08-30-wali-architecture-and-product.md#15-performance-budgets).

## Decision and policy map

Accepted ADRs and [`AGENTS.md`](AGENTS.md) are normative. Cursor rules are
concise projections and cannot override them. Governance and conflict handling
are defined in [`GOVERNANCE.md`](GOVERNANCE.md).

- [ADR 0001: Process topology (partially superseded)](docs/adr/0001-process-topology.md)
- [ADR 0002: Video-first rendering](docs/adr/0002-video-first-rendering.md)
- [ADR 0003: Agent-owned state](docs/adr/0003-agent-owned-runtime-state.md)
- [ADR 0004: Engine-owned use cases](docs/adr/0004-engine-owned-use-cases.md)
- [ADR 0005: Content-addressed artifacts](docs/adr/0005-content-addressed-artifacts.md)
- [ADR 0006: Named authenticated XPC (proposed)](docs/adr/0006-named-authenticated-xpc.md)
- [ADR 0007: Apache 2.0 licensing and DCO](docs/adr/0007-apache-2-licensing.md)
- [Detailed product/system design](docs/design/2026-08-30-wali-architecture-and-product.md)
