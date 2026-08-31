# WALI Architecture Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Correct WALI's process, module, IPC, and storage foundations before wallpaper feature work so the first vertical slice can grow safely into catalogs, schedules, additional renderers, and sync.

**Architecture:** A testable `WALIEngine` owns use cases, durable jobs, and persistence policy while initially hosted inside `WALIAgent`. `WALI.app` submits intentions and renders snapshots; an agent-private XPC worker performs bounded media work. Stable model, wire, and engine targets prevent the shared package and long-lived helper from becoming dumping grounds.

**Tech Stack:** macOS 15+, Swift 6.2 strict concurrency, Swift Package Manager, XcodeGen, NSXPC, ServiceManagement, AppKit, AVFoundation, SQLite3, Bash policy checks.

---

## Non-negotiable invariants

1. Exactly one agent/Engine instance owns mutable runtime state, SQLite, jobs, and wallpaper windows.
2. The main app never launches the transcoder or writes shared persistent state.
3. The transcoder is private to the agent, receives bounded immutable attempts, and cannot install assets.
4. Accepted commands and asynchronous completions are versioned, authenticated, bounded, idempotent, and generation checked.
5. Filesystem publication and database visibility are reconciled through a durable journal.
6. A library query returns only committed, verified asset releases.
7. Main-app exit does not cancel rendering or accepted imports.
8. Executable targets are composition roots and never import one another.
9. AppKit, SwiftUI, windows, layers, players, and display reconciliation remain main-actor owned.
10. Experimental lock-screen behavior cannot destabilize or unsandbox the desktop renderer.

## Task 1: Publish the corrected architecture and governance baseline

**Files:**
- Create: `ARCHITECTURE.md`
- Create: `GOVERNANCE.md`
- Create: `docs/architecture/modules.yml`
- Create: `docs/compatibility/surfaces.yml`
- Create: `docs/versioning.md`
- Create: `docs/migrations.md`
- Create: `docs/generated-files.md`
- Create: `docs/adr/0004-engine-owned-use-cases.md`
- Create: `docs/adr/0005-content-addressed-artifacts.md`
- Create: `docs/adr/0006-named-authenticated-xpc.md`
- Modify: `AGENTS.md`
- Modify: `.cursor/rules/10-architecture.mdc`
- Modify: `docs/plans/2026-08-30-wali-foundation.md`

**Steps:**
1. Write the public module/process graph and distinguish compile, IPC, and embed-only edges.
2. Record the Engine-hosting, artifact, and XPC decisions with alternatives, rollback, and test gates.
3. Make `modules.yml` the machine-readable authority for imports and ownership.
4. Inventory every future persisted/external compatibility surface before data ships.
5. Mark the old foundation plan superseded where it contradicts Engine ownership.
6. Run `make check-architecture`; confirm policy remains green.

## Task 2: Correct the bundle topology and development identities

**Files:**
- Modify: `project.yml`
- Modify: `Config/*.xcconfig`
- Modify: `Config/*.entitlements`
- Modify: `scripts/verify-bundle.sh`
- Modify: `Tests/Architecture/check-architecture-tests.sh`
- Modify: `scripts/check-architecture.sh`

**Steps:**
1. Add a failing bundle-policy fixture requiring `WALITranscoder.xpc` under `WALIAgent.app/Contents/XPCServices`.
2. Run the fixture and confirm failure against the current main-app embedding.
3. Move the XPC target dependency from `WALI` to `WALIAgent`; keep it embed-only.
4. Add distinct Development bundle/group/service identifiers without changing Release identifiers.
5. Extend bundle verification to reject a main-app XPC service and require exactly one agent-private service.
6. Generate, build, inspect plists and linkage, and run Debug/Release verification.

## Task 3: Split the shared package by stability and responsibility

**Files:**
- Modify: `Packages/WALICore/Package.swift`
- Create: `Packages/WALICore/Sources/WALIModel/`
- Create: `Packages/WALICore/Sources/WALIWire/`
- Create: `Packages/WALICore/Sources/WALIEngine/`
- Create: `Packages/WALICore/Tests/WALIModelTests/`
- Create: `Packages/WALICore/Tests/WALIWireTests/`
- Create: `Packages/WALICore/Tests/WALIEngineTests/`
- Modify: `project.yml`
- Modify: `Sources/**`
- Modify: `Tests/**`

