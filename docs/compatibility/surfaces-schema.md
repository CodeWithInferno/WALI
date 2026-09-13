# Compatibility Surface Schema

[`surfaces.yml`](surfaces.yml) is the strict inventory for WALI persisted,
wire, identity, layout, input, and export contracts. Schema version 3 uses
unique surface IDs, controlled kinds, per-epoch revision ranges, and
configuration-keyed identities.

The Psych-based checker rejects duplicate YAML keys before construction and
validates required IDs/kinds, exact per-kind fields, module references,
implementation/version consistency, configuration maps, actual configured
identities, and implemented fixture paths.

## Common fields

Every surface contains exactly the common contract fields:

- `id`: stable snake-case ID.
- `kind`: checker-controlled detail schema.
- `owner_role`: controlled role from `GOVERNANCE.md`.
- `implementation`: `unimplemented`, `configured`, `implemented`, or
  `deferred`.
- `version`: current format plus readable epoch ranges.
- `product_compatibility`: minimum reader/writer and rollback evidence.
- `module_access`: reader/writer module IDs.
- `fixture_gate`: lifecycle status and repository-relative paths.
- `details`: fields required by the surface kind.

Required IDs and kinds:

- `sqlite_schema` → `sqlite_schema`
- `artifact_manifest` → `artifact_manifest`
- `model_records` → `model_records`
- `app_agent_wire`, `agent_worker_wire` → `wire_channel`
- `bundle_identifiers` → `bundle_identity`
- `application_group_containers` → `container_identity`
- `app_agent_service_names`, `agent_worker_service_names`, and
  `agent_lock_screen_helper_service_names` → `service_identity`
- content store, preferences, URL schemes, catalog manifest, lock-screen
  manifest, and diagnostic export → their same-named singular kind;
- `catalog_revocations` → `catalog_revocations`;
- `catalog_acknowledgements` → `catalog_acknowledgements` (bounded foreground recovery only);
- `marketplace_server_schema` → `server_schema`;
- catalog/creator/moderation API entries → `public_api`;
- `catalog_signing_keys` → `signing_key_registry`;
- `classifier_model_registry` → `model_registry`;
- `marketplace_storage_paths` → `storage_paths`; and
- `lock_screen_helper_wire` → `wire_channel`.

Missing, extra, or malformed required detail fields fail closed.

## Per-epoch versions

Implemented versioned surfaces use:

```yaml
version:
  current: { epoch: 2, revision: 3 }
  readable_epochs:
    - { epoch: 1, minimum_revision: 4, maximum_revision: 7 }
    - { epoch: 2, minimum_revision: 0, maximum_revision: 3 }
  additive_compatibility: declared_ranges_only
```

Epochs are unique positive integers. Revisions are nonnegative and each
minimum is at most its maximum. The current pair must be inside its epoch's
declared range. Additive compatibility exists only inside these explicit
ranges; one global min/max cannot represent disjoint epoch support.

Unimplemented, configured-only, and deferred surfaces use `current: null`,
`readable_epochs: []`, and `additive_compatibility: null`. They do not invent
version zero.

`rollback_readers` is an explicit old-binary promise. Every listed product
requires existing `rollback_fixture_paths`; an empty list means rollback is not
promised.

## Strict detail schemas

`sqlite_schema` records the sole runtime owner/openers and a stepwise migration
policy requiring fixtures for every supported epoch/revision and rejection of
unknown newer state before write.

`artifact_manifest` records agent trust authority, SHA-256, immutable versioned
schema policy, and untrusted worker claims.

`model_records` inventories the independently encoded WALIModel aggregate
roots. It fixes the initial logical schema at epoch 1 revision 0, records both
golden and invalid fixtures, and explicitly denies any canonical-byte claim.
Its `Codable` contract covers logical keys, tags, validation, and round trips;
wire framing, signatures, persistence encoding, and canonical hashing remain
separate surfaces.

Each `wire_channel` records the exact two directions and a message catalog.
Catalog envelopes include protocol/message versions, request ID, idempotency
key, expected revision, and payload length.

`content_store` records current/target layout, SHA-256, same-volume scope, and
no-replace publication. Preferences record agent authority and fail-closed
unknown-newer policy. URL schemes are configuration-keyed and require
validation/confirmation. Catalog manifest/revocation details fix canonical
bounds, Ed25519 trust, SHA-256 identity, allowed roles/reasons, approved-host
policy, fixture paths, and catalog-only revocation scope. Public API surfaces
name the versioned contract, body/page bounds, and prohibition on exposed
tables. Server-schema, signing-key, model, and storage surfaces record accepted
target epochs and fail-closed migration/trust/path rules without claiming a
runtime implementation before their migrations/services exist. Diagnostics
require a lease, redaction classes, and excluded payload
classes. The implemented Lock Screen surface is limited by accepted ADR 0009,
an exact system-build and manifest-version allowlist, fixed WALI ownership
identifiers and bounds, a reject-before-write policy, and a redacted
version-gated fixture. The adapter selects only the main display's asset through
the current-user global linked nodes, clears the display and Space maps while
active, and journals the exact four-value preimage. Rollback restores that
preimage only while provider/configuration and all other managed structure still
match; only WallpaperAgent's `LastSet` and `LastUse` dates may drift.

