# WALI Architecture

**Status:** Implemented local pre-release baseline, 2026-09-01
**Scope:** Native macOS 15+ wallpaper engine and accepted marketplace foundation

WALI is an engine-centered modular monolith hosted by `WALIAgent.app`. The
agent is the sole local runtime authority,
`WALI.app` submits intentions and renders snapshots, and
`WALITranscoder.xpc` is an agent-private worker.

ADRs 0011–0016 add an app-only marketplace without moving local runtime
authority to the server. Supabase owns internet-facing identity/catalog state;
`WALICatalog` owns strict signed-catalog contracts; a foreground adapter owns
network transport. `WALIAgent` still owns local install/render/SQLite without
Full Disk Access. `WALILockScreenHelper.app` is the only WALI binary eligible
for that optional permission and owns only the fixed authenticated-session
Lock Screen compatibility operations.

The local wallpaper engine, bounded authenticated XPC paths, per-display
renderer, durable Engine/store, import/transcode pipeline, signed-catalog
verification, and narrow Lock Screen helper are implemented. Marketplace
schema, Edge Function, queue, worker, and client foundations are implemented
and tested locally, but this is not deployment evidence: creator/moderator and
account-privacy product flows are incomplete, public creator uploads are
disabled, and no hosted project or worker VM is claimed to be configured.
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
WALIAppRuntime --> {WALIUI, WALIModel, WALIWire, WALICatalogRuntime}
WALICatalogRuntime --> WALICatalog
WALIUI --> WALIModel

WALIAgent.app --> WALIAgentRuntime
WALIAgentRuntime --> {WALIUI, WALIModel, WALIWire, WALIEngine, WALICatalog}

WALITranscoder.xpc --> WALITranscoderRuntime
WALITranscoderRuntime --> {WALIModel, WALIWire}

WALILockScreenHelper.app --> WALILockScreenHelperRuntime
WALILockScreenHelperRuntime --> WALIWire

WALIWire --> WALIModel
WALIEngine --> WALIModel

WALI.app -e-> {WALIAgent.app, WALILockScreenHelper.app}
WALIAgent.app -e-> WALITranscoder.xpc

WALI.app == bounded authenticated IPC ==> WALIAgent.app
WALIAgent.app == private bounded IPC ==> WALITranscoder.xpc
WALIAgent.app == fixed-operation IPC ==> WALILockScreenHelper.app
```

`WALICore` remains the local package reference and folder name only; there is
no imported `WALICore` module or product. `WALIModel`, `WALIWire`, and
`WALIEngine` implement their bounded model, wire, use-case, and orchestration
responsibilities. Current capabilities and dependency edges are recorded in
[`modules.yml`](docs/architecture/modules.yml); historical task descriptions
are not implementation status.

An `@_exported import` is a distinct re-export edge in addition to its ordinary
import edge. Internal WALI re-exports are denied unless the module manifest
explicitly allowlists them; every current allowlist is empty. A Swift package
product must export exactly one production target, every production target
must have exactly one product, and each module descriptor's product must export
its named target.

The app invokes the agent, the agent invokes its private transcoder, and the
optional helper exposes only its fixed authenticated operations. Current
`project.yml` edges, explicit package products, containment, service metadata,
and copy destinations are checked exactly. Real Team-ID signatures and an
installed launchd lifecycle remain environment evidence, not local hostless
test claims.

Debug, Development, and Release use distinct bundle and planned control-service
namespaces. Credential-free Debug and Release verification requires unsealed
wrappers; linker-produced ad-hoc Mach-O signatures are not bundle seals.
Debug has no app-group entitlement. Development uses the
`com.wali.development.*` namespace, strict Apple Development signatures, and
its own app group; Release retains the `com.wali.*` production identities.

### Implemented topology and remaining environment proof

The compile-time package split shown above is complete. The sole machine
authority for package-target arrows is
`swift_packages.WALICore.current.targets[*].dependencies` in
[`modules.yml`](docs/architecture/modules.yml); the target graph records the
same boundary. There is no `WALIEngine --> WALIWire` edge. Runtime adapters
translate bounded wire DTOs into transport-neutral use-case inputs.

Process and containment graph:

```text
WALI.app == AgentGateway ==> WALIAgent.app == private XPC ==> WALITranscoder.xpc
    |                                |
    |                                `== bounded helper IPC ==> WALILockScreenHelper.app
    |
    +-- WALIAppRuntime --> WALICatalogRuntime --> WALICatalog
    |                                      `--> exact-pinned Supabase SDK
    |
    `-e-> {WALIAgent.app, WALILockScreenHelper.app}
             `-e-> WALITranscoder.xpc
