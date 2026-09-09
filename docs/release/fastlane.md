# Native macOS release workflow

WALI currently targets Developer ID distribution outside the Mac App Store.
The native runtime is not sandboxed. App Store eligibility is a separate final
review; a successful archive or notarization is not App Store approval.

Use Ruby 3.3 or newer and Bundler. `Gemfile.lock` pins fastlane and its tools.

Fastlane is pinned to official upstream commit
`3a4fc36716dec206b3f5441f19f0a5193733c828` ([PR #30176](https://github.com/fastlane/fastlane/pull/30176)).
This includes its Rubyzip 3 API compatibility fix and requires Rubyzip 3.4.0 or
newer, which fixes [CVE-2026-85396](https://rubysec.com/advisories/CVE-2026-85396/).
Released Fastlane 2.239.0 still requires Rubyzip below 3.0; replace the commit pin
with a released version once it includes this upstream fix.

```sh
bundle install
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac development
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac verify
```

`development` builds and verifies the staging app. It does not launch, quit, or
replace a running agent. Quit the app before rebuilding; restart the matching
development agent and launch the new app before recording native journeys.
Screenshots and journey evidence are retained locally under `.build/ui-audit`.
Do not publish screenshots containing authentication secrets or account exports.

For distribution, copy `Config/Signing.example.xcconfig` to the ignored
`Config/Signing.local.xcconfig`. Select the Developer ID certificate, team, and
installed provisioning profiles for the app and both helpers. The app profile
must support Sign in with Apple and `group.com.wali.shared`. Keep credentials
and profiles outside source control. Production marketplace client settings
belong in ignored `Config/Marketplace.production.local.xcconfig`.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac archive
```

Archive from committed source. Local untracked branding previews under `output/`
are allowed; other untracked release inputs and tracked edits are rejected.
The canonical `Config/Package.resolved` is copied to the generated project and
Xcode is forbidden to select new dependency versions during the archive.

This creates a universal Release archive and signed candidate under
`.build/release`. Verification checks all four nested executable signatures,
common Team ID, entitlements, hardened runtime, secure timestamps, matching
versions, and helper containment. Missing signing configuration fails instead
of producing a distributable-looking unsigned build.
`archive.json` binds the source commit, team, and bundle contents. Notarization
rejects a different source commit or an app changed since that verification.

After the exact candidate passes native journeys and the final review, use an
existing `notarytool` Keychain profile:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID WALI_NOTARY_KEYCHAIN_PROFILE=YOUR_PROFILE bundle exec fastlane mac notarize_candidate
```

The lane submits a ZIP, requires an Accepted response, staples and validates the
app ticket, checks Gatekeeper, then creates a fresh distribution ZIP and SHA-256
file. It also packages the stapled app unchanged into a branded drag-to-Applications
DMG, signs that container with Developer ID, submits it for notarization, staples
and validates its ticket, checks Gatekeeper, and writes the final DMG SHA-256.
The app and DMG receipts stay in `.build/release/notarization.json` and
`.build/release/dmg-notarization.json`. The two final formats are
`WALI-VERSION-BUILD-macOS.zip` and `WALI-VERSION-BUILD-macOS.dmg`.
`fastlane mac release` runs archive and notarization together. No lane publishes
automatically as part of that command or changes the production backend.

`release.json` binds the final packages and stapled app to the source commit and
records the Apple submission IDs. Packaging failures preserve the verified
stapled-app digest so outer-DMG notarization can be retried.

## Publish the verified GitHub release

After native journeys and the release review pass, merge the reviewed source
and archive that exact `main` commit. Wait for its `source`, `contracts`,
`swift`, `backend`, and `media` GitHub Actions checks to succeed. Supply the
existing GitHub credential as `GITHUB_API_TOKEN` through a protected process
environment; never put it in a command argument, checked-in file, or log.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac github_release \
  tag:v0.1.0-beta.1 notes:/absolute/path/to/reviewed-release-notes.md
```

Select the actual reviewed tag; its version must match the packaged version.
The lane verifies source, tag target, CI, bundle bytes, signatures, Apple tickets,
Gatekeeper, and package checksums. It creates a draft, uploads ZIP/DMG and
checksums, release notes, project license, notices, full third-party license ZIP,
SPDX inventory and provenance receipt. It checks GitHub's returned sizes and
SHA-256 digests before publishing the draft. Failures leave it unpublished for
inspection; the lane does not overwrite an existing release or retag source.
Repository visibility is not changed.

Publication rejects `--verbose`: the pinned Fastlane HTTP client can otherwise
log authentication headers. All requests use explicit TLS peer verification
and redacted error handlers. The lane uses configured `github_api` actions;
the pinned convenience release action bypasses the secure default in internal
calls. [Fastlane API action](https://docs.fastlane.tools/actions/github_api/),
[GitHub asset digests](https://docs.github.com/en/rest/releases/assets)

Run the credential-free provenance regressions with
`/usr/bin/ruby Tests/Release/release-support-tests.rb`; `make verify` includes them.

## Local branded disk image

After building the matching configuration, package the existing app:

```sh
make build
make package-dmg
# Or select an existing build and output path explicitly:
CONFIGURATION=Debug ./scripts/package-dmg.sh /path/to/WALI.app /path/to/WALI-local-Debug.dmg
```

The default output is `.build/packages/WALI-VERSION-BUILD-local-Debug.dmg`
with a SHA-256 sidecar. Its volume is labeled `WALI Local Debug`. The Debug app
retains its existing ad-hoc seals; this local disk image is not Developer ID
signed or notarized and is not a distribution release. Development builds can
be packaged with `CONFIGURATION=Development`. Packaging does not build, launch,
install, or modify the source app. `APP_PATH` and `DMG_OUTPUT` can also be passed
to `make package-dmg` when selecting both paths.

The shared packager uses macOS `hdiutil`, `ditto`, `sips`, `tiffutil`, `SetFile`,
the Xcode Swift interpreter, and Python 3's standard library. Set `PYTHON_BIN`
to select a Python interpreter. It installs no dependencies, runs no Finder
scripts, and performs no network requests. Temporary images mount without
opening Finder and are detached on success or failure.

The image contains the app and `/Applications` link at `(180, 235)` and
`(480, 235)` within a 660-by-440 Finder window. `Resources/Branding` supplies
`WALI-Volume.icns`, `dmg-background.png`, and `dmg-background@2x.png`; the
background is combined into one Retina TIFF. The packager checks real bundle
branding, writes a bounded `.DS_Store` layout with a native background alias,
and verifies it again after compression and read-only remount. It also verifies
the packaged bundle and compares its file bytes with the original. Finder's
visual rendering remains a separate manual/CUA review.

Current machine evidence (2026-09-09): the pinned Fastlane source loads and
uses Rubyzip 3.6.0. Developer ID Application is installed, but the attempted
Release archive stopped at missing production profiles for WALI, WALIAgent,
and WALILockScreenHelper. Secure Apple authentication, provisioning,
notarization, and final signed native journeys remain pending. No signed
release or App Store submission has been claimed.

The owner requested the initial [App Store review](app-store-review-2026-09-09.md)
before further release work. It is complete as a source audit. The separate
Store product is described by [ADR 0018](../adr/0018-sandboxed-mac-app-store-distribution.md)
and its [implementation plan](../plans/2026-09-09-mac-app-store-distribution.md);
the [metadata packet](app-store-metadata-draft.md) still contains unresolved
owner and production facts. The final Store review must inspect the actual
sandboxed archive and real user journeys.
