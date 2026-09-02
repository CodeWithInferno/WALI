# 0012: Publish immutable signed remote catalog releases

- status: accepted
- date: 2026-09-01
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01

## Context

HTTPS authenticates a connection, not an artifact's durable identity or the
catalog authority that approved it. A compromised cache, database row, object,
redirect, or stale client response must not turn arbitrary remote bytes into a
local wallpaper release.

## Decision

Every published edition is immutable and content-addressed. Publication emits
the epoch-1 catalog manifest defined in `docs/api/catalog-v1.md` and signs its
exact canonical UTF-8 bytes with Ed25519. Signature bytes are detached from the
body. The body fixes its key ID, logical wallpaper and release IDs, edition,
issue time, ordered artifact claims, and public metadata digest.

`WALICatalog` performs strict bounded decoding, trusted-key lookup, signature
verification, host allowlisting, role/cardinality checks, and digest/length
verification before a catalog release can cross into local install. The agent
then applies the existing destination-byte and content-store verification
rules; neither catalog verification nor TLS replaces local publication checks.

Online key rotation uses a cumulative monotonic trust-transition document
signed directly by an active compiled primary or recovery anchor. The
application and agent ship the bounded anchor set, independently verify and
persist each accepted transition, and reject rollback or equal-revision
equivocation. Signed revocation batches may
block a catalog-origin release only for `critical_security`,
`corrupt_artifact`, or `signing_compromise`. Copyright and ordinary policy
removal delist the catalog entry but do not silently delete local user media.

## Invariants

- Published artifact paths include a lowercase SHA-256 digest and are never
  overwritten or upserted.
- Manifest bytes are canonical before signing; parse-and-reserialize output is
  not substituted for the signed input.
- Unknown epochs, duplicate keys, non-canonical bytes, unknown fields,
  floating-point values, excessive bounds, invalid role sets, and unapproved
  URLs fail before download or install.
- Each manifest has exactly one `thumbnail`, `poster`, `preview`, and
  `video_default` artifact and at most one supported optional video variant.
- URLs are HTTPS, use an injected exact-host allowlist, and contain no userinfo,
  query, fragment, token, or redirect authority.
- A key outside its validity interval, revoked key, invalid signature, byte
  length mismatch, or digest mismatch is a terminal trust failure.
- Manifests contain no access token, private object URL, filename, script,
  shader, plug-in identifier, or dynamic instruction.
- Revocations affect only catalog-origin releases; local imports are outside
  remote catalog authority.
- Persisted catalog provenance is decoded only from canonical metadata bytes
  whose exact SHA-256 is bound by the signed manifest; mutable browse/detail
  projections never cross the install trust boundary.

## Alternatives considered

- TLS-only delivery cannot identify immutable bytes after download and makes a
  database or CDN compromise sufficient to replace content.
- Signing mutable database JSON after clients parse it leaves canonicalization
  ambiguity and replay behavior underspecified.
- Expiring signed object URLs are useful for authorization but are unsuitable
  as durable artifact identity and would prevent stable offline verification.
- Remotely deleting every delisted local item grants broader control than the
  security requirement and conflates copyright workflow with malware response.

## Consequences

Release publication and client install gain explicit cryptographic and format
gates. Key custody, rotation, compromise response, canonical fixture generation,
and clock validity become operational responsibilities. Metadata or media edits
require a new edition rather than mutating an old release.

## Migration and rollback

Existing local imports retain origin `local_import` and require no migration.
Catalog-origin records pin the release ID, edition, manifest digest, and
artifact digests. A newer additive revision may be read only after its declared
range and fixtures land. A new epoch needs an accepted ADR and is rejected by
older clients. Rollback can stop issuing manifests or disable network catalog
access without invalidating already verified, unrevoked local releases.

## Verification

- `Fixtures/Catalog/manifest-v1.json` and its detached signature form the
  epoch-1 golden vector.
- Invalid fixtures cover duplicate keys, excessive counts, and an unapproved
  host; mutation tests cover signature, ordering, role, length, digest, key,
  timestamp, and unknown-epoch failures.
- Compatibility inventory fixes the manifest and revocation epoch/revision,
  fixture paths, canonicalization policy, signature algorithm, and trust owner.
- End-to-end tests prove tampered or stale manifests never reach agent install.
