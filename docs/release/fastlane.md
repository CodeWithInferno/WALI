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
file. The submission receipt stays in `.build/release/notarization.json`.
`fastlane mac release` runs archive and notarization together. No lane publishes
to GitHub or changes the production backend.

Current machine evidence (2026-09-04): fastlane 2.237.0 runs successfully;
Development signing and bundle verification pass. Developer ID Application
certificate is installed, but production provisioning profiles are missing for
WALI, WALIAgent, and WALILockScreenHelper. Release archive therefore stops at
Xcode signing validation. Notarization has not been attempted.

The `apple-appstore-reviewer` skill is deliberately deferred until application
work and native journey verification are complete (tess todo 11b).
