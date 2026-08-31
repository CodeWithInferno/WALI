# WALI Foundation Implementation Plan

> **Superseded for execution:** This plan is retained as useful design and
> sequencing history. Do not execute Tasks 2–18 as written. The
> [architecture-hardening plan](2026-08-30-wali-architecture-hardening.md),
> `ARCHITECTURE.md`, and accepted ADRs now govern module ownership, IPC,
> transcoder containment, storage, and the revised vertical-slice sequence.

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Deliver WALI's first shippable vertical slice: import a local video, normalize it, render it efficiently across Mac displays, and control it from a native main window and menu-bar panel.

**Architecture:** `WALI.app` is the normal SwiftUI library application. An embedded `LSUIElement` login item, `WALIAgent.app`, owns the persistent menu-bar extra and AppKit wallpaper windows. Pure domain logic and IPC payloads live in `WALICore`; reusable status UI lives in `WALIUI`; an on-demand XPC service isolates expensive media conversion.

**Tech Stack:** macOS 15+, Xcode 26.2, Swift 6.2, SwiftUI, AppKit, AVFoundation, VideoToolbox, SQLite3, ServiceManagement, OSLog, Swift Testing, XCTest, XcodeGen.

**Design:** Follow [`DESIGN.md`](../../DESIGN.md) and [`docs/design/2026-08-30-wali-architecture-and-product.md`](../design/2026-08-30-wali-architecture-and-product.md).

---

## Rules for execution

- Follow red-green-refactor for every production behavior.
- Keep system frameworks behind protocols so tests do not manipulate the real desktop.
- Use only Apple runtime frameworks in this milestone.
- Never run lock-screen tests against the user's live Apple wallpaper store.
- After each focused test, run the full affected suite.
- Do not commit unless the user has explicitly authorized commits.

## Planned repository shape

```text
Config/
Fixtures/Media/
Packages/WALICore/
Sources/WALIApp/
Sources/WALIAgent/
Sources/WALITranscoder/
Sources/WALIUI/
Tests/WALIAppTests/
Tests/WALIAgentTests/
Tests/WALITranscoderTests/
Tests/WALIUITests/
UITests/WALIEndToEndTests/
scripts/
project.yml
Makefile
```

## Milestone 1 — Buildable native foundation

### Task 1: Generate the project and verification harness

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `project.yml`
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Create: `Config/WALI.entitlements`
- Create: `Config/WALIAgent.entitlements`
- Create: `Packages/WALICore/Package.swift`
- Create: `Packages/WALICore/Sources/WALICore/WALICore.swift`
- Create: `Sources/WALIApp/WALIApp.swift`
- Create: `Sources/WALIAgent/WALIAgentApp.swift`
- Create: `Sources/WALITranscoder/TranscoderService.swift`
- Create: `Sources/WALIUI/StatusPanel.swift`
- Create: `scripts/build.sh`
- Create: `scripts/test.sh`
- Create: `scripts/verify-bundle.sh`

**Steps:**
1. Write XcodeGen configuration for `WALI`, `WALIAgent`, `WALITranscoder`, `WALIUI`, unit-test targets, and one UI-test target.
2. Set Swift 6 strict concurrency, macOS 15 deployment, hardened-runtime release settings, and deterministic bundle identifiers.
3. Make `WALIAgent` an `LSUIElement` app and embed it under `WALI.app/Contents/Library/LoginItems`.
4. Embed the XPC service under `WALI.app/Contents/XPCServices`.
5. Generate `WALI.xcodeproj`.
6. Run `make build`.
7. Run `make test`.
8. Run `scripts/verify-bundle.sh` and assert both embedded products and their `Info.plist` keys.

**Expected verification:**

```bash
xcodegen generate
xcodebuild -project WALI.xcodeproj -scheme WALI \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/WALICore
```

Both commands exit 0; bundle verification finds one login item and one XPC service.

