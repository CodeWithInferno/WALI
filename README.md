# WALI

WALI is an open-source, native macOS live-wallpaper system focused on efficient playback, honest resource use, automatic video preparation, and first-class Mac interaction.

> **Status:** functional local pre-release. The native library, per-display
> renderer, background Engine host, local XPC boundaries, durable storage, and
> video import/transcode path are implemented. Distribution is still gated on
> real-team signing, notarization, and physical-hardware endurance and Spaces
> verification; this is not yet a supported public release.

## Product direction

- Import an ordinary video; WALI prepares the appropriate media variants.
- Render through native AppKit and AVFoundation with hardware codecs.
- Assign wallpapers per display and preserve disconnected-display configuration.
- Pause intelligently for sleep, lock, occlusion, low power, and thermal pressure.
- Keep the lightweight renderer alive when the library window closes.
- Control playback and inspect WALI CPU/memory from the menu bar.
- Offer a native SwiftUI library following macOS interaction and accessibility conventions.
- Support the current user's session lock screen only through tested, version-gated compatibility adapters.

WALI cannot and will not bypass FileVault preboot, SIP, protected login UI, or another user's consent.
Lock Screen continuity is an opt-in private compatibility adapter currently
limited to verified macOS build 25F80. Apple may change this format at any
update; WALI then fails closed until a new fixture-backed epoch is accepted.
Because macOS protects the current-user wallpaper store, this optional adapter
requires Full Disk Access for WALI Agent; normal desktop playback does not.
It mirrors the main display's wallpaper through macOS's current-user global
linked selection and restores the prior global/display/Space values on disable.
Desktop and Lock Screen playback timelines are independent.

## Architecture

Current implementation:

```text
WALI.app              native library, create/download surfaces, settings, and XPC client
WALIAgent.app         Engine, renderer, menu-bar, persistence, and import authority
WALITranscoder.xpc    agent-private HEVC/HEIC media worker with a bounded XPC contract
WALIModel             immutable records and pure playback/import-job reducers
WALIWire              bounded versioned app/agent and agent/worker DTOs and codecs
WALIEngine            revisioned, idempotent use cases and orchestration policy
WALIUI                reusable native presentation models and status panel
```

The foreground process sends intentions and presents snapshots; the agent owns
mutable runtime state, display reconciliation, playback, import jobs, and local
storage. Imported videos are inspected and converted to silent HEVC playback
variants plus an HEIC poster by the embedded worker, then independently
verified and published into the agent's content-addressed store. The checked-in
renderer uses native AppKit wallpaper windows and AVFoundation playback and
reacts to display and system-power changes.

Compatibility surfaces remain conservative: an implementation is not recorded
as a versioned compatibility guarantee until its required fixtures pass.
`WALICore` remains the local package reference/path, not an imported module or
product. `ARCHITECTURE.md` defines the ownership and dependency graph.

Start with:

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`DESIGN.md`](DESIGN.md)
- [`AGENTS.md`](AGENTS.md)
- [`GOVERNANCE.md`](GOVERNANCE.md)
- [Architecture and product design](docs/design/2026-08-30-wali-architecture-and-product.md)
- [Active architecture-hardening plan](docs/plans/2026-08-30-wali-architecture-hardening.md)

## Development

Requirements:

- macOS 15 or newer
- Xcode 26.2 or newer
- Swift 6.2 or newer
- XcodeGen 2.44.1 or newer, available on `PATH` or through `XCODEGEN_BIN`
- macOS system `/usr/bin/ruby` with standard-library Psych, plus the selected
  Swift toolchain's `swift package` and `xcrun swiftc`, for policy checks

```bash
make generate
make build
make test
make check-architecture
make verify
make clean

# Signed local build; requires provisioning access to WALI's identifiers.
DEVELOPMENT_TEAM=ABCDE12345 make development
```

The Xcode project is generated and intentionally ignored. Edit `project.yml`, then regenerate.

Debug and Release verification require credential-free, unsealed app, agent,
and XPC wrappers. Linker-produced ad-hoc signatures on Mach-O payloads are not
treated as cryptographically signed wrappers. Debug compiles the UI-test target
and runs every hostless unit suite, but it uses `com.wali.debug.*`, omits
app-group entitlements, and cannot validate shared-container behavior.
Development uses `com.wali.development.*`, automatic Apple Development signing,
and `group.com.wali.development.shared`; the supplied team must be authorized
for those identifiers. Release retains `com.wali.*` and
`group.com.wali.shared`.

### Remaining release gates

- Exercise the embedded login item and both authenticated XPC boundaries with
  real Apple Development and Developer ID team identities, including upgrade,
  relaunch, and reconnect behavior.
- Archive, notarize, staple, install, and pass Gatekeeper validation using the
  actual distribution credentials and production identifiers.
- Complete physical-hardware endurance runs for sustained playback and imports,
  sleep/wake and lock/unlock, low-power and thermal states, display hot-plug and
  scale changes, and multiple Spaces/full-screen configurations.

Credential-free Debug and Release builds prove the project graph and bundle
shape only. They do not prove the external signing lifecycle, notarization, or
real display/window-server behavior above.

## Principles

1. Native before custom.
2. Correct and recoverable before clever.
3. Deep modules with small interfaces.
4. One explicit owner for mutable state.
5. Measurements before optimization claims.
6. No silent data loss, background polling, telemetry, or compatibility hacks.
7. Architecture changes are recorded, tested, and migratable.

## Contributing

WALI is being structured for both human and autonomous-agent contributions. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md) before changing code. Contributions that weaken concurrency guarantees, data recovery, native behavior, or measured efficiency will not be accepted merely because they add features.

## Clean-room boundary

Backdrop and other products are behavioral references only. Do not contribute copied proprietary code, media, endpoints, credentials, reverse-engineered authentication, or confusingly similar branding.
The sanitized evidence record is
[Backdrop clean-room research](docs/research/2026-08-30-backdrop-research.md).

## License

WALI code and source documentation are licensed under the
[Apache License 2.0](LICENSE). Contributions use the
[Developer Certificate of Origin 1.1](DCO). See [NOTICE](NOTICE): the code
license does not grant rights to wallpaper, video, image, audio, catalog, or
reference-product media unless that content has an explicit compatible license.
