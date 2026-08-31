# Backdrop Clean-Room Research Notes

**Date:** 2026-08-30  
**Purpose:** Preserve behavioral and public technical observations that informed
WALI without carrying machine-local paths or stale repository status.

## Evidence labels

- **User-confirmed:** supplied directly by the product owner.
- **Observed:** verified from public metadata, shipped documentation, signatures,
  linked frameworks, or read-only runtime inspection.
- **Inferred:** the best explanation consistent with observations, not yet
  independently proven.
- **Unverified:** a report or working hypothesis awaiting evidence.
- **Conclusion:** a bounded interpretation supported by the preceding evidence.

Measurements below describe one inspected build and one test setup. They are not
performance claims for WALI or all Backdrop releases.

## Reference identity and packaging

- **User-confirmed:** the reference product is Backdrop by Cindori; earlier
  “Pack Drop” and “Sindori” wording was a transcription error.
- **Observed:** the installed product was Backdrop 2.6.17, build 121, with bundle
  identifier `com.cindori.Backdrop`, requiring macOS 15 or newer.
- **Observed:** the main bundle contained an embedded
  `BackdropWallpaper.app` agent with `LSUIElement=true`.
- **Observed:** both applications were universal (`arm64` and `x86_64`),
  Developer ID signed by Cindori AB, and hardened-runtime enabled.
- **Observed:** neither application declared App Sandbox. The main application
  had CloudKit, application-group, and keychain-group entitlements; the helper
  had the shared application-group entitlement.
- **Observed:** the bundle included Sparkle updater components, analytics/crash
  reporting resources, a UI resource bundle, defaults, and a local manifest.
- **Conclusion:** no special live-wallpaper entitlement was visible. The
  inspected behavior is compatible with ordinary hardened AppKit/media APIs and
  direct distribution.

## Distribution image

- **Observed:** the locally obtained installer was an unencrypted, checksummed,
  read-only compressed UDIF using LZMA over HFS+.
- **Observed:** its compressed payload was about 35.2 MB and represented about
  93.7 MB of non-empty data.
- **Observed:** checksum verification passed during a read-only mount.
- **Observed:** the image contained the application and a conventional
  Applications installation link, with the same version/build as the installed
  bundle.
- **Observed:** no product process was running during the first inactive
  inspection, so that sample had no resident renderer process.

## Architecture evidence

- **Observed:** the embedded wallpaper application shipped a plaintext
  architecture note describing separate desired-state and connected-display
  coordination responsibilities.
- **Observed:** desired content/configuration was retained for known displays,
  including disconnected displays, while runtime players/windows existed only
  for currently connected displays.
- **Observed:** the described flow reconciled on display changes and destroyed
  runtime players on disconnect while preserving configuration for reconnect.
- **Observed:** the documented orchestration states included idle, preparing,
  active, transitioning, and recoverable error.
- **Conclusion:** the product separated catalog/control from rendering and
  separated persistent display intent from connected-display runtime objects.

## Native technology stack

- **Observed:** both executables linked the Swift runtime and native Apple
  frameworks including AppKit, SwiftUI, AVFoundation, CoreGraphics, CoreImage,
  CoreMedia, CoreVideo, QuartzCore, and IOSurface.
- **Observed:** the main application additionally linked AVKit, VideoToolbox,
  CoreData, CryptoKit, IOKit, ImageIO, Network, Security, ServiceManagement, and
  SQLite.
- **Observed:** the helper directly linked AppKit and AVFoundation. No Chromium,
  Electron, React Native, or direct embedded web runtime appeared in its linked
  dependencies.
- **Observed:** helper metadata referenced `AVPlayerLayer` and
  `AVPlayerLooper`, supporting native seamless video looping.
- **Conclusion:** observed efficiency was consistent with compiled native code,
  hardware-backed Apple media frameworks, and lifecycle policy—not evidence of
  a custom low-level renderer.

## Playback and energy lifecycle

- **Observed:** helper metadata contained concrete coordinator/manager type
  names matching its shipped architecture note.
- **Observed:** the helper referenced the API controlling whether video
  playback prevents display sleep.
- **Observed:** lifecycle strings described pausing when wallpaper windows were
  occluded, debouncing occlusion changes, forcing pause on sleep, recalculating
  state on wake, separating user pause from automatic pause, and skipping
  redundant updates.
- **Conclusion:** aggressive suspend behavior plus AVFoundation-backed playback
  likely accounted for much of the low idle resource use.

## Runtime topology sample

- **Observed:** launching the main application also launched the embedded
  wallpaper helper as a separate LaunchServices application.
- **Observed:** both processes were adopted by `launchd`, so helper lifetime was
  not a child-process lifetime.
- **Observed:** one initial sample with the UI open reported 0.0% CPU for both
  processes, approximately 143 MiB RSS for the main app, and approximately
  94 MiB RSS for the helper.
- **Caution:** this was not a steady-state benchmark. It did not measure dirty
  or compressed memory, GPU/energy use, active playback, occlusion, UI-closed
  behavior, or long-run slopes.

## Wallpaper window evidence

- **Observed:** helper metadata referenced explicit AppKit window construction,
  level, collection behavior, mouse-event ignoring, ordering, and teardown.
- **Observed:** runtime WindowServer inspection found one helper-owned wallpaper
  window for each of three connected displays, with bounds matching the display
  arrangement.
- **Observed:** those windows were opaque, untitled, nonshared, and used
  WindowServer layer `-2147483624`.
- **Observed:** on the inspected system,
  `kCGDesktopWindowLevel` resolved to `-2147483623` and
  `kCGDesktopIconWindowLevel` to `-2147483603`.
- **Conclusion:** the resulting wallpaper-window level was exactly one below the
  desktop background level and behind desktop icons. The product rendered
  custom AppKit windows rather than installing media into System Settings.
- **Unverified:** the source-level symbolic expression and exact
  collection-behavior flags.

## Content model evidence

- **Observed:** the inspected build shipped at least one local content manifest
  with associated media.
- **Observed:** the sample modeled a video wallpaper with stable identity,
  category, description, checksums, duration, byte size, bitrate, dimensions,
  thumbnail time, resolution and motion metadata, quality/popularity metadata,
  colors, tags, timestamps, and named asset/thumbnail/preview variants.
- **Observed:** the sample full asset was a roughly 5.1-second, 3300×2160 MOV of
  about 10.1 MB, with HEIC thumbnail and MOV preview variants.
- **Inferred:** a manifest-driven pipeline supports integrity checking,
  lightweight previews, search/filtering, tiered delivery, and deterministic
  cache management.

## Hypotheses evaluated

1. **Supported:** noninteractive AppKit windows at the desktop level host native
   video playback per connected display.
2. **Not supported by observed desktop behavior:** ordinary activation installs
   assets into Apple's System Settings wallpaper store.
3. **Partly supported:** a helper coordinates spaces, displays, and persistent
   lifecycle; no need for a privileged process was observed.
4. **Supported:** the catalog/control application and renderer are separate
   processes so rendering can outlive the foreground UI.

## WALI clean-room boundaries

- Study behavior, public metadata, shipped explanatory documentation, documented
  APIs, code signatures, entitlements, linked frameworks, process topology, and
  bounded network request shapes.
- Build original WALI code, product naming, artwork, service contracts, and
  visual design.
- Do not decompile proprietary binaries into copied logic or bypass DRM,
  authentication, signatures, access controls, or macOS protections.
- Do not redistribute catalog media without a license.
- Treat reference measurements as hypotheses for WALI budgets; make WALI
  performance claims only from fresh reproducible measurements.
