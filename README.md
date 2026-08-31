# WALI

WALI is an open-source, native macOS live-wallpaper system focused on efficient playback, honest resource use, automatic video preparation, and first-class Mac interaction.

> **Status:** pre-alpha foundation. The repository currently contains architecture, design rules, and a buildable multi-process scaffold; it is not yet a usable wallpaper release.

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

## Architecture

Current scaffold:

```text
WALI.app              placeholder window; embeds WALIAgent.app
WALIAgent.app         placeholder scene; embeds WALITranscoder.xpc
WALITranscoder.xpc    permissive process-scoped listener placeholder
WALIModel             immutable records and pure playback/import-job reducers
WALIWire              package-scoped marker depending only on WALIModel
WALIEngine            package-scoped marker depending only on WALIModel
WALIUI                status-view placeholder
```

Target before product behavior:

```text
WALI.app                  foreground intentions and snapshot presentation
WALIAgent.app             Engine host and sole runtime/persistence authority
WALITranscoder.xpc        agent-private bounded media worker
WALIModel                 immutable values and policies
WALIWire                  bounded/versioned DTOs
WALIEngine                use cases, jobs, and orchestration
WALIUI                    reusable native presentation
```

No Engine orchestration, app↔agent IPC, renderer, durable persistence,
filesystem behavior, or storage is implemented. WALIModel implements Task 4
values and package-scoped reducers; WALIWire and WALIEngine remain linkage
markers only. `WALICore` remains the local package reference/path, not an
imported module or product.
`ARCHITECTURE.md` distinguishes current and target graphs.

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
