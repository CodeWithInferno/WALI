# WALI Architecture and Product Design

**Date:** 2026-08-30  
**Status:** Product/design history; scoped architecture sections are superseded as noted  
**Reference:** Clean-room study of Cindori Backdrop 2.6.17 and documented macOS behavior  
**Visual system:** [`DESIGN.md`](../../DESIGN.md)

> **Architecture hardening note:** Product intent, UI behavior, and performance
> budgets in this document remain useful. For module boundaries, process
> ownership, transcoder containment, IPC discovery/authentication, and storage
> publication, [`ARCHITECTURE.md`](../../ARCHITECTURE.md) and accepted ADRs
> supersede the earlier implementation sketches below.

## 1. Goal

Build WALI as an original, native macOS live-wallpaper product that:

- makes local video import effortless;
- presents a polished wallpaper library and future licensed catalog;
- renders efficiently across Spaces and multiple displays;
- can integrate compatible assets with the current user's session lock screen;
- exposes honest CPU, memory, and storage information;
- keeps rendering when the catalog window closes; and
- feels like a first-party Mac application rather than a web interface in a desktop wrapper.

## 2. Decisions

> **Historical decision snapshot:** Process separation and video-first/public
> desktop direction remain useful. ADR 0004 supersedes the broad shared-core
> boundary and makes the worker target agent-private; ADR 0006 governs the
> proposed named/authenticated app↔agent channel. Lock-screen work is deferred.

1. **Video-first, not procedural-first.** User videos and curated video assets are WALI's primary medium. A Metal/procedural format can be added later without blocking the core product.
2. **Native Swift 6.** SwiftUI owns application surfaces; AppKit owns desktop windows and lifecycle details; AVFoundation and VideoToolbox own media playback and hardware codecs.
3. **Two persistent applications, one on demand.**
   - `WALI.app` is the normal catalog, import, and settings application.
   - `WALIAgent.app` is an embedded login item with `LSUIElement=true`. It owns the menu-bar extra and wallpaper renderer and remains lightweight when the main window is closed.
4. **An on-demand transcoder.** `WALITranscoder.xpc` performs expensive analysis, encoding, and thumbnail work out of process, then exits.
5. **Public desktop APIs first.** Desktop rendering uses one noninteractive AppKit window per connected display at `kCGDesktopWindowLevel - 1`.
6. **Lock-screen support is a versioned compatibility adapter.** It is isolated behind capability checks because Apple's per-user Aerials store is undocumented and can change between macOS releases.
7. **Local-first and telemetry-free by default.** Remote catalog infrastructure is a separate phase. Local wallpapers work without an account or network.

## 3. Security boundaries and hard limits

### Supported

- The current logged-in user's desktop.
- All connected displays and macOS Spaces in that user session.
- Future session lock-screen playback only on explicitly tested macOS versions
  after the deferred adapter and fixture gate are approved.
- Per-user launch at login after macOS records the person's consent.
- A shared asset directory for multiple users only as a later, explicit administrator-enabled feature.

### Not bypassable by an ordinary app

- **FileVault preboot:** Before the startup volume is unlocked, user files, WALI, launch agents, and normal WindowServer sessions are unavailable. WALI cannot render there.
- **Other users without their consent:** Each account has a separate GUI session and login-item approval. One user cannot silently install a live renderer into every other account.
- **System-owned login UI:** WALI does not inject into or patch `loginwindow`, WindowServer, or protected system components.

“Install for all users” can eventually share approved media under `/Users/Shared/WALI`, but every user must still enable WALI in their own session. It does not alter FileVault or the preboot screen.

## 4. System topology

> **Historical architecture sketch:** This diagram predates Engine ownership,
> the package split, and agent-private worker containment. Use the explicit
> current/target graphs in [`ARCHITECTURE.md`](../../ARCHITECTURE.md) and ADRs
> [0004](../adr/0004-engine-owned-use-cases.md) and
> [0006](../adr/0006-named-authenticated-xpc.md).

