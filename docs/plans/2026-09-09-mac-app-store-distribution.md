# Mac App Store distribution implementation plan

Date: 2026-09-09. Status: approved; implementation in progress in the Tess
`wali-app-store` worktree on `codex/wali-app-store`. Architecture authority is accepted
[ADR 0018](../adr/0018-sandboxed-mac-app-store-distribution.md).
The [initial Store review](../release/app-store-review-2026-09-09.md) is the
separate product/production readiness register. Approval does not close any
implementation, signed feasibility, production, or submission gate.

## Implementation evidence

- Branding and release preparation merged in [PR 25](https://github.com/CodeWithInferno/WALI/pull/25).
  The bounded asynchronous carousel-test correction merged in
  [PR 26](https://github.com/CodeWithInferno/WALI/pull/26), producing main
  `e390281cd1661945a8118713ac929b246ef0cb59`. Both Marketplace CI and the
  security scan passed on that merge commit.
- The implementation was isolated through the Tess `wali-app-store` feature.
  Final integrated direct `make verify` passed 161 architecture fixtures,
  89 package tests, and 176 native tests, plus bundle, coverage, branding,
  license and release checks. The affected Debug build and bundle were
  rechecked after release-only coverage settings changed.
- The Store hostless suites passed 145 tests. StoreDevelopment and universal
  optimized AppStore structural builds passed graph, bundle and resource
  validation. Both AppStore architectures and all executable wrappers exclude
  LLVM coverage instrumentation. Direct helper selectors and wire bytes retain
  explicit compatibility tests.
- Consent, event-driven service recovery, bounded complete quit, scoped media
  grants, private agent authority, bounded presentation copies, and interrupted
  catalog recovery are implemented and covered through their deterministic
  interfaces. These results do not establish actual signed sandbox behavior.
- Persistent CI now builds both Store configurations, runs hostless Store tests,
  and inspects the universal artifact without credentials. Release lanes require
  the six source, contracts, Swift, Store, backend and media checks for the exact
  committed source before publication.
- Fastlane structural, test, archive, upload and submission lanes exist. The
  exported package is inspected again before upload; matching GitHub release,
  metadata, screenshots, processed Apple build and review submission identities
  are checked separately. Credential-free submission fixtures passed 51 cases.
- The Apple provisioning probe reported `No Accounts`; the available wildcard
  profile lacks Sign in with Apple. Secure login, correct profiles, signed
  runtime journeys, notarization, public release and Store submission remain
  open. No structural artifact has been published as a signed candidate.
- [ADR 0019](../adr/0019-private-creator-blocking.md) remains a separate proposed
  marketplace schema/privacy decision, without approval or implementation.

## Recorded approval

On 2026-09-09 the project owner explicitly replied, "Approve the Store variant".
This authorizes a separate sandboxed Store distribution that keeps the existing
Developer ID product, omits private Lock Screen integration from Store, keeps
agent authority and scoped worker isolation, and uses distinct Store identities
and data. The approval covers the Store-only graph, helper-wire extraction, group-prefixed
IPC, bounded bookmark handoff, consent/quit behavior, and the signed feasibility
gates in ADR 0018. Approval permits implementation and testing; it does not
waive marketplace readiness, accept Apple agreements, or declare Store approval.

The deliberate product difference is that Store has no private Lock Screen
continuity. Existing marketplace capabilities remain in scope. Separate
identity means no automatic import of the direct version's library or settings.
Ordinary desktop animation remains the target; it is not assumed impossible.

## Current source seams

| Concern | Current source | Planned change |
|---|---|---|
| Unconditional helper embedding | `project.yml:85–98,235–251` | Separate explicit XcodeGen distribution graphs using shared templates |
| Mixed helper/main wire declarations | `Packages/WALICore/Sources/WALIWire/AgentXPCProtocol.swift:8` | Extract helper-only definitions to direct-only `WALILockScreenWire`; preserve its bytes/selectors |
| Helper composition and reconciliation | `Sources/WALIAgentRuntime/WALIAgentController.swift:29,77,859`; `Sources/WALIAgentRuntime/LockScreen/` | Store excludes adapters and compiles no helper composition/recovery |
| FDA/settings UI | `Sources/WALIAppRuntime/WALISettingsView.swift:54,137` | Store excludes the whole continuity/FDA UI and associated actions |
| Service registration and startup | `Sources/WALIAppRuntime/IPC/AgentLifecycleController.swift:22,43`; `WALIAppCoordinator.swift:65` | Distribution-specific service list and explicit consent before registration |
| Source/staging access | `WALIAppCoordinator.swift:206`; `WALIAgentController.swift:397,453`; `WALITranscoderServiceRunner.swift:192`; `WALIWire/TranscoderProtocol.swift:4` | Transient interprocess grants, agent-owned persistent authorization, bounded staging grant |
| Authoritative storage and catalog intake | `Sources/WALIAgentRuntime/Storage/LibraryPaths.swift:24`; `Sources/WALICatalogRuntime/CatalogInstallPreparer.swift:116` | Agent-private library; app/agent group quarantine resolved through FileManager |
| Foreground media URLs | `Sources/WALIAgentRuntime/IPC/AgentCommandRouter.swift:439`; `WALIAppCoordinator.swift:312` | Store snapshot projects bounded group presentation copies |
| Release signing | `fastlane/Fastfile:59`; `scripts/validate-signature-metadata.rb:35`; `scripts/verify-bundle.sh` | Add Store-specific lanes and artifact validation; preserve Developer ID enforcement |

These are review-baseline pointers, not immutable line references. Read current
source before each edit. Do not change another active task's owned files.

## 0. Record authority and preserve the release baseline

Owner: `project_owner` with `architecture_maintainer`.

ADR 0018 acceptance and the exact session approval reference are recorded.
Reciprocal `0018=store_helper_presence,store_agent_sandbox_requirement` metadata
and a scoped note are recorded in ADR 0013 without rewriting its history.
ADR 0006's signed lifecycle result remains pending until tested.

Record the current direct build/test commit, artifact paths, and signing state.
Preserve uncommitted work and existing user data. Keep the signed GitHub release
work independent of the Store implementation; never describe a local ad-hoc
artifact or Developer ID notarization as Store submission evidence.

The release-preparation PR is merged and the Store worktree was created through
Tess under that feature. Continue Store product changes in that isolated
worktree; the primary checkout remains the direct-release baseline. Do not create
raw Git worktrees or mix Store work into the primary release checkout.

Exit: approval is recorded; the release-preparation commit and direct evidence
are identified; the Tess worktree path and file owners are assigned. Product
implementation starts only in that isolated worktree.

## First bounded implementation slice

The first slice delivers a deterministically generated, helper-free Store graph
and a credential-free structural compile. It does not attempt production
configuration, signed runtime activation, media access migration, upload, or
submission. This establishes a small reviewable baseline before changing the
cross-process file-access semantics.

1. Extract shared XcodeGen declarations and add the Store entry graph,
   StoreDevelopment/AppStore settings, explicit sandbox entitlement files,
   isolated output directories, and group-prefixed service configuration.
   Preserve direct identifiers and release lane behavior.
2. Extract the existing helper-only wire product without changing its selectors
   or encoded payloads. Keep it and all five LockScreen adapters out of Store's
   build/link graph. Compile out interleaved helper composition, recovery,
   settings, and FDA actions; keep the inert preference compatibility field
   false and reject its activation in the Store agent.
3. Add graph/bundle mutation checks for leaked helper source, product, protocol,
   launch metadata, or FDA UI resources. Extend architecture inventories and
   validation to both distributions without weakening direct checks.
4. Add a structural-only mode to the planned Fastlane `store_feasibility` lane.
   It compiles without signing or launching and labels its outputs as unsigned
   structural evidence. It must not mark sandbox behavior or any signed matrix
   row as passed. The mode's proposed invocation is
   `fastlane mac store_feasibility structural_only:true`; this lane is now implemented.
5. Run direct package/affected adapter tests, both graph checks, and the Store
   structural compile. Record exact outputs and all remaining runtime gates.

Exit: reviewers can inspect both generated graphs and the compiled Store
artifact, confirm helper exclusion, and reproduce direct regression checks.
Signing, service activation, durable scoped imports, presentation sharing, and
complete quit remain explicitly unverified. Begin the next slice only after
this baseline is green; do not publish the structural build.

### Active file ownership in the Store worktree

The release owner confirmed these assignments for the Tess feature above.
These are responsibility boundaries; do not edit the primary checkout or
another active task's files.

| Workstream | Exclusive file ownership | First slice / subsequent slice |
|---|---|---|
| Graph, configuration, and validation | `project.yml`, new `project-store.yml` and shared XcodeGen templates; Store files under `Config/`; `Makefile`; generation/build/bundle/signature scripts; `fastlane/Fastfile` and Store lane support; `Tests/Architecture/`, `Tests/Bundle/`, `Tests/Release/`; architecture/module/compatibility registries and schemas | Build both graphs and structural lane first; later integrate Store signing/export and runtime verification evidence |
| Runtime composition and lifecycle | `Sources/WALIAppRuntime/`, `Sources/WALIApp/`, `Sources/WALIAgent/`, `Sources/WALIAgentRuntime/WALIAgentController.swift`, `Sources/WALIAgentRuntime/IPC/`, `Sources/WALIAgentRuntime/LockScreen/`, affected `Sources/WALIUI/` files; existing app/agent/UI test files | Remove Store helper composition/UI first; later implement consent, service activation, shutdown, and controller integration with scoped-access APIs |
| Wire and scoped media/storage | `Packages/WALICore/Package.swift`, `Sources/WALIWire/` and its tests inside that package, new `WALILockScreenWire` product; `Sources/WALILockScreenHelperRuntime/` and its tests; `Sources/WALITranscoderRuntime/`, `Sources/WALIAgentRuntime/Transcoder/`, `Sources/WALIAgentRuntime/Storage/`; `Sources/WALICatalogRuntime/CatalogInstallPreparer.swift`; newly named scoped-access/storage/worker test files | Extract unchanged helper wire first; later implement bounded source/staging grants, durable authorization, group quarantine, and presentation-copy storage |

The runtime owner alone edits the two shared controllers, `WALIAppCoordinator`
and `WALIAgentController`, including import call sites. The media owner supplies
the scoped-access/storage API and tests, and sends the integration contract to
that owner; it does not concurrently patch those files. The graph owner alone
updates project dependencies and inventories after the wire owner supplies the
new product/path list. New test filenames are agreed before creation. No owner
reverts another's work; overlapping changes are sequenced or explicitly handed
off. The release owner retains submission, credentials, production operations,
final integration, and documentation/evidence coordination.

## 1. Make the distribution graph explicit

Owner: `architecture_maintainer` and build owner.

Refactor common XcodeGen declarations into checked-in shared templates; retain
`project.yml` as the direct entry point and add `project-store.yml` producing
`WALIStore.xcodeproj`. Both select the existing logical target/module names.
Store has only app → agent → private transcoder executable containment, with
StoreDevelopment and AppStore configurations and isolated DerivedData/output.
Keep generation through XcodeGen and the existing scripts/Fastlane entry points.

Extract the helper wire declarations into the direct-only static package
product. Add only the direct adapter dependencies that consume it. Store's
graph must not depend on it, either helper target, the LockScreen adapter source
directory, or helper launch resources. Do not rely on dead stripping for this
boundary. Narrow compile conditions handle the existing interleaved controller
and settings source; do not duplicate the full runtime implementation.

Update `modules.yml`, its schema, `surfaces.yml`, `generated-files.md`,
`ARCHITECTURE.md`, relevant rules, and policy checker to describe both graphs.
Keep direct capabilities registered as current. Add mutation checks that reject
one helper source, embed edge, selector dependency, or launch resource leaking
into Store. A Store setting cannot override the direct signed checks.

Exit: deterministic generation; both graph checks pass; direct focused tests
remain green; Store compiles with zero helper code/UI/configuration dependency.

## 2. Establish sandbox identity and authenticated startup

Owner: `ipc_maintainer`, `security_responder`, and foreground runtime owner.

Add the exact Store identifiers, application groups, and group-prefixed Mach
service names in ADR 0018. Add explicit sandbox entitlements for each wrapper.
Only foreground has outbound networking and user-selected read-only access;
app and agent have the shared group; agent can persist its own source bookmarks;
worker has neither group nor inherited agent storage access. Keep same-team,
exact-bundle peer authentication and reject all cross-channel identities.

Adapt lifecycle registration to an explicit supported service list. Store no
longer requires the helper plist or calls helper recovery. Establish first-run
background consent and a distinct launch-at-login choice. Disable Store agent
`RunAtLoad`, use authorized Mach-service demand for activation, and keep
crash-only restart distinct from deliberate shutdown. Use the existing main-app
login registration only when opted in; the disabled choice must leave no WALI
process running at the next login. Route explicit Quit WALI through authenticated shutdown,
including durable interruption, worker cancellation/invalidation, renderer
teardown, and foreground exit; test that launchd does not immediately restart it.

Add only the requested provisioning/profile configuration through Fastlane when
credentials are available; do not create duplicate certificates or change team
ownership. A signable StoreDevelopment fixture is required before broader UI
work. Do not use Debug or a compile/sign-only result to close lifecycle gates.

Exit: sandboxed StoreDevelopment wrappers and signed service discovery work;
matching peers connect and mismatched peers fail; consent and quit transitions
have fixture coverage and an explicit interactive test script.

## 3. Prove media and storage access before polishing Store UI

Owner: `storage_maintainer`, `ipc_maintainer`, and `media_worker_maintainer`.

Keep agent authoritative state and content under its own sandbox container.
Move only Store catalog quarantine and presentation copies to the app/agent
group. Inject root URLs through existing storage/cache seams; no caller-chosen
authoritative paths and no group entitlement on the transcoder. Keep the
foreground snapshot/cache separate from the Engine's private playback URLs.

Implement the ADR's transient-to-persistent bookmark sequence. The main app
sends an implicit transient read grant, the agent persists its own read-only
source authorization, and each attempt gets fresh source/staging grants. A
worker message revision adds a separately bounded staging bookmark. Validate
version, grant size, generation, resolved identity, containment, actual read or
write permission, and all terminal cleanup. Persist only the agent-owned source
bookmark for recovery, not a transient grant expected to survive reboot.

Do not forward the current app-created app-scoped bookmark unchanged, treat a
path as authorization, put prepared/published storage in the group, or add an
exception when access fails. Stage grants cover only one attempt directory.
Preserve fresh-destination verification and no-replace publication, even when
the worker keeps a descriptor open after cancellation. Direct wire fixtures
and behavior remain supported. Record the Store message revision/negotiation
and updated source-authorization semantics in compatibility fixtures.

Use copied fixtures to prove picker/drag-drop import, stale/revoked grant
failure, reboot recovery, worker staging writes, denial of unrelated paths,
symlink rejection, cancellation races, stale claims, agent restart, and
foreground disappearance after accepted work. Verify preview/poster reads in
the foreground without granting access to authoritative media. Test cache
eviction and accounting rather than creating an unbounded second library.

Exit: signed access proof establishes read-only input and bounded staging with
no worker access to prepared/published/database/group roots. If this cannot be
proved, record the failure and revise the proposal before choosing another
transport. No broad-entitlement fallback is authorized.

## 4. Complete signed desktop and lifecycle feasibility

Owner: `agent_runtime_maintainer` with the person operating the test session.

Use `fastlane mac store_feasibility` once implemented. Record artifact SHA-256,
source commit, macOS build, Team ID, architecture, display topology, media
profile, and actual outcomes. Use an explicitly approved test account/session
and synthetic media. Repository automation must not change the user's active
desktop, mutate private Apple wallpaper stores, grant permissions, or simulate
the manual acceptance result.

| Gate | Required evidence |
|---|---|
| Startup/consent | Fresh install; consent refused/accepted; OS approval required/denied/revoked; no helper item |
| IPC | Correct identity accepted; other channel/team rejected; restart/reconnect and full resync |
| Playback | Supported minimum and current macOS; available architectures; multi-display including three-display topology; all content-fit modes |
| Session/display changes | Spaces/full screen; disconnect/reconnect; sleep/wake; session lock/unlock; no private-store access |
| Lifetime | Window close preserves consented playback and accepted imports; explicit Quit from either UI stops all WALI processes without respawn |
| Login/upgrade | Disabled/enabled login preference; logout/login; interrupted upgrade; no stale service or cross-channel data access |
| Imports/recovery | Scoped grants after foreground exit, cancellation, crash/reboot, missing/revoked source, bounded disk failure |
| Shared directories | Relaunch reuses real Presentation/CatalogQuarantine directories without replacing contents, ownership or permissions; files and symlinks are rejected |
| Foreground visibility | Occlusion/minimize/hide pauses polling without removing ready navigation, import or authentication sheets; returning resumes polling; initial consent and registration failures still gate readiness |
| Resource budget | Same hardware/media/topology baseline; duration, median/p95 CPU/memory/energy where required by ARCHITECTURE.md |

Missing topology/hardware or an unperformed case remains open. Do not downgrade
to static wallpaper, move rendering into the app, or silently remove supported
behavior in response to a failure; bring concrete evidence back to the owner.

Exit: the signed matrix passes and is reviewed, or Store remains unshippable
with a specific failure and bounded next investigation. Direct release proceeds
under its own existing gates.

## 5. Close marketplace and public-review requirements separately

Owner: `catalog_maintainer`, `security_responder`, and `project_owner`.

Use the initial review register for UGC blocking/reporting/moderation, mature
content controls/rating, effective public privacy and support URLs, deletion
completion and Apple authorization revocation, reviewer access, production
worker/signer readiness, privacy disclosures, encryption answers, and complete
license notices. Produce end-to-end evidence against the intended deployment;
schema deployment or a staging fixture is not a production user journey.

Keep accepted catalog signatures, independent agent install verification,
networkless media processing, HEVC Main 10 quality, account-free local use, and
offline installed playback. Do not resolve these gates by covertly disabling
creator/account/catalog features. A smaller submitted feature set requires an
explicit product decision, truthful metadata, and its own review packet.

Exit: enabled features and advertised behavior agree; all P0/P1 submission
findings are fixed or explicitly resolved with supporting evidence, including
working reviewer credentials/access that are never committed.

## 6. Archive, validate, upload, and report using Fastlane

Owner: release owner; credentials and Apple agreements remain separate inputs.

Extend the existing Fastfile with the planned `store_archive` and `store_upload`
lanes. Archive the Store graph/configuration with the correct Store signing
profiles, export the Xcode-produced Store package, and validate all embedded
signatures, sandbox entitlements, peer identifiers, provisioning, no-helper
boundary, branding, privacy resources, and third-party notices. Preserve the
existing Developer ID archive → notarize app → package/sign/notarize DMG order.

Upload through Fastlane only after the signed runtime and public-readiness gates
pass. Confirm App Store Connect processing and resolve validation errors before
selecting the build for submission. Use the actual version/build policy and
separate final artifact hashes. An upload is not review submission; review
submission is not approval; a draft or ad-hoc artifact is not a signed release.

Document the Store feature difference, clean install/import instructions,
background consent and Quit behavior, effective legal/support links, reviewer
steps, tested OS/hardware, residual limitations, and exact release commands.
Report GitHub release URL and signed artifact evidence separately from Store
build ID, processing status, submission status, and eventual review result.

## Completion and rollback

This plan is complete only when the implementation, both distribution checks,
signed feasibility, production/reviewer requirements, and requested release /
Store submission outcomes have evidence. Approval alone closes none of them.
If a gate fails, retain the direct build and user data, stop the affected Store
step, and record the precise next action. Remove only owned generated Store
artifacts when rolling back; do not delete user media, live registrations,
credentials, production data, or another task's files.
