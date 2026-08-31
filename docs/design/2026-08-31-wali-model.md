# WALI Model Contract

**Status:** Implemented architecture-hardening Task 4, 2026-08-31  
**Scope:** Foundation-free immutable values and pure reducers in `WALIModel`

## Chosen hybrid

WALIModel combines stable public immutable records with package-scoped pure
reducers. Records are public because Engine, wire translation, runtimes, and UI
presentation need the same values. Mutation authority is not public: playback
and import transitions enter through package-scoped reducers so WALIEngine can
apply policy without turning WALIModel into an orchestration layer.

The module imports nothing. In particular it has no Foundation, UUID, Date,
URL, Data, path, actor, async, Apple-framework, repository, transport, or
process types. Callers generate IDs, revisions, and time outside the model and
submit validated values. There are no public protocols or classes.

Every independently encoded aggregate root carries
`RecordSchemaVersion(epoch:revision:)`. The only supported model schema is
`1.0`; epoch zero is invalid and aggregate decoding rejects every unsupported
pair. The roots inventoried for compatibility are `Artifact`, `AssetRelease`,
`LibraryItem`, `DisplayRecord`, `DeviceLocalPresentationAssignment`,
`PlaybackState`, `DurableJob`, and `ImportJob`.

`Codable` defines stable logical keys and tags. It does not define canonical
bytes, framing, signatures, hashing input, persistence encoding, or an IPC
security boundary. Semantic sets are held in canonical order before encoding;
set decoders that cannot safely collapse duplicates reject duplicate encoded
elements.

## Values and validation

- Asset, release, variant, library-item, installation, local-display,
  assignment, job, and idempotency identities are distinct types. Each contains
  exactly one canonical lowercase UUID-shaped string; no generic stable-ID
  erasure is public.
- `ContentDigest` pairs the closed `sha256` algorithm tag with exactly 64
  lowercase hexadecimal digits.
- Renderer, media-type, artifact-role, job-kind, display-alias-kind, and
  automatic-pause-reason identifiers are inert open tags. Their grammar is at
  most 64 UTF-8 bytes, begins and ends with a lowercase ASCII letter or digit,
  contains a namespace dot, and otherwise permits lowercase ASCII letters,
  digits, dots, and hyphens. Unknown valid tags round trip but never load code.
- Display fingerprints are validated normalized lowercase ASCII, bounded to
  128 bytes, and permit letters, digits, dot, underscore, colon, and hyphen.
- User text is nonblank and UTF-8 bounded. Media sizes, byte counts,
  generations, duration/frame-rate rationals, bit depth, and fixed-point
  coordinates reject invalid ranges.
- `ModelViolation` carries a stable code plus field, operation, supplied
  generation, and expected generation. Localized prose belongs to a
  presentation adapter.

## Asset, release, and library records

An `Artifact` contains schema, SHA-256 content identity, positive byte count,
inert media type, and exact integer/rational characteristics. It deliberately
contains no path, trust bit, availability bit, worker claim, or framework media
type.

An `AssetRelease` is an immutable positive edition. Artifacts and variants are
canonical semantic sets. Construction and decoding reject duplicate content
identities, conflicting metadata for one digest, a missing poster, duplicate
variant identities, dangling bindings, duplicate roles within a variant, and a
missing default variant. Renderer requirements and binding roles remain inert,
so a release does not define plugins or capability protocols.

A `LibraryItem` is an immutable named snapshot pinned to an `AssetReleaseID`.
The initial closed origins are local import and bundled. Rename returns a
replacement value with the same item and release identities.

## Locality and future sync eligibility

No sync behavior, flags, transport, account, or conflict policy is implemented.
The following classifications constrain a future design:

- Asset identity, immutable release metadata, artifact metadata, and library
  metadata are structurally eligible for a future sync proposal after trust,
  authorization, conflict, and compatibility policy is approved.
- `DisplayIdentity` is explicitly installation-local through
  `(DeviceInstallationID, LocalDisplayID)`. `DisplayRecord`,
  `DeviceLocalPresentationAssignment`, playback state, import jobs,
  idempotency keys, revisions, generations, cancellation markers, and attempt
  history remain device-local.