```

The named Mach services, bounded protocols, and peer-authentication checks are
implemented. Credential-free hostless builds cannot prove real Team-ID peer
identity, embedded login-item registration, upgrades, reconnects, or installed
launchd behavior; those signed lifecycle checks remain external release gates
under [ADR 0006](docs/adr/0006-named-authenticated-xpc.md). A persisted
anonymous endpoint is not an acceptable fallback.

## Module responsibilities

- `WALIModel` is reserved for stable immutable values, identifiers, policies,
  and reducer state. It has no UI, media, persistence, filesystem, or process
  code.
- `WALIWire` is reserved for explicit bounded/versioned envelopes, DTOs, and
  stable wire error codes. It does not expose engine or system-framework types.
- `WALIEngine` owns transport-neutral use cases, command ordering,
  revisions, durable job semantics, and orchestration policy.
- `WALIUI` contains reusable presentation only.
- Runtime static modules adapt the engine and model to SwiftUI, AppKit,
  AVFoundation, SQLite, ServiceManagement, launchd, and XPC.
- `WALICatalog` owns bounded catalog identifiers, canonical JSON, detached
  Ed25519 verification, approved-host checks, and revocation values. It depends
  only on `WALIModel` internally and Foundation/CryptoKit from the platform; it
  has no transport, UI, media, persistence, or Supabase dependency.
- `WALICatalogRuntime` implements native Apple sign-in, public catalog,
  interaction/report/install transport, bounded mapping, public caching, and
  create-exclusive downloads. Creator/moderator protocols and presentation
  models exist, but their production gateway and app-route composition are
  deferred. Supabase types do not escape the runtime boundary.
- `WALILockScreenHelperRuntime` owns only authenticated, fixed-root, version-
  gated Lock Screen transactions and process refreshes. Its composition app is
  the only product eligible for Full Disk Access and imports no media, network,
  UI, database, scripting, or plug-in framework.
- Executable targets are composition roots. They never import another
  executable target's implementation.

Do not add empty catalog, sync, lock-screen, or plugin modules. A new module
needs a real adapter boundary, an owner, and at least one caller.

## Ownership and actor map

- `WALI.app` owns foreground SwiftUI/AppKit objects on `@MainActor`, a
  reconnectable gateway, and disposable snapshot presentation state. It owns no
  renderer, accepted job, artifact installation, or database connection.
- One Engine instance inside `WALIAgent.app` is the logical owner of commands,
  monotonic revisions, assignments, durable jobs, storage transactions, and
  every persistent write.
- Agent AppKit/SwiftUI objects, wallpaper windows, players, and display
  reconciliation are `@MainActor` owned. Engine operations reach them through
  narrow adapters; the Engine does not import AppKit or AVFoundation.
- The agent is the only WALI runtime process that opens SQLite.
- `WALITranscoder.xpc` operates on one bounded immutable attempt at a time. It
  may claim digests and media properties, but it cannot publish artifacts,
  mutate assignments, or edit the database.

Revalidate generation/revision after every suspension point. Accepted commands
and long-running attempts produce one durable terminal result. Teardown is
idempotent.

## Stable seams

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
  coordinator for opt-in intent and helper status. The privileged store adapter
  itself is helper-owned for the authenticated current user's Aerial and
  wallpaper stores. It uses fixed/injected roots, build/schema gates, WALI
  ownership IDs, rollback journals, and atomic replacement; it is not part of
  the desktop renderer.
- `CatalogGateway`: product-shaped home, browse, search, detail, account,
  creator, moderation, and install operations with a production foreground
  adapter and deterministic test adapter; it is not generic CRUD.
- `CatalogManifestVerifier`: strict canonical-body, signature/key, approved-host,
  artifact, digest, and signed-revocation validation independent of transport.
- `DiagnosticsLease`: demand-driven, bounded diagnostics observation.

These are deep domain seams. Do not create generic repositories for every
record or one protocol per Apple framework.

## Storage and compatibility

Artifacts are immutable and addressed by SHA-256. Durable intent precedes
worker dispatch; installation advances through the journals
defined by [ADR 0005](docs/adr/0005-content-addressed-artifacts.md).
The agent copies or streams untrusted staging into a fresh same-volume
destination it alone creates, then hash and validate those destination bytes;
worker staging is never published directly.

```text
intent_recorded -> verifying -> verified -> prepared -> published -> committed
```

Only committed releases appear in library queries. Recovery reconciles
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
- The accepted signed catalog translates versioned public responses and
  manifests into bounded values at `WALICatalog`; the foreground runtime owns
  transport and the agent independently re-verifies install input.
- Storage implementations remain behind `RuntimeStore`.

Desktop public APIs remain primary. ADRs 0009 and 0010 permit one private adapter for
authenticated-session Lock Screen continuity on exact verified macOS builds.
The narrow helper registers the main display's WALI-owned copy with Apple's current-user
Aerial provider. While active, it transactionally selects that asset through
both verified global linked values and clears the current user's display and
Space override maps. The helper quiesces WallpaperAgent immediately before a
required manifest or Index write, journals the exact four-value preimage, and
restores it only while all managed structure remains WALI-owned. On each distinct
session-lock transition, the helper revalidates that active ownership and refreshes
Apple's wallpaper processes once so a short custom asset restarts at time zero.
Direct rendering
in protected Lock Screen UI, FileVault preboot, unauthenticated loginwindow,
other users, root/elevated daemons, arbitrary plugins, device-assignment sync,
and shared `/Users/Shared` storage remain unsupported. Marketplace publication
and install follow ADRs 0011–0016; they do not broaden Lock Screen scope.

## Marketplace control plane and trust chain

**Implementation status:** the schema, bounded Edge contracts, queue workers,
private staging/promotion path, classifier persistence, catalog client, and
local install verifier are implemented and exercised locally. Rights-proof
scanning and reviewer grants, licensed/other submissions, native
creator/moderator composition, account export/deletion retrieval and status,
and the Supabase Auth cleanup executor are deferred. Hosted Supabase projects,
a dedicated worker VM, production signing/recovery keys, exact release images,
and backup/restore evidence remain external release gates.

Supabase is the only public control plane: Auth, a non-exposed authoritative
Postgres schema, explicit public views/RPCs, private upload/evidence/export
buckets, immutable public catalog objects, queues, Cron, and short privileged
Edge Functions. One replaceable Linux worker leases jobs and launches fresh
rootless, networkless media/verifier/classifier sandboxes. It has no public
listener. The application contains no database password, service key, signing
private key, worker credential, or moderator secret.

```text
hostile upload -> opaque private object -> networkless media sandbox
  -> independent verifier -> processing-private -> human approval
  -> digest-verified promotion -> catalog-public immutable release
  -> canonical manifest -> detached Ed25519 signature
  -> WALICatalog verification -> bounded quarantine -> private transcoder
  -> agent destination-byte verification -> content-addressed local publication
