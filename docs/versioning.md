# Versioning and Product Compatibility

WALI versions product releases, format epochs, additive revisions, wire
messages, and migration compatibility independently. A product version never
substitutes for a format or protocol version.

The authoritative surface inventory is
[`docs/compatibility/surfaces.yml`](compatibility/surfaces.yml), with field
semantics in its [schema](compatibility/surfaces-schema.md).

## Product versions

- `CFBundleShortVersionString` is the user-facing product version.
- `CFBundleVersion` is a monotonically increasing build identifier.
- Every migration names the minimum product that can read and write its result.
- Pre-1.0 status does not permit silent reset, destructive fallback, or an
  unsupported rollback claim.

## Format epoch and additive revision

Each implemented versioned surface identifies a current pair:

- `epoch` is positive and changes when an older reader cannot interpret
  the shape without an explicit migration.
- `revision` starts at zero within an epoch and increases for additions
  that readers in the declared range can safely ignore or default.

The current format is `(epoch, revision)`. `readable_epochs` has one entry per
supported epoch, each with inclusive minimum and maximum revisions. This can
represent disjoint support such as late revisions of epoch 1 and early revisions
of epoch 2; one global min/max cannot. `additive_compatibility:
declared_ranges_only` means no revision outside those entries is implied
compatible.

Unimplemented, configured-only, and deferred surfaces use a null current pair,
an empty readable-epochs list, and null additive compatibility. They do not
invent version zero.

Writers emit only the declared current pair. Readers reject unknown newer epochs
and unsupported critical revisions before mutation. Unknown optional fields are
preserved or ignored only when that behavior is part of the epoch contract and
proved by fixtures.

## Product reader and writer compatibility

For each implemented surface:

- `minimum_reader` is the oldest product version proved to read the current
  state.
- `minimum_writer` is the oldest product version allowed to write without
  violating current invariants.
- `rollback_readers` lists old product versions explicitly promised to read
  post-migration state.
- `rollback_fixture_paths` contains fixtures exercised with those old binaries
  or readers.

Product compatibility is migration-specific. It cannot be inferred from a
shared epoch, additive-looking schema change, or immutable media bytes.

An empty `rollback_readers` list means binary rollback is **not promised**. In
that case an upgrade must either perform no incompatible mutation until commit,
fail closed with the old state intact, or provide a documented forward repair.
The project does not promise rollback that the model and fixtures cannot prove.

## Wire compatibility

The app↔agent and agent↔worker channels are separate surfaces with independent
directions and message catalogs.

Protocol version and message version are distinct:

- protocol version governs envelope semantics and negotiation;
- message type uses a stable explicit tag; and
- message version governs one bounded payload schema.

Every request envelope includes protocol version, message type/version, request
ID, idempotency key, expected revision where relevant, and payload length.
Replies correlate to the request and use stable error codes. Snapshot sequences
detect gaps and trigger a bounded full resynchronization.

Do not expose synthesized Swift enum representations or framework objects on
the wire. Use bounded `Data` or narrowly allowlisted `NSSecureCoding` graphs.
Unknown critical messages, unsupported versions, malformed input, and size
violations fail closed before reaching the Engine.

The intended rolling policy may be `N` and `N-1`, but it becomes a guarantee
only when the surface inventory records both epochs' revision ranges and golden
fixtures prove both readers.

## Stable identifiers and errors

- Persisted and wire enum cases use explicit stable integer or string values.
- Identifiers have documented syntax and maximum encoded length.
- Error codes are stable; localized prose is presentation data.
- Public tags, namespaces, and error codes are never reused.
- A changed required meaning receives a new message revision or format epoch.

## Fixture gate

Before implementing or changing a versioned surface:

1. Add immutable fixtures for every declared readable pair.
2. Prove the current reader handles each fixture without rewriting on read.
3. Add malformed, oversized, unknown-newer, and interrupted-write fixtures.
4. Add migration fixtures for every supported source pair.
5. If rollback is promised, run the named old reader against post-migration
   fixtures and record those paths.
6. Update `surfaces.yml` only after the owning focused suite passes.

Fixtures are compatibility contracts. Add a new fixture/version rather than
editing historical bytes.

## Deprecation

A pair can leave its readable epoch range only after supported releases migrate it
and no rollback promise depends on it. Removal records the last reader product,
user impact, forward recovery path, and evidence that no supported writer still
emits the pair.
