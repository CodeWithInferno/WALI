# 0005: Install content-addressed artifacts through durable journals

- status: accepted
- date: 2026-08-30
- owner_role: storage_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- related: [0003](0003-agent-owned-runtime-state.md), [0004](0004-engine-owned-use-cases.md)

## Context

Import crosses process, filesystem, codec, cancellation, and database failure
boundaries. A SQLite transaction cannot atomically include worker execution or
filesystem publication. A simple “encode, rename, insert row” sequence cannot
distinguish durable intent, stale worker output, verified bytes, publication,
query visibility, and cleanup after interruption.

The worker is untrusted and cannot decide that output is safe or visible.
Cross-filesystem rename is not atomic, and path-based verification followed by a
later path-based move permits time-of-check/time-of-use substitution.

## Decision

Use immutable artifacts addressed by an agent-verified SHA-256 digest. A
library item references an immutable release manifest; it never names mutable
media bytes as authoritative content.

Persist job intent before dispatching worker work. Each job has a unique
`job_id`, monotonically unique `generation`, idempotency key, expected Engine
revision, source authorization, and staging reference. A reply can affect state
only when those identifiers still match the active attempt.

Attempt state is durable and separate from install state:

```text
created -> dispatched -> succeeded
                     \-> cancel_requested -> cancelled
                     \-> failed
                     \-> interrupted

succeeded|cancelled|failed|interrupted -> cleanup_pending -> cleaned
```

`cancel_requested` is a durable linearization point. A success arriving after
that point is stale and can only feed cleanup. Connection invalidation records
`interrupted`; it never implies success or cancellation.

A successful current-generation claim starts the install journal:

```text
intent_recorded -> verifying -> verified -> prepared -> published -> committed
```

State preconditions and postconditions:

- `intent_recorded`: the current attempt, expected outputs, source/staging
  references, and cleanup responsibility are durable before worker output is
  accepted.
- `verifying`: the terminal reply is current, but worker staging remains
  untrusted and may still be open or mutable. No reply, cancellation, or
  connection event is treated as file-descriptor revocation or ownership
  transfer.
- `verified`: the agent has created a fresh same-volume prepared destination
  through an agent-owned directory descriptor, streamed/copied worker output
  into it, and SHA-256 hashed and media-validated the destination bytes. The
  worker never receives a descriptor or path granting access to that
  destination.
- `prepared`: prepared files are on the destination object's volume; each file
  and its containing directory have been flushed, and replayable destination
  metadata is durable.
- `published`: a same-volume no-replace rename has created or reused the digest
  path. An existing path is reused only after opening and verifying identical
  bytes; publication never overwrites it.
- `committed`: one SQLite transaction creates final release references,
  advances the install journal to its terminal state, and makes the release
  query-visible.

Publication is atomic only within the destination filesystem. Input on another
volume is copied into same-volume prepared storage, verified there, flushed,
then published. WALI makes no cross-filesystem atomicity claim.

Use directory-relative operations rooted at already-open WALI-owned directory
descriptors. Reject absolute paths, `..`, symlink traversal, nonregular files,
and containment failure. The agent opens worker staging only as an untrusted
source, creates a different prepared destination with exclusive no-follow
creation, copies or streams bytes into that destination, then hashes and
validates the destination bytes. A clone is permitted only after separate
platform evidence proves independent destination identity and prevents worker
mutation; no clone optimization is assumed by this ADR.

Flush prepared file contents and the prepared parent directory before recording
`prepared`. After no-replace publication, flush the object file when newly
created and the object parent directory before recording `published`.

Worker staging remains disposable and untrusted even after a terminal reply,
cancellation acknowledgement, or connection invalidation and even if the worker
still has it open. Those events change journal state, not physical file
ownership. Only the agent can open/create the fresh prepared destination; the
worker never owns or accesses prepared, published, or database-visible state.

Compensation and garbage collection are idempotent. Durable cleanup records
cover attempt staging, abandoned prepared files, and unreferenced published
objects. Leases protect active renderer reads; tombstones make deletion
replayable. Cleanup never follows untrusted links or deletes user source media.

## Invariants

- Durable intent precedes worker dispatch and output acceptance.
- A `(job_id, generation)` has one active attempt and one terminal result.
- Cancellation, failure, and interruption retain enough state for deterministic
  cleanup and retry with a new generation.
- Only the agent verifies, prepares, publishes, commits, compensates, and
  garbage-collects artifacts.
- Verification hashes and validates bytes in a fresh agent-created prepared
  destination; worker staging is never promoted directly.
- No terminal reply or connection event is assumed to revoke worker descriptors
  or transfer physical ownership.
- Publication is same-volume, no-replace, containment-checked, and durably
  flushed before the journal advances.
- Filesystem publication alone never makes a release query-visible.
- Final release visibility and install-journal completion occur in one SQLite
  transaction.
- Every nonterminal or unreferenced WALI-owned file has a durable recovery or
  cleanup explanation.
- Active leases prevent collection; stale generations cannot renew a lease.
- User source media is never cleanup-owned.

## Alternatives considered

- Mutable asset-ID directories: weakens deduplication and permits partial
  replacement.
- Database transaction plus final rename: cannot atomically cover both systems
  and leaves ambiguous crash windows.
- Cross-volume rename: has no portable atomicity guarantee.
- Hash a path then move that path: vulnerable to substitution between check and
  use.
- Trust worker checksums: lets stale or compromised work define trusted
  identity.
- Store media blobs in SQLite: enlarges transactions and does not remove codec,
  descriptor, or filesystem durability requirements.

## Consequences

Recovery can replay from durable facts, and content identity is independent from
library metadata. Storage requires attempt and install journals, fresh
agent-created prepared files, destination-byte verification, same-volume
preparation, no-replace publication, fsync discipline, leases, tombstones, and
bounded GC.

Temporary disk use may include staging plus a same-volume prepared copy. The UI
must distinguish committed library bytes from recoverable temporary bytes.

## Migration and rollback

No user artifact format has shipped. Hardening Task 8 must implement these
states before storage is exposed as a product capability. Pre-release fixture
media enters through a new durable intent and full verification; no existing
path is renamed directly into trust.

Format epoch and additive revision follow `docs/versioning.md`. Each migration
declares minimum reader/writer product versions. Binary rollback is promised
only when old-reader fixtures prove the previous product can read the resulting
journal, manifest, and schema. Otherwise upgrade fails closed before mutation
or requires a documented forward repair; immutable published objects alone are
not sufficient proof of rollback.

## Verification

- Crash injection before and after every attempt/install transition.
- Cancellation races before dispatch, during worker execution, after success,
  and during cleanup.
- Stale generation, duplicate terminal reply, lease expiry, and retry tests.
- Symlink, path traversal, nonregular source, concurrently mutable/open worker
  staging, digest mismatch, and destination-byte verification tests.
- Tests proving terminal replies and connection invalidation do not authorize
  direct staging publication or imply descriptor revocation.
- Cross-volume input tests proving same-volume preparation rather than atomic
  cross-volume rename claims.
- File and parent-directory fsync fault injection.
- Existing-object no-replace and identical-byte reuse tests.
- Query tests proving releases remain invisible until the final SQLite
  transaction and the install journal becomes terminal in that transaction.
- Repeated compensation/GC tests proving active leases survive and failed work
  leaves no permanent orphan.
