# 0020: Register an available namespace for direct distribution

- status: accepted
- date: 2026-09-10
- owner_role: architecture_maintainer
- accepted_by: project_owner
- approval_reference: project-owner explicit session approval 2026-09-10: "yes" to ADR 0020 and the io.github.codewithinferno.wali identity proposal
- supersedes: 0018
- supersedes_scope: 0018=direct_release_identifier_namespace

## Context

On 2026-09-10, Apple's authenticated Developer portal selected team
`UH5Z2K4G9H` but rejected registration of `com.wali.WALI` with:
“An App ID with Identifier 'com.wali.WALI' is not available. Please enter a
different string.” The team's identifier list contained the existing WALI
Development identifier, but no direct Release identifiers. This is evidence
of unavailability to the selected team, not evidence identifying another owner.

The existing Developer ID certificate is available and the owner has saved the
validated `WALI-DeveloperID` notarization credential. The required direct
profiles cannot be issued for the rejected identifier. The shared group
`group.com.wali.shared` was successfully registered under the selected team.

Remote GitHub release inventory and local tags are empty. There is no evidence
of a shipped direct release whose data can be promised automatic migration.
Existing local prerelease installations and data must still be preserved.

Changing signed peer identities and their bundle-derived storage namespaces
requires explicit approval under GOVERNANCE.md. The owner explicitly approved this proposal on 2026-09-10. Approval authorizes
the scoped implementation and registration; it does not establish an Apple
registration or signed-runtime result.

## Decision

Register the following exact Developer ID identities, subject
to Apple's availability checks, and apply them together to direct Release:

| Role | Current identifier | Direct Release identifier |
| --- | --- | --- |
| Foreground | `com.wali.WALI` | `io.github.codewithinferno.wali.WALI` |
| Agent | `com.wali.WALIAgent` | `io.github.codewithinferno.wali.WALIAgent` |
| Private worker | `com.wali.WALITranscoder` | `io.github.codewithinferno.wali.WALITranscoder` |
| Lock Screen helper | `com.wali.WALILockScreenHelper` | `io.github.codewithinferno.wali.WALILockScreenHelper` |

The namespace follows the existing `CodeWithInferno/WALI` repository identity.
Preserving role suffixes keeps the current app/agent peer derivation coherent.
The worker identifier changes with its containing agent but does not require
a separate Developer ID profile.

The agent service becomes
`io.github.codewithinferno.wali.WALIAgent.control`; the helper service becomes
`io.github.codewithinferno.wali.WALILockScreenHelper.control`. Update their
launchd labels, generated plist filenames, lookup metadata, exact peer
requirements, release validators, and compatibility inventories together.
The private worker service uses its new worker identifier.

Keep `group.com.wali.shared`, the existing signing team, exact-peer/same-team
checks, hardened runtime, timestamping, and the separate helper's permissions.
Provision foreground, agent, and helper with that group; foreground retains
its declared Sign in with Apple capability. Do not register unrelated
capabilities, new signing certificates, or App Store product records.

This decision supersedes only ADR 0018's requirement to preserve the old direct
Release identifiers and the data namespaces derived from them. A reciprocal, scoped supersession note is recorded in ADR 0018 without
rewriting its history. Its Store architecture and every other direct invariant remain
in force; ADR 0006's signed lifecycle acceptance remains a separate gate.

## Invariants

- The displayed product remains WALI, including its approved icon and DMG.
- Direct distribution retains optional Lock Screen integration and its exact
  existing macOS build allowlist. Store still excludes the helper by construction.
- Debug, Development, StoreDevelopment, and AppStore identifiers and data paths
  remain unchanged. Store's competing-direct-agent detection must recognize the
  renamed direct agent so edition separation remains effective.
- Agent authority, process containment, IPC payloads/versions, schema epochs,
  codec strategy, and supported macOS versions remain unchanged.
- Keep generic notification names, authentication service base names, and the
  Lock Screen transaction xattr when they are not bundle/service identities.
  Do not apply a repository-wide textual namespace replacement.
- The initial direct prerelease keeps marketplace disabled and ships no user
  video assets. Future marketplace activation must verify the new native Apple
  client/audience configuration and full sign-in flow separately.
- Registration failure for a proposed identifier stops provisioning. No silent
  alternative identity, profile bypass, or weakened signature check is allowed.

## Alternatives considered

1. Keep the current identifiers: blocked by Apple's actual registration rejection.
2. Publish the existing ad-hoc Debug DMG: does not satisfy the requested signed,
   notarized Developer ID release and its configuration isolation.
3. Remove App Groups or exact peer checks to avoid provisioning: weakens the
   accepted runtime/security contract and is rejected.
4. Change only the foreground identity: introduces inconsistent peer derivation
   and catalog namespace behavior. A coherent direct namespace is smaller to
   reason about and verify than special-case cross-namespace compatibility.
5. Reuse Store or Development identities: breaks the approved edition/build
   separation and is rejected.

## Consequences

Direct Release starts with fresh bundle-derived local state:
`~/Library/Application Support/io.github.codewithinferno.wali.WALIAgent/Library`.
The shared direct CatalogQuarantine and CatalogSecurity prefix changes from
`com.wali` to `io.github.codewithinferno.wali`. Bundle-scoped defaults,
authentication Keychain service names, service registration, and permissions
must be treated as new identities. Do not promise existing tokens, bookmarks,
permissions, or library records will transfer.

## Migration and rollback

Do not automatically copy or delete old libraries, credentials, source media,
bookmarks, helper journals, or Apple wallpaper state. A local prerelease user
must first disable continuity and restore through the old app if it owns an
active Lock Screen transaction, then fully quit the old app and agent before
using the new distribution. Preserve the old app/data for recovery. Manual
re-import is supported; old and new editions must not run playback concurrently.

A fresh-install check must not be presented as upgrade acceptance. If an
existing active helper journal cannot be safely restored through the old app,
stop that user's transition and investigate without patching Apple's store.

Before publication, rollback means stop the candidate and revert the scoped
source changes; leave any newly registered Apple identifiers intact rather
than revoking certificates or deleting unrelated records. Reverting source
does not make `com.wali.WALI` registrable. After publication, any rollback or
further identity migration requires a new compatibility decision.

## Verification

Implementation must include focused checks for the four Release IDs, service
and launchd metadata, exact peer rejection, private worker lookup, bundle-derived
paths, and competing-edition detection. Assert the four other build
configurations retain their identities. Update affected fixtures and release
checks while preserving historical ADRs and evidence.

Run architecture/compatibility, bundle, affected Swift, release, and Store
structural checks; obtain green CI on the exact merged source. Decode the three
Apple profiles and verify OSX, exact bundle/team/group, distribution purpose,
expiration, matching certificate, and foreground Sign in with Apple.

Then use Fastlane to archive a signed candidate, record native acceptance
against its exact bytes, notarize/staple the app and DMG, and publish verified
assets with checksums/licenses/release notes. Live Lock Screen tests remain
manual opt-in under the existing ADRs; automated tests must never write the
user's live Apple wallpaper store. An accepted ADR or green structural test
is not proof of successful registration, signing, native operation, notarization,
or public download availability.
