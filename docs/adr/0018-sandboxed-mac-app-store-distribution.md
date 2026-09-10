# 0018: Add a sandboxed Mac App Store distribution

- status: partially_superseded
- date: 2026-09-09
- owner_role: architecture_maintainer
- accepted_by: project_owner
- approval_reference: project-owner explicit session approval 2026-09-09: "Approve the Store variant"
- superseded_by: 0020
- superseded_scope: 0020=direct_release_identifier_namespace
- supersedes: 0013
- supersedes_scope: 0013=store_helper_presence,store_agent_sandbox_requirement
- related: [0001](0001-process-topology.md), [0003](0003-agent-owned-runtime-state.md), [0004](0004-engine-owned-use-cases.md), [0005](0005-content-addressed-artifacts.md), [0006](0006-named-authenticated-xpc.md), [0011](0011-supabase-marketplace-control-plane.md), [0012](0012-signed-remote-catalog-releases.md), [0015](0015-hostile-media-canonicalization.md), [0017](0017-marketplace-hevc-main10.md)

ADR [0020](0020-direct-release-identifier-namespace.md) supersedes only the
requirement below to preserve direct Release identifiers and the data namespaces
derived from them. Its approved first-release identity transition leaves this
record's Store identities, architecture, and other direct invariants in force.

## Context

The owner requested a signed GitHub release followed by Mac App Store
submission. The [initial review](../release/app-store-review-2026-09-09.md)
found that the current Release graph includes an unsandboxed agent and the
Full Disk Access helper. Its Fastlane lane deliberately exports a Developer ID
application. That distribution remains useful and must remain available.

