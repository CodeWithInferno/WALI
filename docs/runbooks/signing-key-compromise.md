# Signing-key compromise

**Severity:** critical
**Owner:** security responder

**Readiness gate:** this is the required production procedure, not evidence
that a recovery key or signing boundary is deployed. Do not enable publishing
until an independent recovery path, hosted revocation retry, and staging client
exercise have been recorded.

## Immediate containment

1. Disable all publish/sign operations and isolate the signing boundary.
2. Preserve access logs and key-generation evidence; do not copy suspected
   private-key material into a ticket or chat.
3. Publish a higher-revision critical revocation signed by an independent
   surviving recovery key, revoking the affected key from the earliest credible
   compromise time.
4. Block new installs for every potentially affected release. Do not remotely
   delete files already in a user's library.
5. Compare signed manifests, transparency/audit records, database releases, and
   immutable object digests to enumerate unauthorized signatures.

## Recovery

Generate a new key in a clean boundary, ship a signed trust transition from a
surviving key, rebuild affected releases from verified immutable artifacts, and
exercise staging install/revocation before reopening publishing. If no recovery
key survives, ship a normal signed application update with a new compiled trust
root; never download an unsigned replacement root.

Exit only after scope is bounded, malicious releases are blocked, clean keys
and operators are established, client behavior is verified, and an incident
review records root cause and follow-up controls.
