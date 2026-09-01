# Display Canvas and Lock Screen Continuity Findings

## Display topology

- `WallpaperDisplayMonitor` already owns authoritative `NSScreen.frame` values and durable Core Graphics UUID aliases.
- Engine and wire display snapshots currently expose pixel dimensions but not logical origin/extent, so the foreground cannot reconstruct macOS arrangement.
- The existing toolbar control is a menu/checklist; the requested canvas is presentation-only and must not call display reconfiguration APIs.

## Reference implementation behavior observed on macOS 26.5.1

- The inspected reference implementation contains no screen saver or loginwindow injection.
- It copies an encoded MOV and thumbnail into `~/Library/Application Support/com.apple.wallpaper/aerials/`, merges a custom asset/category into `manifest/entries.json`, and selects `com.apple.wallpaper.choice.aerials` in `Store/Index.plist`.
- Apple `WallpaperAgent`, not the reference app's desktop player, renders the authenticated Lock Screen; playback timelines are independent.
- The current WALI master is HEVC Main, 1920x1080, SDR, 24 fps and is a plausible Aerial input, but compatibility must be verified before selection.
- The reference asset is HEVC Main 10, 3300x2160, SDR, 30 fps. WALI must fail closed if Apple rejects its existing master and transcode a dedicated variant instead of corrupting the store.

## Security and compatibility

- The relevant Apple store is per-user and available after authentication.
- FileVault preboot cannot read this encrypted per-user asset, so cold-boot unlock is out of scope.
- `lock_screen_manifest` already exists as a deferred compatibility surface and explicitly requires a separate accepted ADR plus copied version-gated fixture.
- Repository safety policy forbids live Apple-store writes from automated tests and proprietary Backdrop code/assets/branding.

## Implemented safety model

- ADR 0008 limits the adapter to exact system build `25F80`, Aerial manifest version 1, and the current-user provider `com.apple.wallpaper.choice.aerials`.
- WALI reserves fixed category/subcategory IDs and `CUSTOM_WALI_` shot IDs, with at most eight registered assets.
- Manifest and Index editors accept injected roots, validate bounds and ownership before writes, stage sibling files, reparse staged data, sync, and compare the exact expected bytes under file coordination before an atomic exchange. The displaced bytes are then verified; an observed noncooperating race is rolled back, while a second race is retained in a recovery sibling rather than deleted.
- The choice journal retains each original value, all managed pre/post asset IDs, and expected/target Index digests until replacement is durable; A-to-B changes, disable, and removed display/Space paths converge without overwriting external choices.
- The asset journal persists `refreshPending` through commit and disable cleanup. Each refresh carries a transaction generation, so an older suspended refresh can clear or remove only the exact journal generation it created.
- Cross-file preflight validates manifest ownership, Index scope/ownership, source and destination paths, removal paths, and journal bounds before the first mutation.
- Successful disable removes empty ownership journals, returning future disabled launches to a strict no-op, while prepared asset journals reclaim orphan UUID files after interrupted installs.
- Disabled with no WALI journal is a strict no-op: no build probe failure is surfaced and no Apple or WALI metadata is changed.
- Only top-level display choices and existing Space-display choices are patched; global, all-user, and Space-default choices remain outside WALI's authority.
- A newly-created Space that clones the display's current WALI choice inherits rollback from that display's matching journal record. A different WALI choice is treated as an external selection and fails closed without mutation.
- Directory event sources observe atomic Apple manifest/store replacement without background polling; wake, unlock, Space, and display events also trigger coalesced reconciliation.
- The authoritative command router dry-validates false-to-true opt-in before engine persistence. Later private-adapter failures preserve the committed desktop command and travel as a durable warning in agent snapshots.
