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
- app/agent and agent/worker service-name surfaces → `service_identity`
- content store, preferences, URL schemes, catalog manifest, lock-screen
  manifest, and diagnostic export → their same-named singular kind

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
validation/confirmation. Catalog details require signatures and remain
deferred. Diagnostics require a lease, redaction classes, and excluded payload
classes. The implemented Lock Screen surface is limited by accepted ADR 0008,
an exact system-build and manifest-version allowlist, fixed WALI ownership
identifiers and bounds, a reject-before-write policy, and a redacted
version-gated fixture.

## Configuration-keyed identities

Identity/configuration maps contain exactly `Debug`, `Development`, and
`Release`. Configuration xcconfigs are the build-setting source; runtime targets
reference those variables rather than repeating identifier literals in
`project.yml` or generated plists.

- Bundle identity maps each configuration to WALI, WALIAgent, and
  WALITranscoder identifiers and must match resolved build settings. Debug uses
  `com.wali.debug.*`, Development uses `com.wali.development.*`, and Release
  retains `com.wali.*`.
- Container identity maps WALI and WALIAgent to group IDs. The checker resolves
  the xcconfig variable in each entitlement file; Debug intentionally has no
  entitlement, Development uses `group.com.wali.development.shared`, and
  Release uses `group.com.wali.shared`.
- Service identity maps each configuration to `current` and `target` service
  names. Configured worker service names must match the worker bundle ID.
  App↔agent current names stay empty while target names reserve each
  configuration's planned `WALIAgent.control` identity. ADR 0006 remains
  proposed until its signed lifecycle spike passes.

These maps prevent a Development-only identity from being presented as a Debug
or Release guarantee.

## Fixture lifecycle

- `planned`: no implemented format.
- `deferred`: behavior and fixtures are deferred.
- `not_applicable`: configured identity, not a versioned runtime format.
- `passing`: implemented surface with existing fixture paths.

The checker proves schema and path presence. Owning tests must still prove
format semantics, migrations, malformed/newer rejection, and any old-binary
rollback claim.
