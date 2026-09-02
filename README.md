# WALI

WALI is an open-source, native macOS live-wallpaper system focused on efficient playback, honest resource use, automatic video preparation, and first-class Mac interaction.

> **Status:** functional local pre-release. The native library, per-display
> renderer, background Engine host, local XPC boundaries, durable storage, and
> video import/transcode path are implemented. A secure marketplace foundation
> is under active integration and public creator uploads remain disabled.
> Distribution is still gated on
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
- Browse an optional signed catalog whose downloads remain playable offline.
- Plan a future creator flow for explicitly licensed media through a hostile-media pipeline.
- Support the current user's session lock screen only through tested, version-gated compatibility adapters.

WALI cannot and will not bypass FileVault preboot, SIP, protected login UI, or another user's consent.
Lock Screen continuity is an opt-in private compatibility adapter currently
limited to verified macOS build 25F80. Apple may change this format at any
update; WALI then fails closed until a new fixture-backed epoch is accepted.
Because macOS protects the current-user wallpaper store, the marketplace plan
isolates this optional permission in a narrow `WALILockScreenHelper`; the app,
renderer agent, catalog client, and media components must work without it.
It mirrors the main display's wallpaper through macOS's current-user global
linked selection and restores the prior global/display/Space values on disable.
Desktop and Lock Screen playback timelines are independent.

## Architecture

Current implementation:

```text
WALI.app              native library, public marketplace, basic account shell, settings, and XPC client
WALIAgent.app         Engine, renderer, menu-bar, persistence, import/install authority
WALITranscoder.xpc    agent-private HEVC/HEIC media worker with a bounded XPC contract
WALILockScreenHelper  optional fixed-operation Lock Screen compatibility helper
WALIModel             immutable records and pure playback/import-job reducers
WALIWire              bounded versioned app/agent and agent/worker DTOs and codecs
WALIEngine            revisioned, idempotent use cases and orchestration policy
WALIUI                reusable native presentation models and status panel
WALICatalog           canonical manifest, trust, revocation, and identifier contract
WALICatalogRuntime    foreground auth/catalog/report/install/download adapter
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
- [Marketplace foundation design](docs/design/2026-09-01-marketplace-foundation.md)
- [Marketplace implementation plan](docs/plans/2026-09-01-marketplace-foundation.md)

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

# Developer ID Release: copy Config/Signing.example.xcconfig to the ignored
# Config/Signing.local.xcconfig and select your local certificate/team there.
CONFIGURATION=Release ./scripts/build.sh
```

The Xcode project is generated and intentionally ignored. Edit `project.yml`, then regenerate.

The marketplace control plane runs locally through Supabase. Install the
Supabase CLI and Docker, then use `make backend-start`, `make backend-reset`,
`make backend-test`, and `make backend-lint`. See
[`supabase/README.md`](supabase/README.md). Hosted projects are never linked or
mutated by these local targets.

The full local marketplace gate is `make marketplace-verify`. It additionally
checks Edge Functions, the race-enabled Go worker, frozen classifier tests,
static networkless-sandbox policy, SPDX/license provenance, and worker-host
isolation. CI also builds an ephemeral media image and runs the hostile corpus
inside an isolated Docker runtime; rerunning that corpus against the exact
signed release image remains a release gate. Hosted staging load/canary,
isolated restore, signed helper lifecycle, and notarization remain explicit
environment gates; see the
[public-beta checklist](docs/release/marketplace-public-beta-checklist.md).

Debug verification permits credential-free, unsealed app, agent, and XPC
wrappers, but Lock Screen continuity stays unavailable because an ad-hoc peer
cannot be authenticated strongly enough for Full Disk Access. Linker-produced
ad-hoc signatures on Mach-O payloads are not treated as cryptographically
signed wrappers. Debug compiles the UI-test target
and runs every hostless unit suite, but it uses `com.wali.debug.*`, omits
app-group entitlements, and cannot validate shared-container behavior.
Development uses `com.wali.development.*`, automatic Apple Development signing,
and `group.com.wali.development.shared`; the supplied team must be authorized
for those identifiers. Release retains `com.wali.*` and
`group.com.wali.shared`, requires a real common Team ID for authenticated IPC,
and intentionally fails until `Config/Signing.local.xcconfig` is configured.

### Remaining release gates

- Exercise the embedded login item and both authenticated XPC boundaries with
  real Apple Development and Developer ID team identities, including upgrade,
  relaunch, and reconnect behavior.
- Archive, notarize, staple, install, and pass Gatekeeper validation using the
  actual distribution credentials and production identifiers.
- Complete physical-hardware endurance runs for sustained playback and imports,
  sleep/wake and lock/unlock, low-power and thermal states, display hot-plug and
  scale changes, and multiple Spaces/full-screen configurations.
- Complete marketplace Gates A–E, including counsel approval, dedicated worker
  deployment, hosted staging canary, restore proof, key rotation, and
  exact-candidate SBOM/vulnerability evidence.
- Keep creator uploads disabled until rights-proof policy is either implemented
  or explicitly excluded, creator/moderator production gateways are composed,
  and publication/revocation pass the hosted signing canary.
- Do not expose account export/deletion until native request/status/retrieval,
  private export download, session revocation, and Auth identity cleanup are
  complete and exercised end to end.

Credential-free Debug builds prove the project graph and hostless behavior
only. They do not prove authenticated helper IPC, external signing,
notarization, or real display/window-server behavior above.

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

Backdrop, Wallsflow, and other products are behavioral references only. Do not
contribute copied proprietary code, media, endpoints, credentials,
reverse-engineered authentication, or confusingly similar branding.
The sanitized evidence record is
[Backdrop clean-room research](docs/research/2026-08-30-backdrop-research.md).

## License

WALI code and source documentation are licensed under the
[Apache License 2.0](LICENSE). Contributions use the
[Developer Certificate of Origin 1.1](DCO). See [NOTICE](NOTICE): the code
license does not grant rights to wallpaper, video, image, audio, catalog, or
reference-product media unless that content has an explicit compatible license.
