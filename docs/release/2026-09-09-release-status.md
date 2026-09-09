# Release preparation — 9 September 2026

This ledger separates completed source/deployment work from release acceptance.
It must not be used as a claim that a signed binary or Store submission exists.

## Source and verification

- Branding/installer implementation: commit `6723f24a706931a4177c480bed0ee7914f2efb21`, [PR 25](https://github.com/CodeWithInferno/WALI/pull/25).
- That commit passed local `make verify` and the hosted contracts, Swift, backend and media jobs. Security CI found the existing Rubyzip 2.4.1 vulnerability.
- Remediation pins official Fastlane source with Rubyzip 3.6.0, accounts for all seven resolved Swift packages, and distributes exact pinned license notices. The expanded inventory contains 58 entries, including the Fastlane Git revision.
- Release tooling now binds source, app and package digests, verifies final CI and tag targets, and verifies GitHub upload digests before publication. Credential-free regression fixtures and Fastlane loading passed. Actual signing, notary and publication execution remain pending.
- The remediation passed a fresh `make verify`: 161 architecture fixtures, 23 bundle fixtures, 18 signature fixtures, eight dependency regressions, four DMG metadata tests, release provenance regressions, package/native tests and coverage, fresh Debug build, bundled notices and final branding verification. Follow-up receipt/remote-upload tamper regressions also passed.
- Final commit, hosted checks, and merge: pending completion of the release-preparation patch.

## Production deployment

The separately identified `wali-production` project was initially empty. The
root checkout remains linked to staging. An isolated snapshot of reviewed SQL
and Edge source was used for production, with synthetic seeds removed and seed
execution disabled.

Verified after deployment:

| Item | Result |
|---|---|
| Migration ledger | 27 migrations, head `202609040011` |
| WALI tables | 57; row security enabled on all 57 |
| Public WALI functions | 26 |
| Buckets | `catalog-public` public; uploads, processing, moderation and exports private |
| Scheduled jobs | Six present and active |
| Edge Functions | All 14 deployed and active |
| Protected Edge entry points | All 13 returned HTTP 401 `authentication_required` for valid request envelopes without credentials |
| Public security-state endpoint | HTTP 503 `temporarily_unavailable`, consistent with missing trust/revocation initialization |

These checks inspect schema/configuration and rejection paths; they do not prove
authenticated journeys, policy correctness, restore readiness, or worker
completion. Metadata/probe receipts are retained locally outside the repository.
No customer content or identity rows were queried for this verification.

Still pending: hosted Apple provider/audience configuration (read attempt
returned HTTP 403), production trust anchors and signed revocations, isolated
worker deployment, operator roles, effective legal documents, backup/restore
evidence and the full native production journey. Public creator activation is
not complete. No staging key or synthetic account was promoted to production.

## Apple distribution

Developer ID Application is installed for the selected owner team. The actual
Fastlane archive attempt failed because production provisioning profiles were
missing for the foreground app, agent and Lock Screen helper. The Apple account
has been identified; secure user authentication is pending. Passwords, two-factor
codes, Apple sessions and private signing material must remain outside source
and release assets.

No notarization, signed GitHub release, or App Store request has been submitted.
Final release notes must describe the actual candidate, effective support/privacy
destinations, verified platform compatibility, signing/notary evidence and known
limitations. The publication lane includes installation packages, checksums,
license texts, notices, SPDX inventory and source/package provenance.

## Store variant

The owner explicitly approved [ADR 0018](../adr/0018-sandboxed-mac-app-store-distribution.md)
on 9 September 2026. The [implementation plan](../plans/2026-09-09-mac-app-store-distribution.md)
retains desktop wallpaper and marketplace scope, uses separate sandboxed Store
identities/data, and excludes private Lock Screen integration. Approval permits
implementation; signed sandbox feasibility and Store acceptance remain pending.

The [initial review](app-store-review-2026-09-09.md),
[metadata draft](app-store-metadata-draft.md), and
[marketplace readiness plan](../plans/marketplace-store-readiness.md) preserve the
remaining findings. Actual legal owner/contact/public website and the production
account/deletion/moderation paths are still required before submission.
