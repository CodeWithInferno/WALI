# Production authentication preparation — 10 September 2026

This update follows the [9 September ledger](2026-09-09-release-status.md).
It records preparation and remaining gates; it is not a production release or
App Store submission announcement.

## Direct authentication and configuration

The owner approved [ADR 0022](../adr/0022-direct-production-email-otp-authentication.md).
The direct app now has an email-code flow with one foreground session authority,
isolated attempts, explicit admission/cancellation behavior, and window-local
pending actions. SDK refresh and persistence guards prevent old requests from
restoring or replacing a newer session. Each gateway operation retains its
original authentication snapshot across retries. MFA factor reconciliation uses
the authenticated server user instead of stale SDK factor metadata.

Production requires the reviewed public manifest, exact Supabase project,
publishable-key fingerprint, distinct primary/recovery catalog keys, and matching
app/agent configuration digest. Archive, notarization and publication revalidate
those values. The default remains an explicitly disabled local preview.
Local-preview archives are rejected by publication. Synthetic fixtures do not
establish the required live production or key-custody evidence.
See [production configuration](production-configuration.md) and the
[Fastlane guide](fastlane.md).

Development and Store preserve native Apple sign-in. The direct app preserves
its Lock Screen helper and Developer ID identities. No local library schema,
wire protocol, hosted database schema or automatic edition migration changed.

## Production email and API checks

Production Supabase now uses the existing Resend service with the verified
sending domain and sender WALI <hello@tryclean.ai>. Pratham Patel is the
owner-confirmed operator. SMTP save and reload were verified with port 465 and a
60-second sending interval. Supabase indicated an initial 30-message/hour limit;
the separate rate-limit settings page has not been verified. Email
confirmation remains enabled and the server code expiry remains 3,600 seconds.
The configured code length changed from eight to six digits and persisted on
readback, matching WALI's validator. Both signup and existing-account templates
now present branded instructions for entering the code in WALI.

The following checks used production Auth API calls and an owner-controlled
mailbox. Authenticated organization-team inspection confirmed the recipient is
outside the project's team; delivery was not limited to a team address.

| Check | Observed result |
| --- | --- |
| New-account email | Received; subject matched the signup template |
| Existing-account email | Received; subject matched the sign-in template |
| Code verification and authenticated user lookup | HTTP 200 for both flows; same account confirmed |
| Session refresh | HTTP 200; same subject confirmed |
| Reuse of an already consumed code | HTTP 403 |
| Probe-session sign-out | HTTP 204 for both sessions |

These are email-delivery and API results. They do not establish a signed native
authentication journey, native cancellation/session restoration, MFA, deletion,
or production release readiness. Recipient identity, codes, tokens, and private
mailbox evidence are excluded from this public ledger.

## Production preparation

The dedicated production host's approved base remediation and network checks
completed. That host verified the prepared immutable media image against its
publisher key, source annotation, digest and authenticated public trust root,
including offline Rekor signed-entry evidence. Temporary registry credentials
were removed and the VM was stopped again. No media worker or container was
deployed or started by that verification.

A local quality canary preserved the source sample's 1080p/24fps dimensions and
rate. It is not evidence of a production upload/download journey. The requested
24 source videos remain outside the public catalog; redistribution evidence and
the production quality comparison are still required.

## Remaining release gates

Native new/existing-account journeys, cancellation and session restoration,
production expiry/resend/rate-limit checks, product operator MFA, account
deletion, catalog signing/recovery bootstrap, active worker operation, production
quality, and effective legal disclosures remain separate work. The privacy
document names the verified email provider but is still a draft. The root
checkout's staging linkage is not authority to configure production.

No notarized public GitHub app package or App Store submission is established by
this source change. Publication additionally requires final-source CI, signed
native acceptance, notarization/stapling, package verification and the applicable
review gates. The initial production app release must be a prerelease. The
production demo and Store submission follow their own actual end-to-end evidence.
