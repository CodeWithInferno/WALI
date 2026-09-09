# Security Policy

WALI is pre-alpha. There are no supported release lines yet.

## Reporting a vulnerability

Do not open a public issue for vulnerabilities involving code execution, path traversal, signature validation, cross-process authorization, update integrity, catalog signing, or destructive data loss.

Use GitHub's [private vulnerability reporting form](https://github.com/CodeWithInferno/WALI/security/advisories/new)
when the repository's Security page offers **Report a vulnerability**. The link
alone does not establish that the hosted feature is enabled or monitored. If it
is unavailable, request a private reporting route from the repository owner
without posting exploit details, affected private data, or credentials. No
separate monitored security address or response deadline is currently published
in this policy. Maintainers must verify the route before public publication;
see the [publication checklist](docs/maintainers/publication.md).

In the private report, include:

- affected commit or version;
- macOS version and hardware;
- reproduction steps or proof of concept;
- realistic impact;
- whether user interaction or special permissions are required;
- suggested mitigation, if known.

Do not include personal media, credentials, access tokens, or unrelated user data.

## Security boundaries

- WALI operates in the current user's GUI session.
- It must not patch protected system components, bypass SIP/FileVault, or install behavior into another user account without consent.
- Ordinary wallpaper operation must not require Accessibility, Screen Recording, Full Disk Access, or root.
- Login-item registration and experimental lock-screen integration must be explicit and reversible. Only `WALILockScreenHelper.app` may be eligible for Full Disk Access; `WALI.app`, `WALIAgent.app`, and media/catalog components must not require it.
- IPC peers and remote catalog manifests must be authenticated before their data is trusted.
- Imported files, transcoder outputs, manifests, thumbnails, and catalog metadata are untrusted input.
- No WALI process with Full Disk Access may parse media, perform network requests, load scripts/plugins, open the marketplace database, or accept caller-controlled paths. The helper accepts only the fixed operations and roots in ADR 0013.
- Never grant Full Disk Access to an ad-hoc/unsigned Debug build. Live helper IPC requires both peers to carry exact bundle identifiers and the same non-empty Apple signing Team ID; a credential-free Debug build therefore fails closed and Lock Screen continuity stays unavailable.
- The macOS app contains no Supabase service-role key, database password, catalog signing private key, worker credential, or moderator secret.
- Public catalog artifacts are immutable and content-addressed. Install requires a canonical bounded manifest, trusted detached Ed25519 signature, exact approved host, length/SHA-256 match, sandboxed media inspection, and agent-owned destination-byte verification.
- Authoritative marketplace tables remain in the non-exposed `wali` schema with default grants revoked and RLS enabled. Public views/RPCs are an explicit versioned allowlist.

The marketplace threat model, data inventory, upload limits, and dependency
rules are normative:

- [`docs/security/marketplace-threat-model.md`](docs/security/marketplace-threat-model.md)
- [`docs/security/data-inventory.yml`](docs/security/data-inventory.yml)
- [`docs/security/media-policy.yml`](docs/security/media-policy.yml)
- [`docs/security/dependency-policy.yml`](docs/security/dependency-policy.yml)

Public creator uploads remain disabled until RLS, hostile-media isolation,
signed catalog/key rotation, backup restore, moderation/legal, and signed bundle
gates have all passed. A shared VM kernel is not a hard security boundary for
unrelated production workloads; the hostile-media worker's production target is
a dedicated replaceable VM.

## Safe research

Good-faith testing against your own WALI data and processes is welcome. Do not:

- test against media or accounts you do not own;
- disrupt another person's system;
- publish an exploit before a fix is available;
- extract or redistribute proprietary competitor assets or credentials;
- use WALI research to bypass macOS security controls.

## Automated tests

Security and compatibility tests use temporary directories and sanitized fixtures. They never mutate the user's live Apple wallpaper store or delete source media.

Tests may inject synthetic peer identities and temporary roots explicitly. Those
test seams are not selected by a build configuration and are not reachable from
the shipped helper composition root.

Marketplace fixtures are synthetic and contain no production credentials,
private object URL, user media, rights evidence, or proprietary competitor
asset. Never report a security test as production-safe merely because a checksum,
antivirus scanner, container, or model accepted an input.

## Source scanning

The Security scan workflow retains Trivy checkout scanning and adds pinned
Gitleaks scanning of all history reachable from the CI checkout's refs. It uses
redacted reports and requires no project credential. Dependency review is
enforced on public pull requests where GitHub makes that API available. These
jobs do not certify private reporting, push protection, remote artifacts, or
deleted/unfetched refs. The [scanner runbook](docs/security/secret-scanning.md)
describes exact historical finding reviews and the final publication scan.
