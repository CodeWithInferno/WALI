# Signed GitHub releases through Actions

The manually dispatched **Signed GitHub release** workflow prepares a Developer
ID candidate with `fastlane mac archive`, then waits for a review of those exact
bytes. After approval it runs `fastlane mac notarize_candidate` and
`fastlane mac github_release`. The combined `release` lane is deliberately split
at its existing candidate review boundary. It does not submit to the App Store
or change the production backend.

This is source preparation for hosted CD. No environment, hosted secret,
certificate, profile, release, or Apple submission was created while adding it.
A successful fixture test is not a successful signed release.

## Configure the existing release identities

A repository administrator must configure two environments before dispatch.
Both must use **Selected branches and tags**, with exactly one **branch** rule
named `main`, and no wildcard or tag rules. The read-only preflight checks these
rules through GitHub's API before the candidate job is scheduled.

- `release-signing` holds candidate signing material. Additional reviewers are
  optional here; producing the reviewable candidate does not require a new
  approval policy.
- `production` holds container signing/notarization material and must have a
  required reviewer. The owner may be that reviewer and may approve their own
  dispatch, consistent with `GOVERNANCE.md`. Approve only after reviewing the
  exact candidate. Do not bypass the review with an administrator override.

GitHub does not offer required reviewers on every plan for private repositories.
If this repository's plan cannot support them, the preflight stops. Configure a
supported protected environment before using CD; do not remove the gate to make
a run green. Environment existence alone is not protection.
[GitHub environment support and permissions](https://docs.github.com/en/rest/deployments/environments)

Configure these **environment variables** with reviewed values:

| Variable | Environment | Meaning |
| --- | --- | --- |
| `WALI_TEAM_ID` | Both | The same approved ten-character Apple team identifier. |
| `WALI_MARKETPLACE_CONFIG_JSON` | `release-signing` | The complete reviewed public production client configuration below. |
| `WALI_NOTARY_KEY_ID` | `production` | Existing Team App Store Connect API key identifier used by notarytool. |
| `WALI_NOTARY_ISSUER_ID` | `production` | That Team API key's issuer UUID. Individual API keys are not supported by this adapter. |

Configure these **environment secrets** through GitHub's secure settings; do not
paste them into workflow inputs, source, terminal logs, or release notes:

| Secret | Environment | Required material |
| --- | --- | --- |
| `WALI_SIGNING_P12_BASE64` | Both | Single-line base64 of a PKCS#12 export containing exactly one valid Developer ID Application identity and its private key. |
| `WALI_SIGNING_P12_PASSWORD` | Both | The password for that PKCS#12 export. |
| `WALI_APP_PROFILE_BASE64` | `release-signing` | Existing macOS Developer ID profile for `io.github.codewithinferno.wali.WALI`, authorizing Sign in with Apple and `group.com.wali.shared`. |
| `WALI_AGENT_PROFILE_BASE64` | `release-signing` | Existing macOS Developer ID profile for `io.github.codewithinferno.wali.WALIAgent`, authorizing `group.com.wali.shared`. |
| `WALI_HELPER_PROFILE_BASE64` | `release-signing` | Existing macOS Developer ID profile for `io.github.codewithinferno.wali.WALILockScreenHelper`, authorizing `group.com.wali.shared`. |
| `WALI_NOTARY_KEY_BASE64` | `production` | Single-line base64 of that existing Team App Store Connect API key's `.p8` file. |

Profiles must authorize the imported certificate, match the exact team and
identifiers, permit Developer ID distribution, and remain valid for more than
one day. The adapter rejects development/device-limited profiles, wildcard app
identifiers, mismatched certificates, and existing profile/configuration files.
It does not register identifiers, obtain profiles, create or revoke certificates,
or enable automatic provisioning. Apple setup remains an explicit prerequisite.

`GITHUB_TOKEN` is provided by Actions for the current run. The workflow needs no
stored GitHub PAT. Only the publication job receives `contents: write`; other
jobs use read access for source, CI, environment and approval checks. Checkout
does not persist the token in Git configuration.

## Review the production client configuration

`WALI_MARKETPLACE_CONFIG_JSON` is a JSON object with **exactly** these nine string
fields, using real reviewed public values rather than the descriptions below:

| Field | Required value |
| --- | --- |
| `WALI_MARKETPLACE_ENABLED` | `YES` |
| `WALI_SUPABASE_URL` | Approved public production HTTPS origin, without query, credentials or fragment. |
| `WALI_SUPABASE_PUBLISHABLE_KEY` | Production `sb_publishable_...` client key; no JWT, service-role or `sb_secret_...` value. |
| `WALI_CATALOG_CDN_HOST` | Approved public hostname only. |
| `WALI_CATALOG_SIGNING_KEY_ID` | Reviewed primary signing key ID. |
| `WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64` | Base64 of the raw 32-byte primary Ed25519 **public** key. |
| `WALI_CATALOG_RECOVERY_SIGNING_KEY_ID` | Distinct reviewed recovery key ID. |
| `WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64` | Base64 of the distinct raw 32-byte recovery **public** key. |
| `WALI_LEGAL_BASE_URL` | Approved public HTTPS location containing the versioned legal documents. |

The adapter rejects disabled/missing configuration, unknown fields, multiline
values, build-setting interpolation, private-key-sized material, and secret key
prefixes. It cannot determine whether an arbitrary 32-byte value is truly a
public key: the owner must obtain these public values from the approved signing
setup. It generates only the ignored production xcconfig and checks all nine
values in the actual archived app. The candidate's app digest includes those
values, so changing production variables after archive does not alter the
reviewed candidate.

## Dispatch and review one candidate

1. Commit the intended `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Config/Base.xcconfig`, along with reviewed, nonempty UTF-8 release notes at
   `docs/release/notes/TAG.md`. A tag has the form `v0.1.0` or `v0.1.0-beta.1`;
   it must match the committed version. Merge the source to `main` and wait for
   all seven required checks: `source`, `history-secrets`, `contracts`, `swift`,
   `store`, `backend`, and `media`.
2. In Actions, select **Signed GitHub release**, **Run workflow**, branch `main`,
   and the exact tag. The equivalent CLI invocation is
   `gh workflow run release.yml --ref main --field tag=v0.1.0`, using the actual
   committed tag. The adapter rejects another repository, ref, event, stale
   main SHA, incomplete CI, missing notes, debug logging, or a reused run attempt.
3. Download this run's `signed-candidate-RUN_ID` artifact. It contains only
   `WALI-candidate.zip` and `archive.json`. Compare the ZIP's
   `shasum -a 256 WALI-candidate.zip` result with the candidate job summary before
   extracting it using `ditto -x -k WALI-candidate.zip ./candidate`.
4. Review the exact signed app and complete the applicable native journeys in
   [the release guide](fastlane.md): foreground/agent startup and quit, supported
   renderer behavior, media import and recovery, account/sign-in and marketplace
   downloads, creator/moderation paths, and helper behavior where enabled.
   Preserve private journey evidence with the commit, hardware/macOS context,
   configuration and app digest. Do not modify, rebuild or re-sign the candidate.
   This candidate is Developer ID signed but is not yet notarized or a release.
5. Open the waiting `production` review. When those journeys and the final
   release review pass, approve with this exact comment, substituting the app
   digest displayed in the candidate summary:

   ```text
   Native review passed: APP_SHA256_FROM_CANDIDATE_SUMMARY
   ```

The workflow reads the approval history for this same run, checks the current
production environment ID, and requires that exact comment/digest. A generic
approval, another environment's approval, or another candidate's digest stops
before credential import and notarization. This records the reviewer's
attestation; it does not turn CI into proof that the native journeys occurred.
[GitHub review history API](https://docs.github.com/en/rest/actions/workflow-runs#get-the-review-history-for-a-workflow-run)

The publication job downloads the immutable artifact ID returned by its own
candidate job. It checks independent job-output hashes for both ZIP and receipt,
then the extracted app's complete bundle digest, source, team, version and build.
It never selects the latest artifact, accepts a run ID input, or rebuilds the
candidate. Explicit hashes are required because the download action's built-in
digest mismatch check is a warning.
[GitHub artifact validation](https://docs.github.com/en/actions/tutorials/store-and-share-data)

Fastlane performs Apple notarization and Gatekeeper checks for the app and DMG,
binds final ZIP/DMG checksums to the receipt, then rechecks current main, required
CI and the exact tag before creating a draft release. It verifies GitHub's
returned asset digests before publishing. App Store upload/submission remains
separate and still depends on its own approved package and review gates.

## Credential lifetime and failures

Each signing job runs on a fresh hosted `macos-26` runner with Xcode 26.2,
Swift 6.2, Ruby 3.4.7, Bundler 4.0.16, the locked Fastlane source, and checked
XcodeGen 2.44.1 bytes. Actions are pinned to full commit SHAs. Dependencies are
installed before signing secrets enter a step; no shared dependency cache is
used by this workflow.

The adapter creates a private temporary keychain, temporarily selects it as the
default and adds it to the search list for the existing profile-based notarytool
lane. It preserves and restores both original settings as quoted argument
arrays. Imported key material is restricted to the temporary keychain; notary
credentials are stored without iCloud sync. Raw import files and secret process
variables are removed before Fastlane runs. Private command output is suppressed.
The keychain lifetime exceeds the two bounded notarization waits.
[GitHub's Xcode signing pattern](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

An `ensure` cleanup restores keychain settings and removes only the files created
by this job. An `always()` step retries cleanup after failures or cancellation;
a journal is retained if restoration/deletion fails. Hosted runner disposal is
the final boundary if the process or machine is terminated before cleanup can
run. No signing directories, keys, profiles, xcconfig files, build logs or private
review records are uploaded as artifacts. The candidate artifact expires after
seven days.

Do not use **Re-run jobs** or **Re-run all jobs** for this workflow. A rerun is
rejected to prevent a previous approval from authorizing changed candidate bytes.
Dispatch a new candidate from the still-current main after investigating the
failure. If a tag or draft release was created, inspect and reconcile it first;
the workflow does not overwrite a release, move a tag or silently resume a partial
upload. A new dispatch creates new signed bytes and requires review of that new
digest. If main moved while approval was pending, the old run stops.

Credential-free checks are `/usr/bin/ruby Tests/Release/ci-release-tests.rb` and
`/usr/bin/ruby -c scripts/ci-release.rb`. The fixtures exercise identity/ref/run
refusals, review binding, transport swaps, public configuration, profile policy,
exclusive file ownership, partial setup, cleanup retry and workflow permissions.
They do not import a certificate, call Apple, test hosted environment support or
publish anything. Record the first real hosted signed run separately before
claiming operational CD.
