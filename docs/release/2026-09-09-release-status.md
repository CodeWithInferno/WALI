# Release preparation — 9 September 2026

This ledger separates completed source/deployment work from release acceptance.
It must not be used as a claim that a signed binary or Store submission exists.

## Source and verification

- Branding/installer implementation: commit `6723f24a706931a4177c480bed0ee7914f2efb21`, [PR 25](https://github.com/CodeWithInferno/WALI/pull/25).
- That commit passed local `make verify` and the hosted contracts, Swift, backend and media jobs. Security CI found the existing Rubyzip 2.4.1 vulnerability.
- Remediation pins official Fastlane source with Rubyzip 3.6.0, accounts for all seven resolved Swift packages, and distributes exact pinned license notices. The expanded inventory contains 58 entries, including the Fastlane Git revision.
- Release tooling now binds source, app and package digests, verifies final CI and tag targets, and verifies GitHub upload digests before publication. Credential-free regression fixtures and Fastlane loading passed. Actual signing, notary and publication execution remain pending.
- The remediation passed a fresh `make verify`: 161 architecture fixtures, 23 bundle fixtures, 18 signature fixtures, eight dependency regressions, four DMG metadata tests, release provenance regressions, package/native tests and coverage, fresh Debug build, bundled notices and final branding verification. Follow-up receipt/remote-upload tamper regressions also passed.
- Final PR head `c7e7b37d88272fc152427a92ba69f6bf0a9f9a6e` passed source, contracts, Swift, backend, and media checks. PR 25 merged at 22:24 UTC as `998bfc09b795ee2c7bfa9d269cf32b2ad445afd8`. Primary main was fast-forwarded without deleting untracked output. The merge-commit checks are a separate publication requirement. The first main run failed one carousel test because its 30 ms sleep expired while the model was still loading; contracts, backend, media and security passed. The correction reproduced that failure with a 75 ms scripted response, then passed 15 focused repetitions and all 20 coordinator tests. [PR 26](https://github.com/CodeWithInferno/WALI/pull/26) passed all five applicable checks and the owner merged it as `e390281cd1661945a8118713ac929b246ef0cb59` at 22:57 UTC. Primary main was fast-forwarded; the new merge commit passed Marketplace CI and the security scan.

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
evidence and the full native production journey. Google Cloud authentication was restored for the WALI project; the existing
worker is explicitly staging and has not been repurposed. Public creator
activation is not complete. No staging key or synthetic account was promoted to production.

## Apple distribution

Developer ID Application is installed for the selected owner team. The actual
Fastlane archive attempt failed because production provisioning profiles were
missing for the foreground app, agent and Lock Screen helper. The Apple account
has been identified; secure user authentication is pending. A subsequent Fastlane
automatic-provisioning probe reported `No Accounts` and a wildcard profile
without Sign in with Apple; it did not produce an archive. Passwords, two-factor
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

The Store source merged in [PR 27](https://github.com/CodeWithInferno/WALI/pull/27)
at 23:38 UTC as `d1cfb0ddacfe188fa95a4d2c371f0f836e1f368b`. All six
applicable checks passed on head `9fb9094ce9e382e527d1c2523e7252ee1d999d5c`.
Primary main was fast-forwarded and retained the existing branding output.
The merge-commit checks are a separate publication requirement.

The isolated Store implementation now has a helper-free structural build,
explicit Store graphs/settings, template-only menu identity, unchanged direct
helper-wire compatibility, and deterministic signature/profile/package gates.
Final integrated Store hostless tests passed 145 cases. StoreDevelopment and
optimized AppStore structural artifacts also passed; every AppStore executable
contains arm64 and x86_64 slices with minimum macOS 15.0. The full direct
`make verify` passed 161 architecture fixtures, 89 package tests and 176 native
tests, with coverage, bundle, license and branding checks. Both Store release
configurations exclude LLVM coverage instrumentation, and the affected Debug
build/bundle were rechecked after that build-setting change. Persistent CI now
runs both Store structural builds and hostless Store suites; release lanes
require that Store job alongside the five existing checks. None of these results
establishes a signed sandbox journey or Store submission. The new Fastlane
upload/submission path has passed 51 credential-free refusal fixtures. Actual credentialed execution
remains separate evidence. Creator
blocking remains the proposed [ADR 0019](../adr/0019-private-creator-blocking.md).


## Public release, source cleanup and media-quality follow-up

The owner additionally requested public downloads, an open-source cleanup and
an actual app demonstration. Credential/personalization and history review is
in progress before changing repository visibility. Neither a public repository
nor a public downloadable release has been established by that request alone.

The requested batch contains 24 original MP4s totaling 1,098,137,015 bytes. A
local baseline records SHA-256, dimensions, frame rate, codec, color metadata,
audio and duration without modifying the originals. Public redistribution
license/attribution remains unresolved. Production upload and downloaded-output
quality comparisons have not run. The comparison must cover the published
`video_default` and the file the native player uses; the lower-resolution
preview is a separate output. Record actual production paths before filming
or presenting the demo as release evidence.

The OSS preparation includes a pinned Gitleaks history job, contributor and
maintainer guidance, narrow local-secret/evidence ignores, and corrected public
repository links. The reviewed full remote-history scan found only the two
historical fixture locations repeated in two commits. All 48 hosted build-record
artifacts were expanded and scanned; their alerts matched Python's public GPG
verification fingerprint. No privileged secret was confirmed in those inputs.
Unfetched/deleted refs, all historical Actions logs, private ignored files and
future artifacts are outside that result; repository visibility is unchanged.

A production base-host packet passed 17 offline safety tests and a read-only
cloud preflight. Infrastructure creation awaits explicit owner approval; no new
cloud resources, credentials or worker services were installed. The video
comparison harness passed 14 tests and reverified all 24 original hashes; no
production downloads or visual-quality assessment have occurred. The public
app recording remains dependent on the intended production journey and media
rights, rather than a fixture or edited simulation.


The cleanup adds a manual [GitHub Actions release workflow](github-actions.md)
that uses the existing Fastlane lanes and binds candidate transport, native-review
approval, notarization and publication to the same source and app digest. Its
12 credential-free tests passed 138 assertions, including credential cleanup
and refusal cases; independent source review found no remaining concrete
blocker. Hosted environments, signing material and an actual run remain pending.

The media image now packages complete pinned FFmpeg/Kvazaar source archives,
full upstream licenses, the existing accepted LGPL patch, and the exact explicit
rebuild inputs. Seven refusal fixtures passed; both upstream archives and their
license bytes were checked. CI verifies all 16 compliance files in the actual
immutable image before running the hostile-media corpus. Compiler, codec and
runtime controls are unchanged. No production image was built or published
while preparing this change.
