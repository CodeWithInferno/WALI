# Maintainer publication checklist

Source visibility, a signed direct download, a Store submission, and live
marketplace activation are separate decisions. This checklist prepares review;
it does not approve legal terms, confer media rights, or change hosted settings.
The repository owner authorizes publication under [governance](../../GOVERNANCE.md).

## Contributor readiness

- Keep [CONTRIBUTING](../../CONTRIBUTING.md) usable without an Apple account or
  upstream credentials. Credential-free checks must work for fork pull requests.
- Review the exact proposed commit and all applicable CI results. Store changes
  also require the Store CI job once that graph has merged.
- Verify DCO sign-off and third-party notices. Do not assert a hosted DCO bot or
  review rule exists merely because the policy requests it.
- Provide a monitored private vulnerability route and a separate private conduct
  contact. Verify GitHub private reporting from a non-maintainer account before
  linking it as available. Do not invent an email address or a response SLA.

## Before making source public

- Confirm explicit redistribution terms for branding and derived image assets.
  [NOTICE](../../NOTICE) and [ADR 0007](../adr/0007-apache-2-licensing.md) do not
  automatically license wallpaper, video, image, or audio content. Do not infer
  rights from an owner-supplied file or a successful media scan.
- Review tracked files, reachable history, commit identity metadata, hosted PR
  refs, Actions logs/artifacts, and release attachments intended for exposure.
  Follow the [secret-scanning runbook](../security/secret-scanning.md). Routine
  documentation cleanup does not erase a path from history. Any rewrite needs a
  separate coordinated decision; revoke an actually exposed credential first.
- Keep authentication screenshots, private exports, upload manifests, source
  media, and raw evidence outside release attachments. Ignore rules are a guard
  against accidental additions, not a check on already tracked material.
- Verify hosted private reporting, secret scanning/push protection, dependency
  review, branch protection, and required checks as applicable. Record actual
  settings and date; repository YAML cannot establish those hosted facts.

## Before distributing a product

- Use the [Fastlane runbook](../release/fastlane.md) and applicable release gates.
  Keep signed artifact, source commit, checksums, provenance, and native journey
  evidence together. Structural builds do not prove signed behavior.
- Resolve the canonical public legal destination and anonymously check every
  app-linked document. Current configuration and historical namespaces can refer
  to different repository owners; redirects are not legal approval.
- Confirm the legal operator, contact routes, content rights, privacy disclosures,
  moderation and account-deletion readiness. Source visibility does not enable
  public uploads or close marketplace/App Store gates.
- Review image and model redistribution evidence separately from source code.
  Reconcile the dependency policy's older FFmpeg "unmodified" description with
  the documented in-tree patch through the policy owner; retain patch notices,
  corresponding source and image SBOM evidence before distributing that image.
- Add exact signed download/checksum links, supported macOS/edition limitations,
  first-use/quit/uninstall guidance, and a demonstration made with rights-cleared
  media after the corresponding release exists. Never label an ad-hoc local DMG
  as notarized or imply Apple approval from a source build.

Record unresolved decisions with the responsible role and required evidence in
the release ledger. Do not replace a missing operator, private contact, rights
grant, or production result with a plausible example.
