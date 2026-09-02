# Catalog rollback

**Owner:** marketplace operator
**Approver:** security responder for critical rollback

**Readiness gate:** this procedure depends on provider restore points, an
immutable object mirror, production signing/recovery keys, and a tested hosted
catalog. Those inputs are not currently deployed or proven. Local verifier and
server contracts are preparation, not rollback evidence.

Catalog rows and releases are immutable. Rollback changes which release is
current or installable; it never overwrites signed bytes.

1. Freeze publishing and identify the last known-good database restore point,
   catalog snapshot revision, signing-key set, release IDs, and object manifest.
2. For a bad item, delist or revoke the specific release and repoint only
   through the audited state transition to a separately verified prior release.
3. For broad corruption, restore the control plane into isolation first and run
   the restore verifier. Compare against the immutable object mirror before any
   production change.
4. Publish a monotonic catalog/revocation revision. Clients must never accept a
   lower revision merely because its timestamp is newer.
5. Verify home, search, detail, request-install, signature validation, offline
   playback, and delisted/revoked behavior using synthetic and known-good items.

Exit after all public API surfaces agree on the same current release, missing or
malicious releases cannot install, clients retain safe offline files, and the
forward fix and restore point are recorded.
