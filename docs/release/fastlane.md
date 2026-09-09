# Native macOS release workflow

WALI currently targets Developer ID distribution outside the Mac App Store.
The native runtime is not sandboxed. App Store eligibility is a separate final
review; a successful archive or notarization is not App Store approval.

Use Ruby 3.3 or newer and Bundler. `Gemfile.lock` pins fastlane and its tools.

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

This creates a universal Release archive and signed candidate under
`.build/release`. Verification checks all four nested executable signatures,
common Team ID, entitlements, hardened runtime, secure timestamps, matching
versions, and helper containment. Missing signing configuration fails instead
of producing a distributable-looking unsigned build.

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
to GitHub or changes the production backend.

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

Current machine evidence (2026-09-04): fastlane 2.237.0 runs successfully;
Development signing and bundle verification pass. Developer ID Application
certificate is installed, but production provisioning profiles are missing for
WALI, WALIAgent, and WALILockScreenHelper. Release archive therefore stops at
Xcode signing validation. Notarization has not been attempted.

The `apple-appstore-reviewer` skill is deliberately deferred until application
work and native journey verification are complete (tess todo 11b).
