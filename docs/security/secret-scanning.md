# Secret scanning

The Security scan workflow uses the official
[Gitleaks 8.30.1 release](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1)
CLI with the Linux x64 archive SHA-256
`551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`.
The release checksum list and downloaded archive were independently matched
when this pin was added. Updates must review the upstream release and new
archive hash together; do not replace it with a mutable `latest` download.

## Local and CI use

Install a verified 8.30.1 binary for your platform, then run:

```sh
GITLEAKS_BIN=/path/to/verified/gitleaks ./scripts/check-secrets.sh
```

The wrapper rejects shallow clones, preserves the default detector rules,
scans all history reachable from locally fetched refs, disables inline
`gitleaks:allow` comments, and writes a fully redacted JSON report under
`.build/security/`. It exits nonzero for findings and scanner errors. It does
not contact providers to validate suspected tokens. Tests use a temporary Git
repository and a generated synthetic token to verify detection after deletion,
inline-comment refusal, redaction, and shallow-history refusal.

CI fetches full branch/tag history plus the event ref through checkout. It does
not acquire every hidden/deleted remote ref or inspect hosted Actions/release
artifacts. Before a visibility change, maintainers must separately review the
exact refs and artifacts being exposed; a green checkout scan is not that audit.
Keep raw findings private. Never upload authentication screenshots, unredacted
reports, or private export files as public workflow artifacts.

The existing Trivy checkout scan and public-PR dependency review remain active.
This history scan complements them; no hosted push protection or private
reporting state is implied. See the [publication checklist](../maintainers/publication.md).

## Reviewed historical findings

`.gitleaksignore` contains only four exact commit/file/rule/line fingerprints,
reviewed on 2026-09-09. Two old commits contain the same two false positives:

| Commits | Historical location | Classification |
| --- | --- | --- |
| `140270db19cc02a072ff64c1d9157307d4581413`, `2611e67839d3e24f48686c60fa05522d813e49d0` | `Tests/WALILockScreenHelperTests/LockScreenHelperTests.swift:147` | Static UUID used as an idempotency identifier in `validActivationObject()`, not an authentication credential. |
| Same two commits | `Tests/WALIAgentTests/CatalogInstallTests.swift:353` | `Curve25519.Signing.PrivateKey` type declaration. The fixture initializer generates an ephemeral key; no private-key bytes are embedded in the declaration. |

These records do not exempt a path, detector rule, token pattern, entire commit,
or new occurrence. For any new alert, inspect source and usage privately first.
A real exposed credential requires revocation/rotation and a separately approved
cleanup/disclosure plan. A false positive requires a precise fingerprint and a
reviewed explanation; do not add a blanket path/rule allowlist or baseline all
current findings. Keep the default detector rules enabled.

Detector coverage has limits, including unsupported encodings, ignored upstream
patterns and files outside the fetched Git history. A clean scan is evidence
about that input and pinned tool, not certification that no secret exists.

References: [Gitleaks CLI and ignore semantics](https://github.com/gitleaks/gitleaks/blob/v8.30.1/README.md),
[checkout history settings](https://github.com/actions/checkout/blob/v4/README.md).
