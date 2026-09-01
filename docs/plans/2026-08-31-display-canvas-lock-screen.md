# Display Canvas and Lock Screen Continuity Implementation Plan

**Goal:** Add a macOS-style display assignment canvas and opt-in authenticated-session Lock Screen continuity without weakening WALI's desktop renderer or claiming FileVault preboot support.

**Architecture:** The agent remains the sole source of display topology and persistent assignment state. Additive optional geometry travels through the existing snapshot DTO to a foreground-only SwiftUI canvas. Lock Screen continuity is a version-gated agent adapter that transactionally registers WALI-owned assets in the current user's Apple Aerial store while preserving unrelated entries and keeping rollback data.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit/CoreGraphics, Foundation JSON/property-list serialization, AVFoundation/ImageIO, existing WALIEngine/WALIWire IPC, macOS 26 Aerial wallpaper store.

---

## Invariants

1. macOS owns physical display arrangement; WALI only reads and visualizes it.
2. Display geometry is additive, bounded, optional wire data and remains backward-decodable.
3. Each display tile shows its durable wallpaper assignment and scaling state.
4. Lock Screen support is opt-in, session-lock-only, and version-gated to verified store formats.
5. Apple and other applications' Aerial categories and assets are never deleted; the accepted macOS 26 compatibility epoch temporarily replaces and journals the four current-user global selection roots only.
6. All Apple-store writes use staging, validation, backup metadata, atomic replacement, and WALI-owned identifiers.
7. FileVault preboot, other users, and unauthenticated loginwindow are never claimed or modified.
8. Desktop playback continues independently if Lock Screen registration fails.

### Task 1: Transport real display geometry

**Files:**
- Modify: `Packages/WALICore/Sources/WALIEngine/EngineState.swift`
- Modify: `Packages/WALICore/Sources/WALIWire/AgentProtocol.swift`
- Modify: `Sources/WALIAgentRuntime/WALIAgentController.swift`
- Modify: `Sources/WALIAgentRuntime/IPC/AgentCommandRouter.swift`
- Modify: `Sources/WALIUI/PresentationModels.swift`
- Modify: `Sources/WALIAppRuntime/WALIAppCoordinator.swift`

**Steps:**
1. Add optional finite logical-frame values to engine and wire display records with backward-compatible decoding.
2. Populate frames from `WallpaperDisplay.frame` in the agent and preserve last-known geometry for disconnected displays.
3. Map geometry into a presentation-only rectangle without importing AppKit into core modules.
4. Bound and validate every coordinate and extent at the wire boundary.
5. Run `make build`, `make check-architecture`, and `git diff --check`.

### Task 2: Build the display assignment canvas

**Files:**
- Create: `Sources/WALIAppRuntime/DisplayArrangementView.swift`
- Modify: `Sources/WALIAppRuntime/WALIAppRootView.swift`
- Modify: `Sources/WALIAppRuntime/WallpaperDetailView.swift`
- Modify: `DESIGN.md`

**Steps:**
1. Replace the toolbar display menu with a popover matching the supplied macOS arrangement reference.
2. Normalize the union of connected display frames into a centered, proportional canvas without changing their system arrangement.
3. Render each display with its assigned wallpaper thumbnail, name, main/built-in affordance, selection state, and scaling badge.
4. Make click toggle assignment selection; provide explicit All Displays and Done controls plus keyboard/accessibility labels.
5. Keep the existing detail Apply action as the mutation point for the selected wallpaper and scaling.
6. Visually verify landscape, portrait, negative-origin, and disconnected-display layouts on the live three-monitor topology.

### Task 3: Record the private Aerial-store decision

**Files:**
- Create: `docs/adr/0008-session-lock-aerial-adapter.md`
- Modify: `ARCHITECTURE.md`
- Modify: `docs/compatibility/surfaces.yml`
- Modify: `scripts/check-architecture.rb`
- Modify: `Tests/Architecture/check-architecture-tests.sh`
- Create: `Fixtures/LockScreen/modern-aerial-v1.json`
- Create: `docs/adr/0009-global-linked-lock-screen-activation.md`