### Task 2: Define the domain and playback state machine

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Domain/WallpaperAsset.swift`
- Create: `Packages/WALICore/Sources/WALICore/Domain/DisplayIdentity.swift`
- Create: `Packages/WALICore/Sources/WALICore/Domain/WallpaperAssignment.swift`
- Create: `Packages/WALICore/Sources/WALICore/Playback/PlaybackState.swift`
- Create: `Packages/WALICore/Sources/WALICore/Playback/PlaybackReducer.swift`
- Create: `Packages/WALICore/Tests/WALICoreTests/PlaybackReducerTests.swift`
- Create: `Packages/WALICore/Tests/WALICoreTests/DomainCodableTests.swift`

**Steps:**
1. Write failing Codable round-trip tests for assets, displays, assignments, and IPC-safe snapshots.
2. Run `swift test --package-path Packages/WALICore`; confirm the types are missing.
3. Add minimal `Sendable`, `Codable`, `Equatable`, stable-ID value types.
4. Write a failing transition-table test covering prepare, ready, failure, user pause, automatic pause reasons, stop, and recovery.
5. Implement a pure reducer:

```swift
struct PlaybackModel: Equatable, Sendable {
    var phase: PlaybackPhase
    var automaticPauseReasons: Set<AutomaticPauseReason>
    var isUserPaused: Bool
}

enum PlaybackEvent: Equatable, Sendable {
    case prepare
    case becameReady
    case failed(PlaybackFailure)
    case setUserPaused(Bool)
    case setAutomaticPause(AutomaticPauseReason, active: Bool)
    case stop
}
```

6. Verify automatic reasons compose rather than overwrite one another.
7. Run the full package suite.

### Task 3: Reconcile assignments with connected displays

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Display/DisplayReconciler.swift`
- Create: `Packages/WALICore/Tests/WALICoreTests/DisplayReconcilerTests.swift`
- Create: `Sources/WALIAgent/System/NSScreenDisplayProvider.swift`
- Create: `Tests/WALIAgentTests/NSScreenDisplayProviderTests.swift`

**Steps:**
1. Write failing pure tests for connect, disconnect, reconnect, assignment change, and duplicate-notification cases.
2. Implement `DisplayReconciler` to return explicit `.start`, `.update`, and `.stop` operations.
3. Verify disconnected display assignments remain persisted but have no running session.
4. Write adapter tests for extracting stable IDs and bounds from injected screen descriptors.
5. Implement `NSScreenDisplayProvider` without using screen-array position as identity.
6. Run package and agent tests.

## Milestone 2 — Efficient desktop renderer

### Task 4: Create and tear down wallpaper windows

**Files:**
- Create: `Sources/WALIAgent/Wallpaper/WallpaperWindow.swift`
- Create: `Sources/WALIAgent/Wallpaper/WallpaperWindowFactory.swift`
- Create: `Sources/WALIAgent/Wallpaper/WallpaperSession.swift`
- Create: `Tests/WALIAgentTests/WallpaperWindowFactoryTests.swift`
- Create: `Tests/WALIAgentTests/WallpaperSessionLifetimeTests.swift`

**Steps:**
1. Write failing tests against an injected `WindowProtocol` recorder for frame, level, mouse handling, collection behavior, and teardown.
2. Implement the factory with `CGWindowLevelForKey(.desktopWindow) - 1`.
3. Add a poster `CALayer` that remains present while no video frame is ready.
4. Implement idempotent `stop()` that removes observations, pauses playback, clears layers, orders out, and closes the window.
5. Run 100 in-memory start/stop cycles and assert equal create/destroy counts.
6. Add one opt-in manual integration test that enumerates WALI windows and validates their WindowServer level without changing the user's wallpaper assignment.

### Task 5: Add seamless AVFoundation playback

**Files:**
- Create: `Sources/WALIAgent/Playback/PlayerProtocol.swift`
- Create: `Sources/WALIAgent/Playback/LoopingVideoPlayer.swift`
- Create: `Sources/WALIAgent/Playback/PlayerFactory.swift`
- Create: `Tests/WALIAgentTests/LoopingVideoPlayerTests.swift`
- Add: `Fixtures/Media/loop-fixture.mov`

