# Migration, Installation, and Recovery Policy

Migrations preserve user intent and recoverability across database, artifact,
preference, wire, and exported-format evolution. They are explicit
Engine-authorized operations, not opportunistic decoder side effects.

## Ownership

`WALIAgent.app` is the only WALI runtime process that opens SQLite. One Engine
instance authorizes migrations and persistent mutations through `RuntimeStore`.
The main app and worker receive snapshots or bounded messages; neither opens the
database or shared mutable state.

The agent establishes single-owner startup before inspection or migration. If
ownership, format support, required disk space, or recovery cannot be proved,
startup fails closed without resetting the store.

## Migration declaration

Every migration declares:

- source and destination `(epoch, revision)`;
- minimum reader and writer product versions;
- whether old-binary rollback is promised;
- old-reader fixture paths for every promised rollback product;
- preconditions, postconditions, and invariant checks;
- transaction and filesystem durability boundaries;
- interruption/retry behavior; and
- forward repair when rollback is unavailable.

An epoch change is incompatible until migrated. An additive revision is
compatible only when declared readers prove safe defaulting or field
preservation. Names such as “additive” or “expand/contract” are not guarantees
without fixtures.

## SQLite migration sequence

1. Verify store identity, exclusive runtime ownership, available format/product
   range, and required recovery material without writing.
2. Reject unknown newer or unsupported formats before mutation.
3. Persist the migration attempt and source/destination versions in the same
   database controlled by the agent.
4. Apply one deterministic step at a time; do not skip required intermediate
   epochs/revisions.
5. Validate foreign keys, constraints, counts, references, and domain
   invariants before advancing.
6. Update format metadata and terminal migration state in the committing
   transaction.
7. Reopen and run integrity/application checks before serving queries.

Each documented restart boundary is idempotent. If the previous product cannot
read post-migration state, the migration does not claim binary rollback.
Depending on its declaration, it either keeps the old state untouched until a
final commit, preserves a verified pre-migration recovery copy, or requires a
forward repair.

## Durable media intent and attempt lifecycle

The agent records job intent before dispatching worker work. The durable record
contains job ID, unique generation, idempotency key, expected Engine revision,
expected outputs, source authorization, staging reference, and cleanup
responsibility.

Attempt states are:

```text
created -> dispatched -> succeeded
                     \-> cancel_requested -> cancelled
                     \-> failed
                     \-> interrupted

succeeded|cancelled|failed|interrupted -> cleanup_pending -> cleaned
```

`cancel_requested` is the cancellation linearization point. A later success for
that generation is stale and cannot install. Failure records a typed terminal
error. Connection invalidation records interruption, not success or
cancellation. Retry creates a new generation; it does not reopen an old terminal
attempt.

Worker staging remains disposable and untrusted throughout. A terminal result,
cancellation acknowledgement, process exit, or connection invalidation updates
journal facts but does not prove file-descriptor revocation or transfer physical
ownership. The worker never receives access to prepared, published, or
database-visible state.

## Artifact install sequence

A current successful claim proceeds:

```text
intent_recorded -> verifying -> verified -> prepared -> published -> committed
```

1. Confirm job, generation, expected revision, and source authorization still
   match.
2. Accept the terminal result as a claim only; make no assumption that worker
   staging is closed or immutable.
3. Resolve staging candidates relative to open WALI-owned directory descriptors; reject
   absolute paths, `..`, symlinks, nonregular files, and containment escape.
4. The agent exclusively creates a fresh destination in same-volume prepared
   storage. It never grants the worker that path or descriptor.
5. Stream/copy bytes from the untrusted staging descriptor into the fresh
   destination. A clone requires separate platform evidence that it creates an
   independently protected destination; no clone optimization is assumed.
6. Hash SHA-256 and media-validate the destination bytes, not the worker staging
   object. If input began on another filesystem, this same-volume destination is
   still the only publication candidate.
7. Flush each prepared destination and its parent directory before recording
   `prepared`.
8. Publish with a same-volume no-replace rename. If the digest path exists,
   open/hash it and reuse only identical bytes; never overwrite it.
9. Flush a newly published object and its parent directory before recording
   `published`.
10. In one SQLite transaction, create final release references, make the release
   query-visible, and mark the install journal terminal `committed`.

Opening and hashing worker staging, then publishing it directly or trusting it
after a terminal reply is forbidden. Verification binds identity to the fresh
agent-created destination. Later worker writes can affect only disposable
staging, never the prepared publication candidate.

## Compensation and garbage collection