## Configuration-keyed identities

Identity/configuration maps contain exactly `Debug`, `Development`, and
`Release`. Configuration xcconfigs are the build-setting source; runtime targets
reference those variables rather than repeating identifier literals in
`project.yml` or generated plists.

- Bundle identity maps each configuration to WALI, WALIAgent, WALITranscoder,
  and WALILockScreenHelper and must match resolved build settings. Debug uses
  `com.wali.debug.*`, Development uses `com.wali.development.*`, and Release
  uses `io.github.codewithinferno.wali.*` under ADR 0020.
- Container identity maps the app, agent, and helper to group IDs. The checker
  resolves the xcconfig variable in each entitlement file; Debug intentionally
  has no group, Development uses `group.com.wali.development.shared`, and
  Release retains `group.com.wali.shared`. The worker has no group entitlement.
- Service identity maps each configuration to `current` and `target` service
  names. The app/agent and agent/helper names match the configured control
  services; the helper name ends in `WALILockScreenHelper.control`. The private
  worker service name matches the worker bundle identifier.

The checker requires exact selected launch plist filenames, labels,
`BundleProgram`, `MachServices`, `RunAtLoad: true`, and `KeepAlive.Crashed: true`.
Generated service lookup and expected-peer metadata must derive from the same
configuration settings, including the worker's expected agent identity.

These are configured facts, not signing or registration evidence. ADR 0006's
signed service lifecycle and ADR 0013's signed helper acceptance remain separate
gates. The maps must not present Development checks as Debug or Release proof.

## Fixture lifecycle

- `planned`: no implemented format.
- `deferred`: behavior and fixtures are deferred.
- `not_applicable`: configured identity, not a versioned runtime format.
- `passing`: implemented surface with existing fixture paths.

The checker proves schema and path presence. Owning tests must still prove
format semantics, migrations, malformed/newer rejection, and any old-binary
rollback claim.

## Store distribution identities

The `store_distribution` surface has kind `distribution_identity`. Its exact
configuration map records StoreDevelopment/AppStore bundle IDs, application
groups, and group-prefixed app–agent Mach service names. `policy_adr` is ADR 0018;
`cross_distribution_migration` is `none`. Signing/container/runtime feasibility
is pending, so its implementation, version, and fixture gate deliberately do
not claim verified compatibility. Direct identity surfaces retain their three
existing configurations.

The direct helper wire implementation is now product `WALILockScreenWire`;
its payload and Objective-C selectors are unchanged. Moving source between
products changes linkage authority, not the existing wire message version.

`store_wire_contracts` separately inventories Store import grant revision 1,
worker request/negotiation revision 2, and payload-free lifecycle callback
revision 1. It records independent bookmark bounds, the unchanged 4 MiB global
envelope, nonce correlation before granting media access, and exact selectors.
Its listed local regressions cover value bounds and controlled adapters;
compatibility remains gated on signed cross-process scope/recovery evidence.
These additions do not rewrite the existing direct wire contract.

Store presentation demand is the additive `preparePresentation` command on the
existing perform/envelope revision. It carries at most 32 unique item UUIDs and
no caller path. The agent validates IDs against its committed snapshot and
returns bounded group projection URLs. It does not grant foreground access to
master media or authorize arbitrary filesystem requests.

## Catalog acknowledgements

The foreground stores schema version 1 only after the agent confirms verified
installation. Records bind subject, wallpaper, release, one-use receipt, manifest
digest, stable idempotency key and original receipt expiry. This format contains
no authentication bearer or local library authority. Each bundle identifier and
project host receives a separate private path. Atomic files are mode0600 inside
mode0700 directories; readers reject unknown versions and oversized/duplicate
records before writing. At most128 entries/256KiB are retained. Exact retries can
recover lost successful responses for seven days after expiry; the server still
rejects expired first-use receipts. Only the matching signed-in subject replays.

## Still catalog extension (ADR0027)

The catalog_manifest surface reads video1.0 and still2.0. Its current version is
2.0; existing video manifests and signatures retain1.0. The exact
required_artifact_roles_by_media_kind map contains video (thumbnail, poster,
preview, video_default) and still (thumbnail, poster, image_default). The global
artifact-count range is3–7, with exact kind-specific enforcement in each reader.
The V2 reader contract is docs/api/catalog-v2.md. Native app/agent and private
worker protocol3 rejects earlier protocol versions; local runtime snapshots are
1.2, with declared legacy-video reads of1.0–1.1 and no writes after unknown newer
schemas. These native implementations do not claim the broader envelope fixture
gates are complete merely from focused media tests.
