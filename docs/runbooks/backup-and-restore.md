# Marketplace backup and restore

**Owner:** database operator
**Approver:** security responder
**Scope:** Supabase Postgres, immutable catalog objects, retained private rights evidence

**Implementation status:** external release gate. No provider PITR, cold object
mirror, production archive adapter, backup attestation key, or completed
isolated restore is claimed. The running worker's `wali_backup_verification`
queue re-hashes live public catalog objects only; it is integrity monitoring,
not a backup. A provider-neutral archive runner and the restore verifier have
local tests/scaffolding but are not wired into an executable production job.

## Objectives

- Production Postgres must use provider PITR once the plan is enabled and verified.
- Staging must have a scheduled logical backup independent of the running database.
- Immutable objects must be mirrored to a separately credentialed, versioned cold
  bucket. The application cannot read that bucket.
- A backup is healthy only after an isolated restore proves referential and
  digest integrity.

Record the target RPO/RTO, provider backup identifier, database migration head,
object-manifest digest, and signing-key generation. Never include a signing
private key, service-role token, or raw rights evidence in evidence logs.

## Backup procedure

1. Confirm the environment and change ticket; production and staging credentials
   must never share a shell environment.
2. Verify PITR status and the latest restorable timestamp in the provider
   control plane. Export schema/config separately from data.
3. Wire and review a production adapter around the local WALI maintenance
   archive runner, then run it with read-only database credentials and
   write-only credentials scoped to the cold prefix for this backup ID. The
   repository does not currently provide an executable provider adapter.
4. The job inventories every referenced immutable catalog object and retained
   private object, streams bytes to the cold store, and verifies SHA-256 and
   length at both ends.
5. After a backup attestation boundary exists, sign the resulting manifest with
   that key, not the catalog signing key. Store the manifest outside the source
   project.

## Restore drill

1. Create a new isolated Supabase project and empty restore bucket. It must not
   serve application traffic and must use fresh credentials.
2. Restore the selected database point, then restore objects by digest into the
   isolated bucket.
3. Run `scripts/verify-restore.sh` with the isolated database URL and SHA-256
   checksum manifest. The current script is read-only but does not authenticate
   a manifest signature.
4. The current script verifies restored file checksums, current-release
   linkage, stored manifest digests and signature length, required artifact
   cardinality/path shape, and revocation release references. Separately verify
   general counts/foreign keys, cryptographic catalog signatures, every
   database-to-object digest/length binding, legal-document versions, and the
   migration head until those checks are added to the script.
5. Test a sample manifest with a public key only. Do not load a production
   signing private key into the drill.
6. Destroy the isolated credentials and project after evidence retention is
   approved.

## Exit criteria

This gate is currently open. It closes only when the newest backup meets RPO,
restore time meets RTO, no referenced object is missing or corrupt, all
integrity queries return zero violations, and evidence is reviewed by a second
operator. Otherwise declare the backup unhealthy and open an incident; do not
delete the last known-good set.