```text
┌──────────────────────────────────────────────────────────────────┐
│ WALI.app — normal foreground application                         │
│ Library UI · catalog · import · settings · diagnostics           │
└───────────────────────┬───────────────────────────┬──────────────┘
                        │ NSXPCConnection           │ on-demand XPC
                        ▼                           ▼
┌──────────────────────────────────────┐  ┌─────────────────────────┐
│ WALIAgent.app — LSUIElement login    │  │ WALITranscoder.xpc      │
│ item                                 │  │ AVAssetReader/Writer     │
│                                      │  │ VideoToolbox             │
│ MenuBarExtra · display coordinator   │  │ HEVC/preview/poster      │
│ AppKit wallpaper windows · players   │  │ generation               │
│ power/occlusion policy · metrics     │  └─────────────┬───────────┘
└───────────────────┬──────────────────┘                │
                    │                                   │
                    └────────────┬──────────────────────┘
                                 ▼
                    ┌──────────────────────────────┐
                    │ Shared application-group     │
                    │ SQLite metadata · manifests  │
                    │ normalized media · previews  │
                    │ settings · bounded logs      │
                    └──────────────┬───────────────┘
                                   │ compatible OS only
                                   ▼
                    ┌──────────────────────────────┐
                    │ LockScreenAdapter            │
                    │ per-user Apple wallpaper     │
                    │ manifest + APFS clone        │
                    └──────────────────────────────┘
```

### Target identifiers

Use these local identifiers until product signing credentials require a final prefix:

- Main app: `com.wali.WALI`
- Agent: `com.wali.WALIAgent`
- Transcoder: `com.wali.WALITranscoder`
- Shared group: `group.com.wali.shared`

Changing the prefix after user data ships requires migration and is therefore a pre-release decision.

## 5. Shared modules

> **Historical module sketch:** `WALICore` and the generic protocol list below
> are superseded by `WALIModel`, `WALIWire`, `WALIEngine`, and the stable seams
> in [`ARCHITECTURE.md`](../../ARCHITECTURE.md). Current/planned presence lives
> in [`modules.yml`](../architecture/modules.yml).

`WALICore` is a local Swift package consumed by every target. It contains no SwiftUI screen code.

### Domain

- `WallpaperAsset`
- `WallpaperVariant`
- `WallpaperAssignment`
- `DisplayIdentity`
- `PlaybackState`
- `ImportJob`
- `LockScreenCapability`
- `ResourceSample`

### Services and protocols

- `AssetRepository`
- `AssignmentRepository`
- `DisplayProviding`
- `PlayerProviding`
- `PowerStateProviding`
- `ResourceSampling`
- `Transcoding`
- `LockScreenInstalling`
- `AgentControlling`

Concrete AppKit, AVFoundation, SQLite, XPC, and system implementations conform to these protocols. Deterministic fakes support tests without creating real wallpaper windows.

## 6. Wallpaper agent

### Display coordination

`DisplayCoordinator` treats `NSScreen.screens` as the connected-hardware truth.

- Keep assignments for disconnected displays.
- Create a `WallpaperSession` only for a connected display with an assignment.
- Tear down its window, player, observations, and decoded surfaces immediately after disconnect.
- Recreate the session when a known display reconnects.
- Debounce display-topology notifications before reconciling.

Stable display identity uses `CGDirectDisplayID` plus vendor/product/serial metadata where available. Never use array position as identity.

### Wallpaper window

Each session owns a borderless `NSWindow`:

- frame equals the display bounds;
- level equals `CGWindowLevelForKey(.desktopWindow) - 1`;
- background is opaque black until the poster is ready;
- ignores mouse events;
- is excluded from ordinary window cycling;
- participates in all Spaces and remains stationary;
- contains a poster layer and `AVPlayerLayer`;
- releases its player and content on teardown.

The exact collection-behavior set is finalized through an integration test on macOS 15 and 26 rather than copied from a private implementation.

### Playback

