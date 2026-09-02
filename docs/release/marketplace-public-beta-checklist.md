# Marketplace public-beta checklist

Public creator uploads and production deployment remain **off** until every gate
below has linked evidence and an accountable human approval. “Code exists” is
not evidence that an external service or legal requirement is ready.

## Gate A — product and data

- [ ] Native account, Discover, Browse, search, detail, favorite/save, report,
      creator upload, review, install, delist, and revocation canary passes.
- [ ] Schema, public RPC contract, RLS, object policies, rate limits,
      idempotency, retention, and deletion behavior pass in staging.
- [ ] Catalog load report records hardware/region, dataset size, concurrency,
      duration, median, p95, errors, and bottlenecks.

## Gate B — hostile media and platform security

- [ ] Worker runs on a dedicated replaceable VM with rootless Podman, immutable
      image digests, Cosign verification, networkless sandboxes, and resource caps.
- [ ] Hostile corpus, independent verifier, signed manifest, trust transition,
      one-use receipt, destination-byte validation, and critical revocation pass.
- [ ] Only WALILockScreenHelper is eligible for Full Disk Access; its peer,
      operation, import/link, path, and live-store tests pass.
- [ ] Security review has no unresolved exploitable high/critical issue.

## Gate C — recovery and operations

- [ ] Production PITR and staging backup schedule are verified.
- [ ] Independent object mirror and isolated restore pass digest and reference checks.
- [ ] Key rotation, key compromise, malicious release, RLS exposure, worker
      compromise, catalog rollback, account deletion, copyright, and ranking
      exercises have owners and dated evidence.

## Gate D — legal, privacy, and OSS

- [ ] Counsel approves the privacy policy, terms, creator license, content
      guidelines, copyright process, operator entity, jurisdiction, and contacts.
- [ ] Creator Terms acceptance is versioned and enforced before submission.
- [ ] Seed catalog is empty or every item has redistribution evidence and digests.
- [ ] SPDX SBOM, notices, model/FFmpeg provenance, license allowlist, dependency
      review, and secret scan pass for the exact release.

## Gate E — signed Apple release

- [ ] Release archive is built from the reviewed commit with the approved team.
- [ ] Hardened Runtime, entitlements, app groups, helper/XPC nesting, designated
      requirements, `codesign`, `spctl`, notarization, and stapling pass.
- [ ] Three-display Fill/Fit/Stretch/Center, idle CPU/memory, pause/resume,
      app close/reopen, agent restart, repeated lock/unlock, permission removal,
      unsupported-build rollback, and FileVault limitations are recorded.

## Approvals

- [ ] Product owner
- [ ] Security owner
- [ ] Moderation operator
- [ ] Legal reviewer
- [ ] Release operator