Apple requires appropriately sandboxed Mac App Store applications and public,
appropriate APIs for accessing other applications' data. The helper's fixed
Apple wallpaper roots and private-store transactions cannot be part of the
Store product. The ordinary desktop renderer uses public AppKit windows and
Core Graphics window levels; its signed sandbox behavior remains unproven.
[App Review Guidelines 2.4.5 and 2.5.1](https://developer.apple.com/app-store/review/guidelines/#performance)

This decision changes distribution-specific process containment, service
identity, filesystem access, and package composition. The project owner supplied
the explicit approval required by [GOVERNANCE.md](../../GOVERNANCE.md) on
2026-09-09: "Approve the Store variant". This approves implementation and
testing; it does not establish implementation, signed feasibility, or Store
acceptance.

## Decision

### Two distributions, one product implementation

Keep the existing `project.yml` Developer ID graph, identifiers, library paths,
helper, signing policy, and `fastlane mac release` workflow. Add a separately
generated `WALIStore.xcodeproj` with a checked-in `project-store.yml` entry
specification and shared XcodeGen target templates. Reuse the existing Swift
sources, static runtime modules, package products, and Engine. Do not fork the
application implementation or introduce another packaging system.

The Store graph contains exactly the following executable containment:

```text
WALI.app
  Contents/Library/LoginItems/WALIAgent.app
    Contents/XPCServices/WALITranscoder.xpc
```

Keep the logical target/module names `WALI`, `WALIAppRuntime`, `WALIAgent`,
`WALIAgentRuntime`, `WALITranscoder`, and `WALITranscoderRuntime`. Separate
generated projects and DerivedData directories prevent same-name product
collisions. Shared templates describe common compilation; each entry spec
explicitly selects its sources, dependencies, resources, and embed edges.
The architecture inventory and checker must validate both concrete graphs.

Use the following distinct identities; registering them is a later signed-build
prerequisite, not evidence supplied by this ADR:

| Setting | StoreDevelopment | AppStore |
|---|---|---|
| Main app | `com.wali.store.development.WALI` | `com.wali.store.WALI` |
| Agent | `com.wali.store.development.WALIAgent` | `com.wali.store.WALIAgent` |
| Transcoder | `com.wali.store.development.WALITranscoder` | `com.wali.store.WALITranscoder` |
| App/agent group | `group.com.wali.store.development.shared` | `group.com.wali.store.shared` |
| Agent Mach service | `group.com.wali.store.development.shared.agent-control` | `group.com.wali.store.shared.agent-control` |
| Signing purpose | Apple Development feasibility | Mac App Store distribution |

All three Store executables enable App Sandbox and retain Hardened Runtime.
StoreDevelopment and AppStore use the same sandbox, containment, and feature
boundary. Their signing, identifiers, and debug settings differ. The Store
product retains the existing supported macOS floor and codec policy.

### Exclude private Lock Screen integration by construction

The Store graph does not build, link, embed, register, discover, or launch
`WALILockScreenHelper` or `WALILockScreenHelperRuntime`. It excludes all five
files currently under `Sources/WALIAgentRuntime/LockScreen`, all helper launch
plists, helper Info keys, fixed Apple-store paths, process-refresh adapters,
helper recovery/journal access, and associated settings, notices, commands,
and Full Disk Access navigation. Exclusion must be established by the target
graph and compiler, not a remotely changeable flag or link-time dead stripping.

The helper protocol is currently mixed into
`WALIWire/AgentXPCProtocol.swift`. Move those existing helper-only declarations
into a small direct-distribution-only `WALILockScreenWire` static package
product. The direct agent and helper adapters consume it; Store targets do not.
This is a concrete existing transport separation, not a new runtime service or
third-party dependency. Preserve the helper's existing Objective-C selectors,
encoded payloads, version, and authentication behavior.

Use a compilation condition such as `WALI_APP_STORE` only where shared runtime
source currently interleaves direct-only composition or UI. The Store build
must have no helper connection, selector implementation, private-store adapter,
or activation path. The inert `lockScreenContinuityEnabled` compatibility field
may remain in existing shared preference records to preserve decoding; the
Store agent always reports it false and rejects attempts to enable it before
mutating state. That field does not expose a hidden Store feature.

These are the precise scoped changes to ADR 0013: its helper-presence decision
and unsandboxed-agent decision apply only to direct distribution. All its
direct-distribution privilege, authentication, restore, and safety rules remain
in force. Reciprocal scoped metadata and a narrow note are recorded in 0013;
its historical decision is preserved. ADR 0006 remains proposed until
its own signed lifecycle acceptance is recorded. Approval here permits the
Store implementation and feasibility work, not a claim that those gates passed.

### Keep authority private; share only handoff and presentation data

The Store agent remains the sole Engine host and authoritative writer. Its
database/state, journals, prepared files, and published content-addressed
objects live in its own sandbox container, using the existing `RuntimeStore`
and `LibraryPaths` seams. They do not move into the app group.

Only the foreground app and agent receive the Store application-group
entitlement. Resolve that container through
`containerURL(forSecurityApplicationGroupIdentifier:)`; do not derive another
process's container from its bundle identifier. The group has two bounded,
reconstructible uses:

- `CatalogQuarantine`: foreground-downloaded opaque catalog bytes addressed by
  existing UUID references. The agent treats these as untrusted input and
  independently applies signature, digest, canonicalization, and publication
  checks. A shared path does not grant install authority.
- `Presentation`: bounded copies of committed posters/previews for foreground
  library display. Agent snapshot projection supplies those presentation URLs;
  desktop playback continues to use the private published object. Missing or
  modified presentation copies are replaceable cache state, never authoritative
  media or input to publication. Account for and evict these copies within the
  existing storage budget; do not duplicate every master video.

The foreground has outbound network access for the existing catalog/auth and
creator adapters, read-only user-selected-file access, and app-scoped bookmarks
only where it persists its own user authorization. The agent has its own
app-scoped bookmark capability for durable imports and the app group; it gains
no network, automation, Full Disk Access, broad filesystem, or temporary Mach
exception entitlement. The worker has no app group, network, user-selected-file
entitlement, or inherited access to the agent's container.

### Explicit media access across sandbox boundaries

Keep bounded `Data` messages and the existing import/worker ownership model.
App-scoped persistent bookmarks are not interchangeable across executable
identities. Apple documents implicit ephemeral bookmark scope for passing
access to another process; this is the selected handoff mechanism, subject to
the signed tests below. Neither a raw URL nor shared Team ID proves access.
[Foundation bookmark scope](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withoutimplicitsecurityscope)

1. The foreground obtains read-only access through the existing picker or
   authorized drag-and-drop. It sends a bounded transient bookmark carrying
   implicit scope to the authenticated agent. The current persistent
   `.withSecurityScope` bookmark must not simply be forwarded unchanged.
2. The agent resolves the transient grant and creates its own persistent,
   read-only app-scoped source bookmark before accepting a durable import.
   Restart/reboot recovery uses that agent-created bookmark. Missing, stale,
   revoked, or insufficient access produces a recoverable failure or requests
   renewed user selection; it never falls back to unscoped source access.
3. For each `(jobID, generation)`, the agent creates fresh transient source and
   attempt-staging bookmarks. Extend the bounded worker request with an explicit
   staging grant; keep source/staging URLs only as values to validate against the
   resolved grants. Never grant the library root, prepared directory, published
   objects, database, presentation cache, or app-group root to the worker.
4. The worker resolves only those current-attempt grants. The input grant must
   be read-only; staging permits that attempt's output. Balance scoped access
   and close handles on every terminal path. Signed tests must establish both
   intended access and denied unrelated access. If the supported bookmark path
   cannot meet those bounds, stop and revise this ADR with evidence; do not add
   broad exceptions or silently change transport.
5. Worker replies remain untrusted claims. The agent copies/verifies bytes into
   a different, private prepared destination and publishes under ADR 0005.
   Cancellation, connection invalidation, and scope cleanup are not treated as
   proof that every worker-held descriptor or grant has been revoked.

Record the changed worker request and source-authorization meaning in the
compatibility inventory, codec fixtures, and version policy before dispatch.
Use a separately negotiated Store worker message revision; an old/unknown peer
must fail before receiving a job. Retain existing direct-distribution payloads
and fixtures. Do not enlarge the global envelope limit just to fit an extra
unbounded bookmark. Persistent bookmark creation and resolution must follow
Apple's [app-scoped bookmark contract](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata%28options%3Aincludingresourcevaluesforkeys%3Arelativeto%3A%29).

### Registration, consent, and explicit quit

Use the existing `AgentLifecycleController`, `SMAppService`, and authenticated
named XPC seam. The Store service list contains only the bundled agent and does
not require helper configuration. Use the group-prefixed service names above in
launchd metadata, Info configuration, listener, and client. Authenticate exact
same-channel bundle identifiers and Team ID; reject direct/Store and
development/distribution cross-connections before decoding commands. Apple's
[group IPC naming rules](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
apply without temporary Mach exceptions.

Before first registration, explain that the agent keeps wallpapers running
after the window closes and obtain explicit user consent. Consent to that
session behavior is distinct from optional launch at login. The Store agent's
plist disables `RunAtLoad` and starts the agent on authorized Mach-service
demand. A crash-only restart policy must not become unconditional KeepAlive.
The opt-in main-app login registration uses the existing `SMAppService.mainApp`
path; when disabled, no WALI process should start at the next login. Validate
registration/status and launch-plist behavior under both choices; do not infer
consent from a successful API call.

Closing a window leaves the consented agent and accepted work running.
**Quit WALI**, from either UI, requests authenticated shutdown of the agent,
worker attempts, renderer, and foreground process. Persist interruption/cleanup
state, complete bounded shutdown, and prevent launchd from immediately
respawning the deliberately stopped agent. Retain the user's explicit login
preference without treating Quit as revocation of all settings. App Sandbox
must not be bypassed to implement shutdown. Cross-channel coexistence means
isolated identities and data, not supported simultaneous wallpaper rendering;
require stopping the other active WALI distribution before starting playback.

### Marketplace readiness is a separate release gate

Retain the planned catalog, authentication, creator, moderation, and account
capabilities and the trust boundaries in ADRs 0011–0017. This ADR does not
approve hiding those features to avoid the initial review findings, change
UGC policy, introduce purchases, or authorize incomplete production workflows.

The sandbox feasibility build may run controlled fixtures or an explicitly
identified staging environment. Before Store submission, the final enabled
feature set needs production evidence for reporting/blocking, moderation,
effective public policies/support, account deletion and Apple authorization
handling, content controls, reviewer access, and signed media publication.
Any decision to submit a reduced product requires a separate explicit product
decision and truthful metadata; a passing sandbox build does not make the
marketplace ready.

### Fastlane and release artifacts

Extend the existing Fastfile with `store_feasibility`, `store_archive`, and
`store_upload` lanes. They are planned names, not currently available commands.
Use Xcode's Store archive/export path through Fastlane and the proper App Store
distribution profiles, then Fastlane's App Store Connect upload workflow.
Use separate artifact/log roots and validate Store signatures, provisioning,
sandbox entitlements, graph, privacy resources, and bundled license notices.
Do not pass Store products through the Developer ID verifier or notarization
lane. No identity, profile, session, API key, agreement, or successful upload is
implied by this ADR. Keep credentials outside source, generated metadata, and
logs. GitHub release completion and Store upload/review/approval remain distinct
reported states.

## Invariants

- Direct distribution retains its current identifiers, helper behavior, data,
  authenticated topology, signing, and notarized ZIP/DMG workflow.
- Store artifacts contain no private Apple wallpaper integration or FDA flow.
- One agent owns each channel's Engine, accepted jobs, authoritative store,
  verified publication, and rendering; the foreground never takes over.
- The worker cannot access authoritative storage and cannot publish content.
- Cross-channel data, credentials, service discovery, and grants are isolated.
- No new third-party runtime dependency, codec, renderer strategy, root helper,
  automation entitlement, or broad sandbox exception is introduced.
- Source tests and successful signing do not substitute for signed interactive
  feasibility or App Store review.

## Alternatives considered

- Submit the current Developer ID artifact: incompatible with the Store
  sandbox and private-store boundary.
- Enable sandbox on every existing configuration: disrupts direct distribution
  and requires unsupported changes to its optional Lock Screen behavior.
- Hide the Lock Screen toggle but retain the helper/code: leaves the prohibited
  capability and dependency graph in the submitted artifact.
- Add only another build configuration to the current unconditional embed
  graph: cannot demonstrate that the helper is absent by construction.
- Put the database and all media in an app group, including the worker: grants
  broader mutation access and breaks the existing publication trust boundary.
- Replace the agent with foreground-owned rendering or reduce to static
  wallpapers: changes accepted lifetime/ownership or product behavior without
  evidence that the existing public renderer fails under sandboxing.
- Build a separate Store implementation: duplicates product logic and recovery
  behavior when only concrete composition and access adapters must vary.

## Consequences

Store distribution adds a graph, signing/profile set, isolated data namespace,
scoped access handling, and signed acceptance workload. Some presentation bytes
are duplicated in a bounded cache. The Store version has no Lock Screen
continuity feature and must describe that accurately. Bookmark persistence,
named service activation, rendering, and complete quit remain material
feasibility risks; failure pauses Store submission, not the signed GitHub path.

## Migration and rollback

No automatic migration or shared writable library crosses distribution
identities. First Store launch starts with its own library. Importing media
requires the normal picker and verification path; Store does not inspect the
direct application's private helper journals, reset Apple wallpaper choices,
or remove the direct installation. The user stops/restores direct Lock Screen
continuity through the existing signed direct application before switching.

Preserve existing format epochs unless a documented new worker message or
source-authorization representation requires a version change. Snapshot
presentation copies are rebuildable; they never become migration authority.
Rollback removes or disables the unshipped Store graph/lanes without changing
direct data. A shipped Store rollback requires old-reader fixtures for its own
persisted state; unsupported state fails closed without deletion.

## Verification

Implementation follows the [Store delivery plan](../plans/2026-09-09-mac-app-store-distribution.md).
Acceptance requires all of the following, with artifact hash, commit, macOS
build, signing Team ID, and result recorded without personal paths or media:

- Direct `make verify` and Developer ID archive/sign/notarization checks remain
  green, including helper compatibility tests and branding/DMG verification.
- Generated Store graph and archive prove the three wrappers are sandboxed,
  correctly signed, and helper-free; forbid helper selectors/private-store
  adapters, launch resources, FDA links, unsafe entitlements, and cross-channel
  identifiers. Validate current shipping macOS and the supported minimum.
- Signed first-launch consent, matching/mismatched XPC peers, registration,
  restart, upgrade, login behavior with each preference, and bounded complete
  quit pass without an unrequested background process or respawn.
- Signed import proves transient access, agent-owned persistent authorization
  after reboot, bounded worker input/staging access, denial of unrelated and
  published paths, revoked grants, cancellation, crash, and recovery. Use
  copied synthetic fixtures only; denial tests target disposable locations.
- Signed desktop playback proves multi-display placement, three-display
  behavior where available, Spaces, reconnect, sleep/wake, lock/unlock, preview,
  window-close survival, and resource budgets. Do not touch Apple's private
  wallpaper store or alter the user's live desktop in an automated test.
- Final archive privacy/license resources, production marketplace journeys,
  review metadata/access, and upload processing are separately verified. A
  missing hardware topology, credential, or production path stays an explicit
  incomplete gate rather than a passing result.