- `AVQueuePlayer` and `AVPlayerLooper` provide native seamless looping.
- Audio tracks are removed during normalization and the player remains muted.
- Video gravity is configurable per assignment: fill, fit, or stretch-disabled crop.
- The poster remains visible while paused, preparing, or recovering.
- A replacement player reaches ready-to-display before the old layer crossfades out.

### State machine

```text
stopped → preparing → playing
              │          │
              ▼          ▼
            failed ← automaticallyPaused
                         │
                         ▼
                     userPaused
```

Pause reasons are a set, not one Boolean:

- user request;
- session locked;
- system sleep;
- display asleep;
- window not visible/occluded;
- low-power policy;
- thermal pressure;
- asset transition.

Playback resumes only after every automatic reason clears and the user has not paused it.

### Power policy

- Observe workspace sleep/wake and screen sleep/wake notifications.
- Pause before sleep and rebuild timing after wake.
- Observe lock/unlock and active console session changes.
- Pause hidden main-window previews immediately.
- In Low Power Mode, follow the user's setting: continue, reduce frame rate on the next encode, or pause.
- Under serious/critical thermal pressure, pause video and retain the poster.
- Coalesce redundant state changes.

## 7. Menu-bar and toolbar status

The persistent global control is a SwiftUI `MenuBarExtra` hosted by `WALIAgent.app` with window/popover style.

The same `StatusPanel` view is embedded in a trailing toolbar popover in `WALI.app`. This satisfies both use cases without maintaining two visual implementations.

### Status content

- Current wallpaper title and thumbnail.
- Number of active displays.
- Explicit playback state.
- Agent CPU percentage.
- Agent physical-memory footprint.
- Pause/Resume, Next, and Open WALI.
- Stop Wallpaper, Settings, and Quit WALI.

`Stop Wallpaper` and `Quit WALI` remain separate commands.

### Metrics

- Read only WALI-owned process information.
- Match Activity Monitor's useful convention where one fully occupied core is approximately 100% CPU.
- Show physical footprint for memory, not a misleading sum of virtual address space.
- Sample at 1 Hz only while a status or diagnostics surface is visible.
- Keep a bounded 60-sample in-memory history for the visible sparkline.
- Suspend sampling and discard history after the last diagnostics observer closes.

On macOS 26, onboarding checks whether the menu-bar item is visible and directs the user to **System Settings → Menu Bar** if macOS has disabled it.

## 8. Main application

The complete visual and interaction contract lives in [`DESIGN.md`](../../DESIGN.md).

### Information architecture

- **Discover:** curated remote collection in a later network phase; local editorial samples during foundation work.
- **Library:** installed and imported assets.
- **Playlists:** ordered or scheduled wallpaper sets.
- **Downloads:** active, queued, failed, and completed transfers/conversions.
- **Create:** drag/drop and file import.

Settings uses the native Settings scene and `⌘,`.

### Core interaction

- A standard `NavigationSplitView` and unified toolbar.
- Search, display assignment, and status in toolbar roles.
- Large 16:10 image/video tiles with subdued metadata.
- Only one low-resolution hover preview decodes at once.
- Space opens preview; Return applies; double click applies.
- Dragging a video into the window starts validated import.
- Context menus expose Apply, Assign to Display, Add to Playlist, Reveal in Finder, and Delete.
- Destructive deletion uses confirmation when the asset is assigned or installed on the lock screen.
- Native undo restores assignment and playlist changes.

### Visual identity

Use native Liquid Glass only for controls and navigation. The selected wallpaper can extend beneath the sidebar to create WALI's “Ambient Edge,” allowing system material to reflect the artwork. Content tiles themselves are not glass.

## 9. Import and conversion

> **Historical pipeline sketch:** The atomic-move/transaction sequence below is
> not the durability contract. ADR
> [0005](../adr/0005-content-addressed-artifacts.md) and
> [`docs/migrations.md`](../migrations.md) define durable intent, attempt
> generations, descriptor-bound verification, same-volume no-replace
> publication, and recovery.

The user experience is one action: select or drop a video. WALI handles the technical format.

### Pipeline