- An assignment pins a release directly. It does not refer to `LibraryItem` and
  carries no sync flag, so deleting or renaming library presentation cannot
  silently retarget a display.
- Display aliases are stored evidence only. Match confidence belongs to a
  computed `DisplayMatchCandidate`; tentative and ambiguous matching policy is
  deferred to reconciliation.

## Trust distinction

Content identity is not proof that bytes were independently verified.
`Artifact` is immutable descriptive metadata. `ImportAttempt.succeeded` means
only that worker work ended successfully; no artifact, claim, path, or trust
assertion enters the job reducer. Only a later agent-owned verifier and install
journal may establish trusted bytes. `ImportResult` records library-item and
release IDs only after installation commits.

The artifact manifest, content store, SQLite schema, wire channels, and storage
journal remain unimplemented in the compatibility inventory.

## Playback reducer

Playback keeps desired running, user pause, a canonical automatic-reason set,
selected quality, active prepared playback, replacement preparation, and
current-generation failure as orthogonal axes.

| Input | Required state | Result |
| --- | --- | --- |
| begin replacement | generation 1, or exactly latest + 1; no pending replacement | requested replacement; current failure clears |
| preparation started | matching requested generation | preparing replacement |
| preparation ready | matching preparing generation | ready replacement; active playback is unchanged |
| commit replacement | matching ready generation | prepared replacement becomes active |
| preparation failed | matching replacement generation | replacement clears; failure is blocking only when no active playback exists |
| set desired running | any | updates only desired-running axis |
| set user pause | any | updates only user-pause axis |
| set automatic reason | any | inserts/removes one reason without disturbing other axes |

Exact represented repeats return `duplicate`. Older asynchronous callbacks
return `stale`. Future callbacks throw; replacement starts with a generation
gap also throw. Unknown valid automatic reasons conservatively pause.

Effective mode precedence is: stopped; blocking failure; no active playback is
preparing; user paused; any automatic reason; playing. Replacement status is
reported separately, so replacement preparation or replacement-only failure
does not hide an available active wallpaper.

## Durable import reducer

`DurableJob` is a concrete header, not a generic payload/result container.
`ImportJob` combines that header with ordered attempts and an optional committed
ID-only result.

| Input | Required state | Result |
| --- | --- | --- |
| begin attempt | nonterminal, uncancelled, no attempt or prior terminal/cleaned attempt | reducer allocates generation 1 or previous + 1 |
| mark dispatched | matching created attempt | dispatched |
| request cancellation | nonterminal job | persists accepted revision and terminal cancelled outcome; active attempt becomes cancellation requested |
| finish attempt | matching current nonterminal attempt | retains succeeded/cancelled/failed/interrupted outcome |
| installation committed | current successful attempt, no cancellation | writes committed result and terminal job success |
| begin/finish cleanup | attempt has retained terminal outcome | cleanup pending/cleaned while retaining that outcome |
| fail permanently | nonterminal job | writes terminal job failure |
| recover after crash | current created/dispatched/cancellation-requested attempt | records interrupted, never inferred cancelled or succeeded |

Persisting `cancellationRequested` and `CancellationMarker` is the cancellation
linearization point. Any later success is
`completionAfterCancellationCleanupOnly` and can never install. A completion
for an older generation is `staleCompletionCleanupOnly`; a future generation
throws. Exact terminal duplicates are idempotent, conflicting current terminal
outcomes throw, and a terminal job never reopens or changes outcome. Worker
success is not job success; only `installationCommitted` succeeds the job.

## Deferred concepts

- Engine command ordering, orchestration, repository seams, persistence, and
  actor ownership
- wire envelopes, payload bounds, IPC authentication, XPC, and message
  compatibility
- filesystem staging, independent byte verification, manifests, publication,
  install journals, SQLite, leases, tombstones, and garbage collection
- import progress and worker artifact claims
- display reconciliation and tentative/ambiguous match policy
- renderer implementations, plugin loading, capability negotiation, and Apple
  media/framework behavior
- sync transport, account identity, conflicts, remote catalogs, and lock-screen
  behavior