Attempt cleanup is durable and idempotent. Cleanup records account for staging,
abandoned prepared files, and published objects with no committed reference.
Repeated recovery reaches the same result after crashes at any boundary.

Renderer leases protect active artifacts. Lease identity includes release,
artifact digest, holder, and generation; stale generations cannot renew.
Deletion creates a tombstone before removing references or files. GC uses
directory-relative no-follow operations and removes only WALI-owned objects
that have no committed reference, active lease, or live recovery record.

Cleanup never owns or deletes user source media.

## Other surfaces

- Artifact manifests migrate by creating a new immutable release.
- Preferences use explicit versions and deterministic defaults; incompatible
  values are quarantined/reported rather than silently changing intent.
- Wire compatibility is negotiated per channel. Unsupported peers receive a
  stable upgrade error and no mutation.
- URL and catalog input is validated into current model values; external input
  is never rewritten in place.
- Diagnostic exports are immutable; readers do not mutate them.

## Marketplace server migrations

The marketplace server schema starts at epoch 1 revision 0 under accepted ADR
0014. Ordered Supabase migrations are authored and replayed locally, applied to
staging, verified, and only then applied to production. Staging and production
never share project IDs, data, buckets, queues, credentials, signing keys, or
worker service accounts.

Authoritative tables live in the non-exposed `wali` schema. An exposed
`public` table is prohibited. Public views and RPCs must be named in the v1 API
allowlist, use invoker security where possible, and have explicit grants. A
security-definer function fixes `search_path`, schema-qualifies objects, uses no
dynamic SQL, and rechecks the authenticated identity, current role/AAL, state,
generation, revision, idempotency key, and rate limit.

Production database changes are forward-only. A destructive change uses:

```text
expand -> dual-read/write only when specified -> bounded backfill
       -> verify counts/digests/RLS -> switch readers -> contract later
```

Every migration is transaction-safe where PostgreSQL permits, has explicit
lock/statement bounds, preserves immutable release/audit history, and includes
RLS tests for visitor, user A, user B, creator, moderator AAL1/AAL2, admin, and
worker paths. A failed or unknown newer migration never triggers destructive
reset. Restore uses database PITR plus separately digest-verified Storage backup;
database backups do not contain Storage objects.

## Catalog and public API evolution

Catalog manifest and signed revocation bodies begin at epoch 1 revision 0.
Their canonical bytes, ordering, size/count limits, key/signature rules, and
fixtures are defined by `docs/api/catalog-v1.md`. An incompatible canonical
change creates a new epoch and accepted ADR; older clients reject it before
download. Additive revisions are readable only inside declared compatibility
ranges with golden/malformed fixtures.

Public Catalog, Creator, and Moderation APIs use explicit `v1` names. A changed
meaning or removed required field creates a new version. Old and new versions
coexist until supported clients migrate and server evidence proves the old
surface is unused. Internal table shape never becomes a compatibility promise.

Published media and manifests are immutable. Updating media or metadata that
affects the public metadata digest creates a new release edition. Copyright or
policy removal delists without mutating old bytes. Only a trusted signed
critical-security revocation blocks catalog-origin local selection; local
imports remain outside server authority.

The app/agent wire protocol version 2 adds bounded signed catalog install
metadata, cumulative trust transitions, and monotonic revocation updates.
Version 1 peers fail the protocol handshake before catalog state is exchanged;
catalog installs are retried only after both processes run version 2.

Model and taxonomy changes register a new immutable model/taxonomy revision and
write new embeddings/suggestions. They never reinterpret existing rows in
place. Storage paths remain generated content-addressed values; migration or
backup code never constructs paths from a creator filename/title.

## Rollback and fail-closed policy

For each migration, `rollback_readers` in `surfaces.yml` is the complete binary
rollback promise. Every listed product requires an old-reader fixture proving
it can consume post-migration state. No listed reader means no binary rollback
guarantee.

When rollback is not proved, WALI fails closed before an incompatible write or
uses the migration's documented forward repair/recovery copy. Immutable
content-addressed bytes do not by themselves prove that an old binary can read
new manifests, journals, or schemas.

## Test gate

Use copied fixtures and temporary directories only. Tests inject interruption
before and after every durable boundary and cover duplicate/stale replies,
cancellation races, renderer-lease expiry, disk-full/write/fsync failures,
symlink/path escape, worker staging that remains open or changes after reply,
cross-volume input, no-replace collisions, repeated recovery, and idempotent GC.

Compatibility tests cover every readable source pair and every claimed old
reader. Automated tests never open a live user store or Apple wallpaper store.
