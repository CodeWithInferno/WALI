# Native macOS release workflow

WALI preserves its Developer ID distribution and adds a separate sandboxed
Mac App Store graph under accepted ADR 0018. A successful build, archive, or
notarization is not App Store approval.

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
and archive that exact `main` commit. Wait for its `source`, `history-secrets`, `contracts`,
`swift`, `store`, `backend`, and `media` GitHub Actions checks to succeed. Supply the
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

## Separate Store graph and feasibility

The Store graph is generated as `WALIStore.xcodeproj` from `project-store.yml`
and shared `project-common.yml` target templates. It retains the native
marketplace routes. Production marketplace readiness and UGC review evidence
remain separate submission gates. Direct signing and GitHub lanes are unchanged.

```sh
bundle exec fastlane mac store_feasibility structural_only:true
bundle exec fastlane mac store_feasibility structural_only:true configuration:AppStore
bundle exec fastlane mac store_test
# Only after coordinating the signed feasibility run:
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac store_feasibility \
  structural_only:false allow_provisioning_updates:true
```

Structural builds use `.build/store/DerivedData`; signed feasibility uses
`.build/store/SignedDerivedData`. Both inspect the real embedded bundles and
resources without launching the app. Only the explicit provisioning option
permits Xcode to update profiles; no lane creates or revokes certificates.
A structural result proves source membership and binary shape, not service
registration, app-group access, scoped media grants, desktop rendering, or quit
behavior. Complete the signed journeys in the approved Store implementation
plan before recording that gate as passed.

For a later Store distribution archive, configure ignored
`Config/AppStoreSigning.local.xcconfig` with `WALI_STORE_DEVELOPMENT_TEAM`,
`WALI_STORE_CODE_SIGN_IDENTITY`, `WALI_APP_STORE_PROVISIONING_PROFILE`,
`WALI_AGENT_STORE_PROVISIONING_PROFILE`, and a worker profile if the account
requires one (`WALI_TRANSCODER_STORE_PROVISIONING_PROFILE`). App/agent profiles
must authorize the Store app group; the foreground app also needs Sign in with
Apple. Use Store-specific IDs, never direct-distribution profiles.
Production client settings belong in ignored `Config/Marketplace.AppStore.local.xcconfig`.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
WALI_STORE_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: YOUR_NAME (YOUR_TEAM_ID)' \
  bundle exec fastlane mac store_archive
```

`store_archive` requires committed source, archives with the AppStore
configuration and canonical Swift dependency pins, and exports a signed PKG.
It checks the selected team, Apple certificate class, hardened runtime, exact
entitlements, and CMS-decoded profile dates, identity, capability grants, and
signing certificate membership. It expands the exported package into a temporary
directory, verifies its installer certificate and actual app payload, and writes `.build/store/release/archive.json` with source and
artifact hashes; the recorded app digest belongs to the exported PKG payload.
It does not upload or submit. Store packages do not use the
Developer ID notarization/DMG path. App Store Connect agreement, metadata,
privacy, demo-account, production UGC, signed-runtime, and review gates remain
required before submission.


## Upload and submit the Store build

These are separate commands. Complete the signed native journeys and resolve
production, account deletion, creator blocking, legal, privacy, content rights,
age rating, App Store agreements, pricing/availability and reviewer access first.
The metadata draft is not an upload input. No lane chooses those answers for the
owner or establishes runtime acceptance from a successful source build.

Publish the matching Developer ID release first. `store_upload` and
`store_submit` both recheck current merged main and its seven required CI jobs,
the signed exported Store PKG, the exact version/build/team, and the published
GitHub tag and package/provenance digests. Keep the matching direct release
artifacts under `.build/release`; a draft GitHub release does not satisfy this
ordering. Store and direct binaries have different identities, but these lanes
require them to represent the same reviewed source/version/build.

Use an App Store Connect API key JSON outside source control, selected through
`APP_STORE_CONNECT_API_KEY_PATH`, or secure Apple login with `FASTLANE_USER` and
`WALI_ASC_TEAM_ID`. The latter is the numeric App Store Connect team ID, separate
from the ten-character Developer team used for signing. Provide
`GITHUB_API_TOKEN` only through a protected environment. Never paste passwords,
sessions, private keys or review credentials into terminal command arguments.

Prepare final Fastlane metadata in a private directory: root `copyright.txt`
and `primary_category.txt`, and `en-US/name.txt`, `description.txt`,
`keywords.txt`, `support_url.txt`, `privacy_url.txt`, plus applicable optional
localized fields. Supply 1–10 English screenshots from the actual selected
build under a separate `en-US` screenshots directory, using unique two-digit
prefixes such as `01-library.png`. Only macOS desktop dimensions are accepted.
Upload replaces the screenshots in this supplied English locale and verifies
the ordered remote checksums and sizes; other locales are not supplied. The local checks reject
missing files, symlinks and placeholder text; Apple validates image formats and
Store metadata constraints. Public HTTPS URL presence is not proof that the
page is reachable or that its policy is effective—verify both independently.

The private review JSON has exactly two objects: `app_review_information` and
`submission_information`. Review information requires `first_name`, `last_name`,
`phone_number`, `email_address` and `notes`; include `demo_user` and
`demo_password` only together for an actual task-specific review account.
Submission information requires explicit JSON booleans for
`export_compliance_uses_encryption` and
`content_rights_contains_third_party_content`, based on the final archive and
rights review. These names are the pinned Fastlane action's options; do not
infer an exemption or rights grant from an example elsewhere.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac store_upload \
  github_tag:v0.1.0 metadata:/absolute/private/metadata \
  screenshots:/absolute/private/screenshots review:/absolute/private/review.json

# After the same uploaded build completes processing and the review is ready:
DEVELOPMENT_TEAM=YOUR_TEAM_ID bundle exec fastlane mac store_submit \
  github_tag:v0.1.0 metadata:/absolute/private/metadata \
  screenshots:/absolute/private/screenshots review:/absolute/private/review.json
```

Upload sends the verified package, final metadata and screenshots without
submitting. `.build/store/release/upload.json` records the exact source,
package and review-input fingerprints after Transporter succeeds. An interrupted
or duplicate upload requires inspecting App Store Connect and the local receipt;
these lanes never silently adopt a previously uploaded unrelated build.
Ambient `DELIVER_*` overrides and `Deliverfile` configuration are refused so
they cannot turn a real upload into a successful validation-only run.

Submission requires that receipt and the unchanged review inputs, selects the
specific macOS version/build (never `latest`), refuses processing/invalid/expired
builds, and runs Fastlane metadata Precheck with errors stopping the lane. It
does not reject an existing submission or enable automatic release. The final
receipt identifies the Apple build and review submission; Apple approval remains
a separate state. A metadata change requires reconciling the uploaded metadata
and receipts before submitting. Detailed upload/receipt recovery support and
actual credentialed execution remain unverified until the first release run.

Both commands reject verbose mode before reading credentials. Private contact,
demo and declaration JSON remains local; receipts record hashes rather than
those values. Credential-free refusal regressions live in
`Tests/Release/store-submission-support-tests.rb` and run in `make verify`.

References: [Fastlane macOS upload and submission](https://docs.fastlane.tools/actions/appstore/),
[Apple build processing](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[Apple review submission](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).

The Store upload lane creates a candidate version only when no editable version
exists, and refuses to rename a different prepared version. Metadata is restricted
to approved category/copyright files and `en-US` text; review contacts and demo
credentials come only from the private review JSON. Existing screenshot sets in
other languages must be resolved before this English-only lane runs, because the
pinned uploader can reorder those sets even when only English images are supplied.
