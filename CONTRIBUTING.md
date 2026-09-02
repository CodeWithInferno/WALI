# Contributing to WALI

WALI welcomes careful contributions from people and autonomous coding agents. The project values architectural integrity, native behavior, and measured efficiency over feature count.

## Before starting

1. Read `README.md`, `AGENTS.md`, `DESIGN.md`, and `ARCHITECTURE.md` when present.
2. Read the ADRs related to your area.
3. Search existing issues and plans.
4. For a large feature or architectural change, open a design issue before implementation.

## Choose the correct module

The following is the target placement, not current product capability:

- Immutable domain values and policies → `WALIModel`
- Bounded/versioned cross-process DTOs → `WALIWire`
- Use cases, durable jobs, and orchestration policy → `WALIEngine`
- Shared native presentation → `WALIUI`
- Canonical catalog identifiers/manifests/trust/revocation → `WALICatalog`
- Foreground network/auth/catalog/download adapters → `WALICatalogRuntime`
- Foreground intentions and snapshot presentation → `WALI.app`
- Long-lived rendering, state, jobs, and persistence adapters → `WALIAgent.app`
- Bounded media analysis/encoding only → agent-private `WALITranscoder.xpc`
- Fixed authenticated-session Lock Screen mutations only → `WALILockScreenHelper.app`

`WALICore` names the local package reference and folder, not an importable
product. Current capabilities and allowed edges are recorded in
`docs/architecture/modules.yml`; do not infer them from this summary or bypass
these seams to make a feature faster to write.

## Development workflow

1. Describe the user-visible behavior and invariant.
2. Write a focused test and observe it fail for the expected reason.
3. Implement the smallest behavior that passes.
4. Refactor while the suite remains green.
5. Update public documentation and migration notes.
6. Run:

```bash
make verify
CONFIGURATION=Release ./scripts/build.sh
CONFIGURATION=Release ./scripts/verify-bundle.sh
```

7. Include exact verification results and screenshots for visual changes.

Marketplace database work must pass `make backend-reset`, `make backend-test`,
`make backend-lint`, `make marketplace-contracts`, and
`make marketplace-verify`. Use only the local
Supabase project while developing; linking, migration pushes, or destructive
commands against a hosted project require an explicit deployment procedure and
separate authorization.

Wallpaper contributions need item-level source, rights holder, redistribution
grant, attribution, source/canonical digests, reviewer, and date in
`docs/content/seed-catalog.yml` or the authoritative marketplace rights record.
An empty seed catalog is preferred to uncertain rights.

## Architecture changes

Add a proposed ADR under `docs/adr/` and obtain the explicit approval defined
in `GOVERNANCE.md` before changing:

- process or actor ownership;
- dependency direction;
- persistent schema/migrations;
- cross-process messages;
- security/privacy boundaries;
- codec or rendering strategy;
- macOS compatibility;
- runtime dependencies or plugin mechanisms.

An ADR must include credible alternatives, consequences, rollback/migration, and enforcement tests.

## Pull requests

Keep each pull request focused. Include:

- problem and intended behavior;
- architecture impact;
- tests added and red-green evidence;
- commands run and results;
- performance impact where relevant;
- storage/schema/IPC migration impact;
- accessibility verification for UI;
- screenshots or recordings for visual changes;
- risks and rollback.

Do not mix generated project output, mass formatting, unrelated cleanup, and behavior.

## Swift and concurrency

- Swift 6 strict concurrency remains enabled.
- AppKit/SwiftUI state is main-actor owned.
- Mutable subsystems have one explicit actor owner.
- Do not use `@unchecked Sendable`, detached tasks, blocking main-thread work, or arbitrary test sleeps without documented justification and focused tests.
- Check cancellation and revalidate state after suspension points.

## Design

Follow `DESIGN.md`. Use native controls and semantic system values. Test light/dark mode, system accent, Increase Contrast, Reduce Transparency, Reduce Motion, keyboard operation, and VoiceOver. Do not imitate Apple by drawing fake macOS chrome.

## Performance

Do not call a change “lighter” or “faster” without reproducible before/after measurements. Include hardware, macOS build, media profile, display topology, sample duration, median, and p95. Background polling and unbounded caches require rejection unless redesigned.

## Safety and clean-room requirements

- Never test against the live Apple wallpaper store automatically.
- Never submit proprietary media, copied implementation, private endpoints, credentials, or DRM bypasses.
- Never delete source media after an incomplete or unverified import.
- Never silently add telemetry, network access, login persistence, or elevated permissions.

## Generated files

`WALI.xcodeproj` and build output are generated and ignored. Edit `project.yml` and source configuration instead.

## Commit style

Use an imperative subject describing purpose, for example:

```text
add deterministic display reconciliation
prevent stale imports from committing
document agent state ownership
```

Commits should be buildable and reviewable. Automated agents must not commit or push unless explicitly authorized by the repository owner.

## Developer Certificate of Origin

Contributions are licensed under [Apache License 2.0](LICENSE) and require
certification under [Developer Certificate of Origin 1.1](DCO). Add a
`Signed-off-by` trailer with Git's sign-off option:

```bash
git commit --signoff
```

The trailer certifies the DCO; it is not a copyright assignment. Do not submit
wallpaper or other media unless its separate license permits inclusion and is
recorded in [NOTICE](NOTICE) or adjacent metadata.

No hosted DCO bot or branch rule is claimed. Reviewers verify sign-off until
explicit automation is configured.