```

The public contract is version 1. Catalog manifest and revocation bodies use
epoch 1 revision 0. The server schema begins at epoch 1 revision 0. Storage
paths are generated and content-addressed; public objects are never overwritten.
Signing and model registries retain immutable revision/digest/license history.
Exact bounds and endpoint contracts live under `docs/api/` and
`docs/security/`; machine-readable compatibility facts live in
`docs/compatibility/surfaces.yml`.

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
- Only the optional `WALILockScreenHelper.app` may request Full Disk Access. It
  cannot receive media, URLs, paths, scripts, or generic commands and cannot
  import network/media/database/scripting frameworks.
- Public catalog bytes require canonical manifest, trusted Ed25519 signature,
  approved host, byte length, SHA-256, media-policy, and local destination-byte
  verification before install.
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
- [ADR 0008: Session Lock Screen compatibility (partially superseded)](docs/adr/0008-session-lock-aerial-adapter.md)
- [ADR 0009: Global linked Lock Screen activation (partially superseded)](docs/adr/0009-global-linked-lock-screen-activation.md)
- [ADR 0010: Restart Lock Screen playback on lock (partially superseded)](docs/adr/0010-restart-lock-screen-playback-on-session-lock.md)
- [ADR 0011: Supabase marketplace control plane](docs/adr/0011-supabase-marketplace-control-plane.md)
- [ADR 0012: Signed remote catalog releases](docs/adr/0012-signed-remote-catalog-releases.md)
- [ADR 0013: Separate Full Disk Access helper](docs/adr/0013-separate-full-disk-access-helper.md)
- [ADR 0014: Marketplace schema and RLS](docs/adr/0014-marketplace-schema-and-rls.md)
- [ADR 0015: Hostile media canonicalization](docs/adr/0015-hostile-media-canonicalization.md)
- [ADR 0016: Minimal engagement and ranking data](docs/adr/0016-minimal-engagement-and-ranking-data.md)
- [Detailed product/system design](docs/design/2026-08-30-wali-architecture-and-product.md)
- [Marketplace foundation design](docs/design/2026-09-01-marketplace-foundation.md)