**Steps:**
1. Generate a tiny, original test fixture with VideoToolbox-compatible HEVC and no audio.
2. Write failing lifecycle tests with a fake queue player: prepare, ready, play, pause, replace, and release.
3. Implement `AVQueuePlayer` + `AVPlayerLooper` behind `PlayerProtocol`.
4. Set `preventsDisplaySleepDuringVideoPlayback = false` and mute playback.
5. Write a failing transition test proving the old poster/player stays visible until the replacement is ready.
6. Implement a reduced-motion-aware crossfade; switch immediately when Reduce Motion is enabled.
7. Run the complete agent suite and a real fixture smoke test.

### Task 6: Implement automatic pause and power policy

**Files:**
- Create: `Sources/WALIAgent/System/PowerEventSource.swift`
- Create: `Sources/WALIAgent/Playback/PlaybackPolicyController.swift`
- Create: `Tests/WALIAgentTests/PlaybackPolicyControllerTests.swift`

**Steps:**
1. Write failing tests for sleep/wake, screen sleep/wake, session lock/unlock, occlusion, Low Power Mode, and thermal pressure.
2. Verify one cleared reason cannot resume playback while another reason remains.
3. Implement injected notification adapters for `NSWorkspace`, `ProcessInfo`, and window occlusion.
4. Debounce noisy occlusion changes and coalesce identical state updates.
5. Keep the poster visible while video decoding is paused.
6. Run the state-machine and agent suites.

## Milestone 3 — Agent control and diagnostics

### Task 7: Measure WALI CPU and physical memory on demand

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Diagnostics/ResourceSample.swift`
- Create: `Sources/WALIAgent/Diagnostics/ProcessResourceSampler.swift`
- Create: `Sources/WALIAgent/Diagnostics/DemandDrivenSampler.swift`
- Create: `Tests/WALIAgentTests/ProcessResourceSamplerTests.swift`
- Create: `Tests/WALIAgentTests/DemandDrivenSamplerTests.swift`

**Steps:**
1. Write failing arithmetic tests using injected cumulative CPU times and monotonic timestamps.
2. Define one full core as approximately 100% and guard zero/negative intervals.
3. Read the current process's physical footprint through Mach task information.
4. Write failing clock tests proving sampling starts with the first observer, runs at 1 Hz, and stops after the last observer.
5. Keep at most 60 samples in memory and discard history after diagnostics closes.
6. Benchmark visible and hidden sampler overhead.

### Task 8: Build the typed agent control channel

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/IPC/AgentCommand.swift`
- Create: `Packages/WALICore/Sources/WALICore/IPC/AgentSnapshot.swift`
- Create: `Sources/WALIAgent/IPC/AgentService.swift`
- Create: `Sources/WALIApp/IPC/AgentClient.swift`
- Create: `Tests/WALIAgentTests/AgentServiceTests.swift`
- Create: `Tests/WALIAppTests/AgentClientTests.swift`

**Steps:**
1. Write failing Codable tests for snapshot and commands.
2. Define commands for snapshot, apply, pause/resume, next, stop wallpaper, and terminate agent.
3. Write failing service tests for every command using fake coordinator/repository dependencies.
4. Implement an anonymous `NSXPCListener` endpoint published in the shared container.
5. Implement reconnect and stale-endpoint handling in the main app.
6. Validate connecting clients belong to the same signed WALI product before accepting commands.
7. Run service, reconnection, malformed-payload, and interruption tests.

### Task 9: Register and manage the login item

**Files:**
- Create: `Sources/WALIApp/Services/AgentLifecycleController.swift`
- Create: `Tests/WALIAppTests/AgentLifecycleControllerTests.swift`
- Modify: `Sources/WALIApp/WALIApp.swift`
- Modify: `Sources/WALIAgent/WALIAgentApp.swift`

