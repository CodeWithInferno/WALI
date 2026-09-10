# WALI

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Resources/Branding/wali-lockup-horizontal-white.svg">
  <img src="Resources/Branding/wali-lockup-horizontal-blue.svg" alt="WALI ribbon logo" width="280">
</picture>

WALI is an open-source, native macOS live-wallpaper system focused on efficient playback, honest resource use, automatic video preparation, and first-class Mac interaction.

> **Status:** functional local pre-release. The native library, per-display
> renderer, background Engine host, local XPC boundaries, durable storage, and
> video import/transcode path are implemented. Native staging verification now
> covers creator agreement/upload/submission, moderator approval/publication,
> report removal, account export, and catalog installation with Cancel/Retry.
> Public release remains gated on deletion and interrupted-job verification,
> moderation policy, legal approval, recovery/capacity evidence, distribution signing,
> notarization, and physical-hardware checks. See the dated
> [evidence ledger](docs/release/marketplace-public-beta-evidence.md).

## Try the local app

With the [development requirements](#development) installed:

```sh
git clone https://github.com/CodeWithInferno/WALI.git
cd WALI
make build
open .build/xcode/DerivedData/Build/Products/Debug/WALI.app
```

Import a video you have permission to use, wait for preparation, then choose a
display in the library. The menu bar provides playback controls and Quit.
Local wallpaper use requires no marketplace account. Connected marketplace
work uses a separately configured environment; see [backend setup](supabase/README.md).
For contributions, start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Product direction

- Import an ordinary video; WALI prepares the appropriate media variants.
- Render through native AppKit and AVFoundation with hardware codecs.
- Assign wallpapers per display and preserve disconnected-display configuration.
- Pause intelligently for sleep, lock, occlusion, low power, and thermal pressure.
- Keep the lightweight renderer alive when the library window closes.
- Control playback and inspect WALI CPU/memory from the menu bar.
- Offer a native SwiftUI library following macOS interaction and accessibility conventions.
- Browse an optional signed catalog whose downloads remain playable offline.
- Upload creator media through a bounded processing and human-review pipeline.
- Support the current user's session lock screen only through tested, version-gated compatibility adapters.

WALI cannot and will not bypass FileVault preboot, SIP, protected login UI, or another user's consent.
Lock Screen continuity is an opt-in private compatibility adapter currently
limited to fixture-backed macOS builds 25F80 and 25G83. Apple may change this format at any
update; WALI then fails closed until a new fixture-backed epoch is accepted.
Because macOS protects the current-user wallpaper store, the marketplace plan
isolates this optional permission in a narrow `WALILockScreenHelper`; the app,
renderer agent, catalog client, and media components must work without it.
It mirrors the main display's wallpaper through macOS's current-user global
linked selection and restores the prior global/display/Space values on disable.
Desktop and Lock Screen playback timelines are independent.

## Distribution status

The branding and verified Finder installer layout are merged in
[PR 25](https://github.com/CodeWithInferno/WALI/pull/25). The direct-download
product retains its optional, version-gated Lock Screen helper. Signed and
notarized release packages are still gated on actual distribution credentials
and the remaining release evidence; a local Debug DMG is not a distribution
release. Direct Release currently supports local wallpapers only, with
marketplace access disabled under
[ADR 0021](docs/adr/0021-developer-id-local-only-entitlements.md).

The separate sandboxed Mac App Store implementation merged in
[PR 27](https://github.com/CodeWithInferno/WALI/pull/27) under
[ADR 0018](docs/adr/0018-sandboxed-mac-app-store-distribution.md). It retains the
native desktop and marketplace product, omits private Lock Screen integration,
and uses its own library/settings identity. All six applicable PR checks passed,
including 145 Store hostless tests and both Store structural builds. Signed
sandbox journeys, production readiness, and App Store submission remain open.
See the [release ledger](docs/release/2026-09-09-release-status.md) and
[Fastlane workflow](docs/release/fastlane.md) for the current evidence and commands.
The manual [GitHub Actions release workflow](docs/release/github-actions.md)
archives a signed candidate, waits for native review of its exact digest, then
notarizes and publishes those same bytes. That hosted workflow requires
marketplace access and remains incompatible with the current local-only direct
Release. Use the local Fastlane prerelease lanes and their native review gates.
Hosted signing setup and the first real run remain pending.

## Architecture

Current implementation:

```text
WALI.app              native library, marketplace, creator/moderation/account routes, settings, XPC client
WALIAgent.app         Engine, renderer, menu-bar, persistence, import/install authority
WALITranscoder.xpc    agent-private HEVC/HEIC media worker with a bounded XPC contract
WALILockScreenHelper  optional fixed-operation Lock Screen compatibility helper
WALIModel             immutable records and pure playback/import-job reducers
WALIWire              bounded versioned app/agent and agent/worker DTOs and codecs
WALIEngine            revisioned, idempotent use cases and orchestration policy
WALIUI                reusable native presentation models and status panel
WALICatalog           canonical manifest, trust, revocation, and identifier contract
WALICatalogRuntime    foreground auth/catalog/creator/moderation/account/download adapters
```

The foreground process sends intentions and presents snapshots; the agent owns
mutable runtime state, display reconciliation, playback, import jobs, and local
storage through atomic JSON snapshots and content-addressed files. Imported videos are inspected and converted to silent HEVC playback
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

The Xcode projects are generated and intentionally ignored. Edit `project.yml`
for direct distribution or `project-store.yml` for Store, with shared declarations
in `project-common.yml`, then regenerate the relevant graph.

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

`make build` seals Debug app, agent, and XPC bundles with credential-free ad-hoc
signatures so macOS can register the background agent. Lock Screen continuity
stays unavailable because an ad-hoc peer cannot be authenticated strongly enough
for Full Disk Access. Hostless test builds may remain unsealed; linker-produced
Mach-O signatures alone do not seal an app bundle. `make test` compiles the UI-test target
and runs every hostless unit suite. Debug uses `com.wali.debug.*`, omits
app-group entitlements, and cannot validate shared-container behavior.
Development uses `com.wali.development.*`, automatic Apple Development signing,
and `group.com.wali.development.shared`; the supplied team must be authorized
for those identifiers. Release uses `io.github.codewithinferno.wali.*` under accepted
[ADR 0020](docs/adr/0020-direct-release-identifier-namespace.md) and retains
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
- Complete marketplace Gates A–E, including counsel approval, redistribution
  rights, restore proof, key rotation, capacity, and exact-candidate
  SBOM/vulnerability evidence. The dedicated staging worker and original-media
  canary are recorded in the evidence ledger.
- Complete moderation policy and rights screening, post-publication object and
  copyright handling, and technical revocation checks before enabling public
  creator submissions. The original staging canary passed moderator MFA,
  review/revision, publication, and report hiding/removal.
- Finish native deletion/session
  revocation/Auth cleanup verification. The staging export check does not prove
  the deletion path.

Credential-free Debug builds support local app interaction and hostless checks.
They do not prove team-authenticated helper IPC, external signing, notarization,
or the hardware and lifecycle release gates above.

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
