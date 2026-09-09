# Working on WALI

This repository is designed for contributions from humans and autonomous coding agents. The goal is not merely to keep the project compiling; it is to preserve a native, efficient, recoverable macOS architecture as the product grows.

This file and accepted records under `docs/adr/` are normative. A later ADR
changes an accepted decision only when it explicitly supersedes it.
`.cursor/rules/*.mdc` files are concise tooling projections; they do not
override this file or an accepted ADR. See `GOVERNANCE.md` for precedence,
approval, ownership, and conflict handling.

## Read first

1. `ARCHITECTURE.md` — public architecture and non-negotiable invariants.
2. `DESIGN.md` — visual and interaction contract.
3. `docs/plans/2026-08-30-wali-architecture-hardening.md` — active delivery plan.
4. `docs/architecture/modules.yml` and
   `docs/compatibility/surfaces.yml` — current/target graph and format registry.
5. Applicable accepted/proposed records under `docs/adr/`.
6. The nearest module documentation and concise `.cursor/rules/` projections.

The older foundation plan is retained as superseded history. Do not execute a
step from it when the hardening plan or an accepted ADR differs.

## Build and test

Requirements: macOS, Xcode 26.2+, Swift 6.2+, and XcodeGen 2.44.1+ on `PATH`
or selected with `XCODEGEN_BIN`. Architecture policy also requires the macOS
system `/usr/bin/ruby` with standard-library Psych, `swift package`, and
`xcrun swiftc`; the wrapper checks them.

```bash
make generate       # regenerate ignored WALI.xcodeproj
make build          # credential-free Debug build
make test           # package tests + macOS unit tests
make check-architecture # validate dependency and rule policy
make verify-bundle  # validate helper/XPC embedding and metadata
make verify         # clean, sequential local verification
make clean          # remove every generated project/build output
```

Release configuration:

```bash
CONFIGURATION=Release ./scripts/build.sh
CONFIGURATION=Release ./scripts/verify-bundle.sh
```

Signed Development configuration:

```bash
DEVELOPMENT_TEAM=ABCDE12345 make development
```

Debug script builds use credential-free ad-hoc bundle seals for local agent
registration; hostless test builds may remain unsealed. Debug omits
the app-group entitlements and uses `com.wali.debug.*` identities, so it cannot
verify shared-container behavior. Development uses `com.wali.development.*`,
automatic Apple Development signing, and
`group.com.wali.development.shared`; the selected team must have provisioning
access to those identifiers. Release retains `com.wali.*` and
`group.com.wali.shared` and requires configured distribution signing. The credential-free test path compiles the UI-test
target but does not launch its runner.

## Store distribution work

Accepted [ADR 0018](docs/adr/0018-sandboxed-mac-app-store-distribution.md) and
[the Store delivery plan](docs/plans/2026-09-09-mac-app-store-distribution.md)
govern the separate sandboxed product. `project.yml` remains the direct entry;
`project-store.yml` generates `WALIStore.xcodeproj` from shared
`project-common.yml` templates. Do not change the direct identifiers, library,
helper behavior, or Developer ID workflow to make Store tests pass.

```bash
make store-generate
bundle exec fastlane mac store_feasibility structural_only:true
bundle exec fastlane mac store_test
```

Structural output is credential-free and does not prove sandbox permissions,
service registration, or signed runtime behavior. The signed feasibility and
App Store archive lanes use distinct profiles and output directories; see
`docs/release/fastlane.md`. Do not send Store packages through Developer ID
notarization or call an archive an upload/review result.

Store contains only foreground app, agent, and private transcoder. All are
sandboxed; `WALILockScreenWire`, private Lock Screen code, helper resources, and
FDA settings must be absent by construction. Agent authority remains in its
private container. App-group quarantine/presentation bytes are untrusted or
rebuildable, and the worker has no group/network access. Preserve scoped grants,
explicit background consent, complete bounded Quit, and separate data identities.
No automatic migration or simultaneous playback across editions is promised.

Marketplace privacy/schema changes require their own applicable approval;
Store sandbox approval does not authorize bypassing marketplace release gates.

## Runtime topology

### Current direct-distribution implementation

```text
WALI.app ──► app runtime/UI, catalog adapter ──► bounded AgentGateway
 ├─ embeds WALIAgent.app ──► Engine, renderer, local persistence, import/install
 │    └─ embeds WALITranscoder.xpc ──► bounded private media worker
 └─ embeds WALILockScreenHelper.app ──► optional fixed compatibility operations
```