**Steps:**
1. Write failing tests against an injected `SMAppService` wrapper.
2. Implement explicit states: not registered, requires approval, enabled, unavailable, and failed.
3. Register only after onboarding explains persistence and the user enables it.
4. Make closing the main window leave the agent running.
5. Make Quit WALI terminate both products; make Stop Wallpaper preserve both.
6. Add recovery UI for macOS login-item and menu-bar visibility settings.
7. Verify the helper bundle is discoverable and launchable from a built app.

## Milestone 4 — Apple-quality control surfaces

### Task 10: Build the reusable status panel and menu-bar extra

**Files:**
- Replace: `Sources/WALIUI/StatusPanel.swift`
- Create: `Sources/WALIUI/StatusPanelModel.swift`
- Create: `Tests/WALIUITests/StatusPanelModelTests.swift`
- Create: `Sources/WALIAgent/MenuBar/WALIMenuBarScene.swift`
- Modify: `Sources/WALIAgent/WALIAgentApp.swift`

**Steps:**
1. Write failing model tests for every playback state and control label.
2. Implement one semantic `StatusPanelModel`; do not put business logic in the view.
3. Render active wallpaper, display count, CPU, physical memory, Pause/Resume, Next, Open WALI, Stop Wallpaper, Settings, and Quit.
4. Host it in `MenuBarExtra(...).menuBarExtraStyle(.window)`.
5. Add VoiceOver labels, keyboard navigation, monospaced metric digits, and reduced-transparency behavior.
6. Verify sampling activates only while the panel appears.
7. Capture light, dark, increased-contrast, and reduced-transparency screenshots for design review.

### Task 11: Build the native main-window shell

**Files:**
- Create: `Sources/WALIApp/Navigation/AppDestination.swift`
- Create: `Sources/WALIApp/Navigation/AppModel.swift`
- Create: `Sources/WALIApp/Views/RootView.swift`
- Create: `Sources/WALIApp/Views/SidebarView.swift`
- Create: `Sources/WALIApp/Views/LibraryView.swift`
- Create: `Sources/WALIApp/Views/PlaceholderDestinationView.swift`
- Create: `Sources/WALIApp/Views/ToolbarStatusButton.swift`
- Create: `Sources/WALIApp/Settings/WALISettingsView.swift`
- Create: `Tests/WALIAppTests/AppModelTests.swift`
- Modify: `Sources/WALIApp/WALIApp.swift`

**Steps:**
1. Write failing navigation and command tests for Discover, Library, Playlists, Downloads, and Create.
2. Implement `NavigationSplitView`, native Settings scene, window restoration, and standard commands.
3. Add search, display assignment, and a trailing status-toolbar popover reusing `StatusPanel`.
4. Apply default 1120×720 and minimum 820×560 window sizes.
5. Extend wallpaper imagery beneath navigation material on macOS 26 using native APIs; use semantic material fallback on macOS 15.
6. Add `⌘F`, `⌘O`, Space, Return, `⌘⇧P`, `⌘,`, and `⌘Q`.
7. Run keyboard-only and VoiceOver UI tests.
8. Perform a screenshot critique against `DESIGN.md`; remove nonfunctional decoration.

## Milestone 5 — Asset library and automatic conversion

### Task 12: Add transactional asset storage

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Storage/AssetRepository.swift`
- Create: `Sources/WALIAgent/Storage/SQLiteAssetRepository.swift`
- Create: `Sources/WALIAgent/Storage/LibraryPaths.swift`
- Create: `Tests/WALIAgentTests/SQLiteAssetRepositoryTests.swift`
- Create: `Tests/WALIAgentTests/LibraryRecoveryTests.swift`

**Steps:**
1. Write failing repository contract tests using a temporary directory.
2. Add schema versioning for assets, variants, assignments, playlists, and import jobs.
3. Enable foreign keys and WAL mode.
4. Serialize all writes through the agent service.
5. Write failing recovery tests for incomplete staging folders and interrupted database transactions.
6. Implement atomic install and WALI-owned orphan cleanup.
7. Prove deleting an assigned asset is rejected until the assignment is changed or explicitly confirmed.

### Task 13: Analyze imports and select a conversion profile

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Import/MediaDescription.swift`
- Create: `Packages/WALICore/Sources/WALICore/Import/ConversionPlan.swift`
- Create: `Packages/WALICore/Sources/WALICore/Import/ConversionPlanner.swift`
- Create: `Packages/WALICore/Tests/WALICoreTests/ConversionPlannerTests.swift`
- Create: `Sources/WALITranscoder/MediaAnalyzer.swift`
- Create: `Tests/WALITranscoderTests/MediaAnalyzerTests.swift`