**Steps:**
1. Write failing import/target-policy tests for the desired dependency graph.
2. Declare exactly three static products and six package targets at the
   canonical paths.
3. Add only package-scoped module-availability markers: Wire and Engine each
   prove their sole dependency on Model. Domain values, envelopes, use cases,
   and jobs remain Tasks 4–6.
4. Update runtime modules so app depends on Model/Wire/UI; agent on
   Model/Wire/Engine/UI; worker on Model/Wire.
5. Remove the broad `WALICore` module after all imports migrate; retain
   `WALICore` only as the local package reference/path.
6. Run package tests, architecture checks, Xcode unit tests, and both builds.

## Task 4: Define durable assets, displays, playback policy, and jobs

**Status:** Implemented and verified on 2026-08-31.

**Files:**
- Create: `Packages/WALICore/Sources/WALIModel/Assets/*.swift`
- Create: `Packages/WALICore/Sources/WALIModel/Displays/*.swift`
- Create: `Packages/WALICore/Sources/WALIModel/Playback/*.swift`
- Create: `Packages/WALICore/Sources/WALIModel/Jobs/*.swift`
- Create: corresponding focused tests under `WALIModelTests`
- Create: `docs/design/2026-08-31-wali-model.md`
- Modify: model compatibility/module inventories and architecture policy fixtures

**Steps:**
1. Write failing round-trip tests for explicit schema versions and stable raw values.
2. Model immutable `AssetRelease`, content-addressed `Artifact`, user `LibraryItem`, device-local display record/aliases, and presentation policy separately.
3. Model playback preparation, desired running state, user pause, automatic reason set, quality tier, and failure independently.
4. Model a concrete durable job header and import aggregate with generation,
   cancellation linearization, cleanup retention, and one write-once terminal
   outcome; do not introduce a generic payload/result job.
5. Add transition-table tests for duplicate, stale, cancellation, retry, and crash-recovery inputs.
6. Run the package and architecture suites.

**Evidence:**
- The pre-implementation package run failed on the intentionally missing
  `AssetRelease`, `PlaybackState`, `ImportJob`, reducers, and related values.
- The compatibility-policy red run failed on the intentionally unknown
  `model_records` surface and missing golden/invalid-fixture enforcement.
- `swift test --package-path Packages/WALICore` passes 55 tests in 5 Swift
  Testing suites.
- `Tests/Architecture/check-architecture-tests.sh` passes 143 mutation cases,
  and `scripts/check-architecture.sh` passes against the real repository.
- `make clean && make verify` passes, including four hostless Xcode unit tests,
  Debug build, and Debug bundle verification.
- The credential-free Release build and bundle verification pass. Public symbol
  extraction reports 50 public structs and 22 public enums in WALIModel, with
  no public class, protocol, generic stable ID/job, or reducer entry point.

## Task 5: Implement explicit bounded wire envelopes

**Files:**
- Create: `Packages/WALICore/Sources/WALIWire/Envelope/*.swift`
- Create: `Packages/WALICore/Sources/WALIWire/Agent/*.swift`
- Create: `Packages/WALICore/Sources/WALIWire/MediaWorker/*.swift`
- Create: fixtures under `Packages/WALICore/Tests/WALIWireTests/Fixtures/`

**Steps:**
1. Write failing golden-fixture tests for protocol N and N−1 decoding.
2. Add envelopes carrying protocol version, message type/version, request ID, idempotency key, expected revision, and bounded payload bytes.
3. Use stable integer/string wire tags; never rely on synthesized enum layout.
4. Reject unknown critical messages, oversized payloads, duplicate fields, invalid identifiers, and unsupported newer writer versions.
5. Add sequenced snapshots and gap-triggered full resynchronization.
6. Run malformed-input, size-bound, compatibility, and round-trip tests.

## Task 6: Implement Engine-owned command and job semantics