**Steps:**
1. Record project-owner approval from the 2026-08-31 autonomous implementation mandate.
2. Limit support to the authenticated current-user session and the verified macOS 26 store epoch.
3. Define ownership prefixes, copied asset layout, maximum custom assets, rollback rules, and OS fail-closed behavior.
4. Update the compatibility registry and policy checker so implementation requires the accepted ADR and redacted fixture.
5. Supersede the unsafe per-display activation mechanism with the verified revision-1 global linked contract while preserving ADR 0008 as historical context.
6. Run architecture mutation tests and the real repository check.

### Task 4: Implement transactional Aerial registration

**Files:**
- Create: `Sources/WALIAgentRuntime/LockScreen/AerialManifestEditor.swift`
- Create: `Sources/WALIAgentRuntime/LockScreen/WallpaperStoreEditor.swift`
- Create: `Sources/WALIAgentRuntime/LockScreen/LockScreenContinuityCoordinator.swift`
- Modify: `Sources/WALIAgentRuntime/WALIAgentController.swift`
- Modify: `Sources/WALIAgentRuntime/System/SystemEventSource.swift`

**Steps:**
1. Build deterministic editors that operate on injected roots and reject unknown/malformed schemas before writes.
2. Derive stable WALI asset IDs from library item IDs and copy verified master MOVs plus generated PNG thumbnails into the per-user Aerial store.
3. Merge only `WALI` category/subcategory/assets while retaining every unrelated manifest value.
4. Select the main display's assignment and transactionally replace `AllSpacesAndDisplays` and `SystemDefault` with the verified global linked Aerial choice while clearing `Displays` and `Spaces`.
5. Journal the exact prior values of all four managed roots, fail closed on external drift, and restore them exactly on disable.
6. Quiesce the current user's `WallpaperAgent` before a required store mutation, then stage, validate, fsync, and atomically replace; recover interrupted transactions on next startup.
7. Refresh the current user's `WallpaperAgent` and Aerial extension only after a committed transaction.
8. Reconcile on apply, startup, display/Space change, and detected Apple catalog replacement.
9. Exercise editors against temporary copies before any live store mutation.

### Task 5: Add opt-in preference and user-facing state

**Files:**
- Modify: `Packages/WALICore/Sources/WALIEngine/EngineState.swift`
- Modify: `Packages/WALICore/Sources/WALIWire/AgentProtocol.swift`
- Modify: `Sources/WALIAgentRuntime/IPC/AgentCommandRouter.swift`
- Modify: `Sources/WALIAppRuntime/WALISettingsView.swift`
- Modify: `Sources/WALIAppRuntime/WALIAppCoordinator.swift`
- Modify: `DESIGN.md`

**Steps:**
1. Add a backward-compatible `lockScreenContinuityEnabled` preference defaulting off.
2. Add a clear settings toggle labeled experimental/private integration with authenticated-session and FileVault caveats.
3. Enabling performs a dry validation before mutation; failure leaves desktop behavior unchanged and surfaces recovery text.
4. Disabling removes only WALI-owned manifest/assets and restores the exact four-root preimage only while the managed global structure remains WALI-owned.
5. Leave it disabled in the current installation until isolated editor checks and explicit live verification are complete.

### Task 6: Verify and publish the second checkpoint

**Steps:**
1. Run `make verify` and `git diff --check`.
2. Build and sign the exact live app bundle, then repair the registered agent if required.
3. Verify the display canvas visually on all connected monitors.
4. Select Center and Fill through the canvas/detail flow and confirm per-display durable state.
5. Enable Lock Screen continuity, verify WALI-owned manifest entries and display/Space choices, lock the authenticated session, and visually confirm playback.
6. Confirm WALI resumes after unlock and both foreground and agent processes remain healthy.
7. Commit without assistant metadata and push `wali-production` only after all gates pass.