1. Acquire a security-scoped URL or normal file URL.
2. Validate readability, duration, dimensions, tracks, frame rate, and estimated output size.
3. Compute a streaming SHA-256 fingerprint to deduplicate without loading the file into memory.
4. Build a deterministic conversion plan.
5. Write outputs into a temporary job directory.
6. Generate normalized HEVC, low-resolution preview, and HEIC poster.
7. Verify every output can be opened and matches its checksum.
8. Atomically move the completed asset directory into the library.
9. Commit metadata in one SQLite transaction.
10. Remove the temporary directory on success, cancellation, crash recovery, or failure.

The source file is not retained by default after verified conversion. A “Keep originals” preference is opt-in.

### Profiles

Initial measured profiles:

- **Desktop master:** HEVC hardware encode, 10-bit where the source and hardware support it, up to display-appropriate 4K, up to 30 fps, no audio.
- **Grid preview:** hardware HEVC, 720p, up to 24 fps, short loop or bounded bitrate.
- **Poster:** HEIC at the selected representative frame.
- **Lock-screen master:** version-specific HEVC Main 10 profile with the temporal/sample-group metadata required by the compatible Apple wallpaper adapter.

Exact bitrates are selected from visual-quality tests and capped by resolution and motion complexity. WALI never upscales solely to claim “4K.”

### Cancellation and recovery

- Cancellation is cooperative between frames/chunks.
- Partial files never appear in the library.
- On launch, directories under `Staging/` older than the active job set are removed.
- Every import job has a stable ID and persisted terminal state.
- Errors preserve the user's source and state the failed stage.

## 10. Lock-screen adapter

> **Deferred historical design:** No lock-screen adapter is implemented or
> scheduled before the public desktop path. The compatibility inventory marks
> this surface deferred; a separate accepted ADR and copied-fixture gate are
> required before implementation.

This feature targets the **session lock screen**, not FileVault preboot.

### Design

- `LockScreenCapabilityDetector` keys support by exact macOS build ranges verified in tests.
- Each supported range has its own adapter.
- Installation writes only inside the current user's Library.
- Manifest changes are built in memory, schema-validated, written to a sibling temporary file, fsynced, and atomically renamed.
- Existing Apple files are backed up before the first WALI edit and never overwritten by an incompatible schema.
- WALI namespaces every injected category and asset UUID.
- Media is installed with APFS `clonefile` when possible and copied as a fallback. Hard links are avoided.
- Uninstall removes only UUIDs and files WALI owns.
- A transaction journal enables rollback after interruption.

### Failure policy

If the schema, ownership, macOS build, or required codec metadata differs from what WALI has tested, the adapter refuses to write and desktop wallpaper remains available. “Unsupported on this macOS build” is safer than corrupting the user's wallpaper store.

## 11. Storage model

> **Historical layout sketch:** The mutable asset-ID layout below is superseded
> by ADR [0005](../adr/0005-content-addressed-artifacts.md). The actual content
> store is unimplemented; its target SHA-256 layout is inventoried in
> [`surfaces.yml`](../compatibility/surfaces.yml).

```text
Shared Group/
├── Library.sqlite
├── Assets/<asset-id>/
│   ├── manifest.json
│   ├── master.mov
│   ├── preview.mov
│   └── poster.heic
├── Staging/<job-id>/
├── Backups/LockScreen/<os-build>/
└── Logs/
```

SQLite uses WAL mode, foreign keys, explicit migrations, and one writer actor. Binary media never enters the database.

Every stored file is referenced by a database row or recognized staging transaction. A maintenance audit reports and safely removes unreferenced WALI-owned files. Cache and library sizes are visible in Settings.

## 12. Remote catalog phase

The foundation does not require a backend. When introduced, the catalog uses:

- signed, versioned JSON manifests;
- immutable CDN asset URLs addressed by checksum;
- separate poster, preview, and full variants;
- resumable downloads;
- creator, license, attribution, and moderation metadata;
- client-side checksum and signature verification;
- bounded cache eviction that never deletes explicitly saved assets.

WALI will not scrape or redistribute Backdrop's catalog.

