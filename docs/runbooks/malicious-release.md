# Malicious catalog release

**Severity:** critical
**Owner:** security responder with moderation operator

**Readiness gate:** the local signed-revocation and client-verification
primitives are not a deployed incident capability. Before relying on step 2,
prove the production signing/recovery boundary, security-response grants,
hosted retry path, and supported-client behavior. Until then, freeze publishing
and installs, delist where possible, preserve evidence, and escalate through the
operator recovery plan.

Trigger on a hostile canonical artifact, manifest mismatch, sandbox escape,
malicious metadata, or a release published without valid rights/approval.

1. Disable installs and publishing for the release; preserve immutable bytes,
   moderation/audit rows, job claims, and signing evidence.
2. If clients can still trust the release, publish a signed critical release
   revocation. Delisting alone is not a security revocation.
3. Suspend the involved creator/operator grants without deleting evidence.
4. Determine whether the artifact was raw, canonical, signed, downloaded, or
   installed. Check worker, verifier, agent destination-byte validation, and
   offline libraries independently.
5. Rotate credentials or signing keys only when the evidence supports exposure;
   broad rotation must not destroy forensic context.
6. Build a clean replacement as a new immutable release ID. Never mutate the
   compromised release or reuse its manifest digest.

Communicate impact without naming users or exposing the malicious payload.
Exit after new installs fail closed, affected keys/releases are revoked,
replacement and rollback are tested, and prevention tests are merged.