**Steps:**
1. Write a decision table for SDR/HDR, codec, dimensions, frame rate, duration, audio, and hardware availability.
2. Write one failing test per row.
3. Implement deterministic desktop-master, preview, and poster plans.
4. Never upscale; cap desktop output at 30 fps and remove audio.
5. Stream SHA-256 computation and reject unreadable/empty/nonvideo input with specific errors.
6. Verify estimates are bounded before the expensive encode starts.

### Task 14: Implement cancellable VideoToolbox conversion

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/Import/ImportProgress.swift`
- Replace: `Sources/WALITranscoder/TranscoderService.swift`
- Create: `Sources/WALITranscoder/VideoTranscoder.swift`
- Create: `Sources/WALITranscoder/PosterGenerator.swift`
- Create: `Sources/WALITranscoder/OutputVerifier.swift`
- Create: `Tests/WALITranscoderTests/VideoTranscoderTests.swift`
- Create: `Tests/WALITranscoderTests/ImportCancellationTests.swift`

**Steps:**
1. Write a failing end-to-end fixture test expecting a playable master, preview, poster, checksum, and no audio.
2. Implement `AVAssetReader`/`AVAssetWriter` with hardware HEVC through VideoToolbox.
3. Report stage and fractional progress through the XPC reply channel.
4. Write a failing cancellation test that interrupts mid-stream and expects no committed output.
5. Write outputs under `Staging/<job-id>` and verify them before atomic installation.
6. Add crash-recovery cleanup and deterministic terminal job states.
7. Record encode time, output size, codec, dimensions, bit depth, and frame rate in test artifacts.

### Task 15: Connect import, library browsing, preview, and apply

**Files:**
- Create: `Sources/WALIApp/Library/LibraryModel.swift`
- Create: `Sources/WALIApp/Import/ImportCoordinator.swift`
- Create: `Sources/WALIApp/Views/WallpaperTile.swift`
- Create: `Sources/WALIApp/Views/WallpaperDetailView.swift`
- Create: `Sources/WALIApp/Views/ImportProgressView.swift`
- Create: `Tests/WALIAppTests/LibraryModelTests.swift`
- Create: `Tests/WALIAppTests/ImportCoordinatorTests.swift`
- Modify: `Sources/WALIApp/Views/LibraryView.swift`
- Modify: `Sources/WALIApp/Views/RootView.swift`

**Steps:**
1. Write failing tests for file selection, drag/drop, progress, cancellation, deduplication, failure, and successful install.
2. Load thumbnails lazily and decode no full master in the grid.
3. Permit only one delayed 350 ms hover preview at a time.
4. Implement single-click selection, double-click apply, Space preview, and Return apply.
5. Add native context menus and undoable assignment changes.
6. Ensure closing the window during conversion does not lose job state.
7. Run the end-to-end UI flow with the original fixture.

## Milestone 6 — Multi-display, lock screen, and hardening

### Task 16: Complete multi-display assignment and persistence

**Files:**
- Create: `Sources/WALIApp/Displays/DisplayAssignmentModel.swift`
- Create: `Sources/WALIApp/Views/DisplayAssignmentPicker.swift`
- Create: `Tests/WALIAppTests/DisplayAssignmentModelTests.swift`
- Modify: `Sources/WALIAgent/Wallpaper/WallpaperSession.swift`

**Steps:**
1. Write failing tests for mirror, independent, disconnected, reconnected, and removed-display cases.
2. Persist stable assignments and retain disconnected display configuration.
3. Apply changes transactionally: prepare replacements first, then switch.
4. Verify a failed player on one display does not stop healthy displays.
5. Run 100 fake topology changes and inspect real three-display behavior manually.

### Task 17: Implement the version-gated session lock-screen adapter

**Files:**
- Create: `Packages/WALICore/Sources/WALICore/LockScreen/LockScreenCapability.swift`
- Create: `Sources/WALIAgent/LockScreen/LockScreenCapabilityDetector.swift`
- Create: `Sources/WALIAgent/LockScreen/AerialManifestAdapter.swift`
- Create: `Sources/WALIAgent/LockScreen/ManifestTransaction.swift`
- Create: `Tests/WALIAgentTests/Fixtures/LockScreen/`
- Create: `Tests/WALIAgentTests/LockScreenCapabilityTests.swift`
- Create: `Tests/WALIAgentTests/AerialManifestAdapterTests.swift`

**Steps:**
1. Copy sanitized fixture stores into the test target; never point tests at `~/Library/Application Support/com.apple.wallpaper`.
2. Write failing build-range capability tests.
3. Write failing merge, idempotency, collision, schema-drift, uninstall, interruption, and rollback tests.
4. Implement atomic sibling-file writes, `fsync`, backup, and transaction journal.
5. Use APFS `clonefile` when possible and a copy fallback; never hard-link library media.
6. Refuse live installation on unknown schema or macOS build.
7. Add an explicit Experimental label and explain that FileVault preboot is unsupported.
8. Manually verify enable, lock, unlock, disable, and rollback on the current test account.

### Task 18: Meet performance, stability, and accessibility gates

**Files:**
- Create: `scripts/endurance.sh`
- Create: `scripts/measure-resources.swift`
- Create: `docs/benchmarks/baseline.md`
- Create: `docs/release-checklist.md`
- Modify: `scripts/test.sh`

**Steps:**
1. Add deterministic 100-cycle start/stop, 50-cancel import, and topology stress commands.
2. Run an eight-hour renderer loop after shorter harness validation.
3. Capture median/p95 CPU, physical footprint, file descriptors, windows, players, and first-frame latency.
4. Use Instruments Allocations, Leaks, and Energy Log for manual evidence.
5. Verify light/dark, graphite, Increase Contrast, Reduce Transparency, Reduce Motion, Full Keyboard Access, and VoiceOver.
6. Verify sleep/wake, lock/unlock, main-window close/reopen, agent restart, and crash recovery.
7. Compare results with the budgets in the architecture document; fix regressions or document measured exceptions.
8. Run a clean checkout-equivalent generation, full test, build, and bundle verification.

## Milestone 7 — Later product expansion

These are separate plans after the local foundation is stable:

1. Signed remote catalog and CDN with creator/license metadata.
2. Resumable downloads and bounded cache eviction.
3. Creator workflow, moderation, and publishing.
4. Playlist schedules and time/battery-aware rotation.
5. Optional Metal/procedural wallpaper runtime.
6. Shared media for multiple local users, while preserving per-user consent.
7. Developer ID signing, notarization, Sparkle updates, release telemetry policy, and public launch.

## Completion gate for the first shippable milestone

The milestone is complete only when fresh evidence shows:

- a clean build and all automated tests pass;
- a user video imports and verifies through the hardware conversion pipeline;
- one and three-display rendering work at the desktop layer;
- Pause, Resume, Stop Wallpaper, Open WALI, and Quit WALI behave distinctly;
- menu-bar CPU/memory sampling stops while hidden;
- sleep/wake and lock/unlock restore correctly;
- 100 apply/stop cycles leak no WALI windows, players, observers, or descriptors;
- failed/cancelled imports leave no untracked files;
- keyboard and accessibility checks pass; and
- measured performance is recorded against the declared budgets.