**Files:**
- Create: `Packages/WALICore/Sources/WALIEngine/LibraryUseCases.swift`
- Create: `Packages/WALICore/Sources/WALIEngine/PresentationUseCases.swift`
- Create: `Packages/WALICore/Sources/WALIEngine/CommandProcessor.swift`
- Create: `Packages/WALICore/Sources/WALIEngine/ImportJobs/*.swift`
- Create: corresponding tests under `WALIEngineTests`

**Steps:**
1. Write failing tests for idempotent commands, expected-revision rejection, and one durable terminal result.
2. Implement a pure command processor returning events/results without I/O.
3. Add narrow `LibraryUseCases` and `PresentationUseCases`; avoid generic CRUD repositories.
4. Add import orchestration interfaces for a durable store, artifact verifier/publisher, and bounded media worker.
5. Prove stale worker completions cannot install and main-app disconnect does not cancel accepted jobs.
6. Run package tests and strict-concurrency builds.

## Task 7: Prove the XPC lifecycle seam

**Files:**
- Create: `Sources/WALIIPC/`
- Create: `Tests/WALIIPCTests/`
- Create: `Config/WALIAgent-LaunchAgent.plist`
- Modify: `project.yml`
- Modify: `Sources/WALIAgentRuntime/`
- Modify: `Sources/WALIAppRuntime/`
- Modify: `Sources/WALITranscoderRuntime/`

**Steps:**
1. Write failing adapter tests around a transport-neutral `AgentGateway`.
2. Define Objective-C-compatible XPC methods using `Data` envelopes and explicit progress/reply sinks.
3. Configure interfaces, exported objects, payload limits, interruption/invalidation handling, and activation order before resuming connections.
4. Package a launchd-published, configuration-specific Mach service for the agent; do not persist anonymous endpoints.
5. Add code-signature requirement evaluation before accepting a peer.
6. Add protocol-skew, duplicate-request, malformed/oversized, interruption, and stale-snapshot tests.
7. Run unsigned adapter tests. Run signed lifecycle tests only when an authorized Development team is available; report that gate honestly otherwise.

## Task 8: Define crash-recoverable content storage before SQLite behavior

**Files:**
- Create: `Sources/WALIStorage/`
- Create: `Tests/WALIStorageTests/`
- Create: `Fixtures/Storage/`
- Modify: `project.yml`

**Steps:**
1. Write failing recovery tests for a crash after each install transition.
2. Define object paths by verified SHA-256 digest and immutable artifact metadata.
3. Implement the journal states `staged → verified → prepared → published → committed`.
4. Make every transition idempotent; reconcile files and metadata after restart.
5. Add leases/tombstones so renderers retain artifacts while deletion completes.
6. Reject path traversal, symlink escape, digest mismatch, stale generations, and unknown newer schemas.
7. Keep SQLite agent-private and expose only Engine transactions.
8. Run temporary-directory tests, crash injection, migration tests, and cleanup audits.

## Task 9: Resume the desktop vertical slice through Engine interfaces

**Files:**
- Supersede Tasks 2–18 in `docs/plans/2026-08-30-wali-foundation.md` with a revised renderer/import plan.

**Steps:**
1. Define capability-based `WallpaperRenderer` and pure adaptive energy policy.
2. Implement deterministic display reconciliation with persistent display fingerprints.
3. Build AppKit window and AVFoundation session ownership behind the agent runtime.
4. Route apply/pause/stop/import through Engine use cases and wire snapshots.
5. Implement media analysis/conversion against immutable attempts and artifact claims.
6. Build menu-bar diagnostics and main-window library on the same snapshot model.
7. Keep dynamic HEIC, catalog, schedules, lock-screen adapter, and procedural renderers as later production adapters, not empty frameworks.

## Verification gate before feature work

```bash
make clean
make check-architecture
make verify
CONFIGURATION=Release ./scripts/build.sh
CONFIGURATION=Release ./scripts/verify-bundle.sh
```

In addition:

- No WALI process remains after tests.
- Main app contains no XPC service.
- Agent contains exactly one transcoder XPC service.
- No internal dynamic framework is embedded.
- Package target graph matches `docs/architecture/modules.yml`.
- No accepted behavior relies on a signing capability that was only compiled, not exercised.

Commits are intentionally omitted from this plan until the repository owner explicitly authorizes them.
