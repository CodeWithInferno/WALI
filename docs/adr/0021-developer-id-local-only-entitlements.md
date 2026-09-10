# 0021: Local-only Developer ID entitlements

- status: partially_superseded
- date: 2026-09-10
- owner_role: architecture_maintainer
- accepted_by: project_owner
- approval_reference: project-owner explicit session approval 2026-09-10: "Approve ADR 0021"
- superseded_by: 0022
- superseded_scope: 0022=direct_release_local_only_activation_condition
- supersedes: 0020
- supersedes_scope: 0020=direct_release_sign_in_with_apple_requirement

ADR 0022 supersedes only the direct Release local-only activation condition.
The supported entitlement, identity, signing, and native acceptance decisions
below remain in force; this record preserves the original decision.

## Context

ADR 0020 retained native Sign in with Apple for the direct foreground app.
Apple's [supported macOS capabilities matrix](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
lists that capability for Apple Developer Program distribution, but leaves
Developer ID unsupported. [Apple DTS explicitly confirms](https://developer.apple.com/forums/thread/793244)
that Sign in with Apple is not supported for Developer ID apps.

The downloaded direct foreground profile otherwise matches the required team,
identifier, App Group, and certificate, but omits
`com.apple.developer.applesignin`. Agent and helper profiles pass their
existing validation. This evidence matches Apple's distribution restriction;
regenerating the foreground profile cannot satisfy the current requirement.
It does not establish that a portal App Group save removed a capability.

The owner explicitly approved this scoped change on 2026-09-10 under
GOVERNANCE.md. Acceptance authorizes implementation; it does not establish
successful signing, native acceptance, notarization, or publication.

## Decision

Use a separate `Config/WALI-Release.entitlements` for the direct foreground
Release configuration. Retain its existing App Group entitlement and omit
native Sign in with Apple. Map entitlements explicitly by configuration:

| Configuration | Foreground entitlement policy |
| --- | --- |
| Debug | Unchanged credential-free policy |
| Development | Existing `Config/WALI.entitlements`, including Sign in with Apple |
| Release | New direct file; existing App Group, no Sign in with Apple |
| StoreDevelopment / AppStore | Existing Store entitlements, including Sign in with Apple |

Direct Release must remain local-only: require
`WALI_MARKETPLACE_ENABLED = NO` in resolved build settings and verify the
actual bundled `WALIMarketplaceEnabled` value is `NO`. Reject enabled,
missing, unresolved, or malformed values. Do not silently coerce an enabled
candidate to pass verification. Marketplace activation requires a separately
approved authentication design supported by Developer ID distribution and
verified end to end; merely configuring a native Apple client is insufficient.

Keep the existing hosted production workflow's marketplace-enabled input
contract intact. It cannot release this local-only candidate and must remain
blocked by the direct Release policy. Use the existing local prerelease
archive, native acceptance, notarization, and publication gates; this decision
creates no hosted approval bypass.

Supersede only ADR 0020's direct Release native Sign in with Apple retention,
profile requirement, and assumption that native-client configuration alone
can enable future direct marketplace authentication. Its identity namespace
and all other decisions remain in force.

## Invariants

- Preserve `group.com.wali.shared`, all four exact Release identities, the
  common signing team, exact peer checks, hardened runtime, and timestamping.
- Preserve agent, worker, and helper entitlements and permissions, process
  ownership, IPC, storage, and compatibility policy.
- Leave Debug, Development, StoreDevelopment, and AppStore entitlements unchanged.
- Do not modify portal App IDs, certificates, capabilities, or profiles.
  Reuse the downloaded profiles after normal identity, certificate, purpose,
  and expiration validation; no redownload is required by this change.
- Local-only UI must not offer unusable marketplace authentication.
  No weaker signature checks, implicit entitlement exceptions, or source-media
  deletion are authorized.

## Alternatives considered

Regenerating the profile does not overcome Apple's documented restriction.
Removing App Groups or using ad-hoc signing would weaken unrelated requirements.
Reusing Development or Store signing would change the distribution contract.
A browser-based authentication replacement is a separate design, not part of
this prerelease adjustment.

## Consequences

The local-only Developer ID candidate can use supported entitlements. Direct
marketplace release remains blocked. Development and Store authentication keep
their existing capability; no authentication implementation changes here.

## Migration and rollback

No data or identity migration is added. ADR 0020's fresh library, manual reimport,
old-app restore, and full-Quit requirements remain. On acceptance, record the
reciprocal scoped supersession in ADR 0020 and update current release guidance.
Rollback stops the candidate and reverts the scoped changes; it restores the
known signing blocker, not Developer ID support for native Sign in with Apple.

## Verification

Implement narrow configuration-aware updates to `project.yml`, entitlements,
architecture and artifact validators, `scripts/ci-release.rb`, affected
Fastlane gates, and current release documentation. Require focused regressions:

- Release selects the new group-only foreground file; adding native Sign in
  with Apple fails. Development and Store retain their existing files and
  required capability; agent, worker, and helper policies remain unchanged.
- All three exact direct profiles pass without requiring Sign in with Apple.
  Wrong or legacy IDs, wildcards, team/group/certificate mismatch, development
  purpose, and expired profiles still fail.
- Release marketplace `YES`, missing, unresolved, and malformed values fail,
  including mutations of the actual app Info.plist. An exact local-only
  candidate passes; hosted marketplace-enabled input remains incompatible.
- Inspect the signed candidate's actual entitlements and local-only flag before
  accepting archive, notarization, or publication evidence. Run affected
  architecture, signature, bundle, release, and Store isolation fixtures.

Existing exact-source CI, native signed-runtime acceptance, notarization,
stapling, and checksum gates remain. Automated tests must never write the
user's live Apple wallpaper store. Approval and static tests prove neither
native operation nor release completion.