`WALICore` remains the package path, not an imported module/product. WALIModel,
WALIWire, and WALIEngine implement the model, versioned IPC contracts, and pure
use cases. Agent-owned persistence currently uses atomic JSON snapshots and
content-addressed files. Native marketplace creator/moderation/account routes
are composed; consult the dated release evidence ledger for verification gaps.

### Runtime boundary

```text
WALI.app ──► AgentGateway / versioned wire ──► WALIAgent.app
                                                  │
                                                  ├─ sole Engine host
                                                  └─ embeds private WALITranscoder.xpc

runtime static modules ──► package products they consume
```

Containment is not linkage. Transcoder containment and its authenticated request
path are agent-private.
Package-target dependencies are canonical only in
`docs/architecture/modules.yml` under `swift_packages.*.*.targets`; diagrams
must stop at package-product boundaries.

### Target dependency direction

- `WALIModel`: immutable values, IDs, policies, and reducer state.
- `WALIWire`: explicit bounded/versioned DTOs; it may depend on `WALIModel`.
- `WALILockScreenWire`: direct-only helper records/protocol; no Store dependency.
- `WALIEngine`: transport-neutral use cases, jobs, revisions, and orchestration;
  it depends on `WALIModel`, not UI/media/SQLite/XPC.
- `WALIUI`: reusable presentation depending on model values.
- `WALI.app`: foreground intentions and snapshot presentation only.
- `WALIAgent.app`: Engine host and sole local runtime persistence authority.
- `WALITranscoder.xpc`: bounded agent-private media work returning untrusted
  immutable artifact claims; it never installs or assigns.

Runtime static modules are adapters. Executable targets must not import another
executable target's implementation. `docs/architecture/modules.yml` records
allowed current and target imports.

## Ownership and concurrency

- AppKit/SwiftUI objects are main-actor owned.
- One agent-hosted Engine owns command ordering, revisions, assignments, durable
  jobs, install decisions, and persistent mutations.
- The agent is the only writer of local runtime library/job/assignment state.
- Wallpaper windows, players, and display reconciliation remain main-actor
  adapters owned by the agent.
- Worker outputs are claims; the agent verifies bytes and metadata before
  content-addressed publication.
- Values crossing actors or processes are immutable, bounded, `Codable`, and `Sendable`.
- Revalidate state after each suspension point before committing a mutation.
- Long-running tasks support cancellation and publish one terminal result.
- Teardown is idempotent.

## Change protocol

1. State the behavioral or architectural invariant being changed.
2. Identify the module interface and adapters involved.
3. Write the smallest failing test through that interface.
4. Implement the minimum behavior.
5. Refactor only after green.
6. Run the focused test and affected suites.
7. Update public docs, module/surface inventories, fixtures, and migration notes.
8. Add a proposed ADR and obtain explicit architecture approval when ownership,
   dependencies, IPC, schema, security, or compatibility policy changes.

Prefer the stable seams named in `ARCHITECTURE.md`. Do not create abstractions
for hypothetical variation, generic CRUD layers, or one protocol per Apple
framework. Introduce a new seam when a real system adapter plus deterministic
test adapter, or two production implementations, prove variation.

## Architectural decision records

Create a proposed `docs/adr/NNNN-short-title.md` and obtain the approval defined
in `GOVERNANCE.md` before implementing decisions that alter:

- process or actor ownership;
- target/package dependency direction;
- persistent schema or migration policy;
- cross-process message contracts;
- security/privacy boundaries;
- rendering or codec strategy;
- supported macOS compatibility;
- new runtime dependencies or plugin mechanisms.

Follow `docs/adr/README.md`. Accepted history is immutable; supersede it with a
new linked ADR rather than rewriting the decision.

## Safety boundaries

- Never write to the user's live Apple wallpaper store from an automated test.
- Never patch protected macOS components or claim FileVault preboot support.
- Never include proprietary Backdrop code, assets, endpoints, credentials, or branding.
- Never add telemetry or network dependencies silently.
- Never delete user source media after a failed or unverified import.

## Performance contract

Treat the budgets in the architecture document as acceptance criteria. Every optimization needs before/after evidence with hardware, macOS build, media profile, display topology, duration, median, and p95. Avoid background polling and unbounded caches.

## Collaboration

- Do not modify files owned by another active task.
- Do not erase uncommitted work.
- Follow `docs/generated-files.md`; `project.yml` is authoritative for the
  generated Xcode project.
- Keep changes narrow enough to review and revert.
- Report actual test/build output, unresolved risks, and migration impact.
- Do not commit or publish unless explicitly authorized by the repository owner.