## 13. Privacy and distribution

- No telemetry in the foundation release.
- Unified logging is local, privacy-redacted, and bounded.
- Network access is absent until the catalog phase.
- Hardened runtime and Developer ID notarization are release requirements.
- Direct distribution is expected because desktop-level windows, login-item behavior, and the experimental lock-screen adapter require capabilities that are a poor fit for the Mac App Store sandbox.
- The app never requests Accessibility, Screen Recording, or Full Disk Access for ordinary wallpaper operation.

## 14. Observability

Use `Logger` categories:

- lifecycle;
- display;
- playback;
- import;
- lock screen;
- storage;
- xpc;
- performance.

Use signposts for player preparation, first frame, transitions, encode stages, and manifest transactions. Exported diagnostics redact user paths and contain no media.

## 15. Performance budgets

Budgets are acceptance targets, not unverified claims. Record hardware, display count, resolution, codec, power mode, and macOS build with every result.

- Agent paused: median CPU below 0.2% over 10 minutes.
- One 4K/30 HEVC wallpaper on Apple silicon: median process CPU below 3%, p95 below 7%.
- Agent physical footprint: below 140 MB for one active display after warmup; no more than 45 MB incremental per additional independent player.
- Main app physical footprint after library settles: below 220 MB with 500 assets.
- Menu-bar metrics overhead: below 0.2% CPU while visible and effectively zero while closed.
- Cached first frame: visible within 500 ms of assignment.
- Eight-hour playback: physical-footprint slope below 10 MB after the first 15-minute warmup.
- Repeated 100-cycle apply/stop test: no leaked wallpaper windows, players, observers, or file descriptors.
- Cancelled/failed imports: zero untracked files after recovery.

If independent playback on several displays misses the budget, investigate one decoded frame source fan-out through `AVPlayerItemVideoOutput` and Metal as a measured optimization—not as V1 complexity.

## 16. Test strategy

### Unit

- playback-state transition table;
- pause-reason composition;
- display reconciliation;
- import-plan selection;
- deduplication and storage accounting;
- schema migrations;
- lock-screen capability gating;
- manifest merge and rollback;
- resource-sampler arithmetic;
- menu command semantics.

### Integration

- XPC connection, reconnection, and agent relaunch;
- temporary SQLite store and crash recovery;
- AVFoundation fixture analysis and conversion;
- real `NSWindow` creation/teardown on a test display session;
- sleep/wake and display-change notification handling through injectable sources;
- APFS clone fallback;
- lock-screen adapter against copied fixture stores only.

### UI and accessibility

- navigation, import, apply, pause, stop, and delete paths;
- keyboard-only operation;
- VoiceOver labels and order;
- minimum/default/wide window layouts;
- light, dark, graphite, increased contrast, reduced transparency, and reduced motion;
- menu-bar popover with every playback state.

### Endurance

- 8-hour active loop;
- 100 apply/stop cycles;
- 100 connect/disconnect reconciliation cycles with fakes plus manual hardware verification;
- 50 cancelled imports;
- sleep/wake and lock/unlock loops;
- Instruments Allocations, Leaks, Energy Log, and file-descriptor checks.

## 17. Delivery sequence

> **Superseded execution sequence:** Preserve this section as design history,
> but execute the
> [architecture-hardening plan](../plans/2026-08-30-wali-architecture-hardening.md)
> instead.

1. Repository, native project, shared domain, and CI.
2. Agent lifecycle and tested desktop-level static poster windows.
3. AVFoundation loop playback and power state machine.
4. XPC contract, menu-bar status, and demand-driven metrics.
5. Native main-window shell and local library.
6. Test-driven import/transcode pipeline.
7. Multi-display assignment, playlists, and storage maintenance.
8. Experimental version-gated session lock-screen adapter.
9. Endurance/performance hardening.
10. Signed catalog and creator pipeline.

The first shippable milestone is local import + efficient desktop rendering + menu-bar control. Lock-screen compatibility follows after the desktop path meets its stability budgets.
