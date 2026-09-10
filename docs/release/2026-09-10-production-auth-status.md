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

Custom email delivery, real new/existing-account journeys, product operator MFA,
catalog signing/recovery bootstrap, active worker operation, production quality,
and effective legal/provider disclosures remain separate work. The privacy
document is still a draft. The root checkout's staging linkage is not authority
to configure production.

No notarized public GitHub app package or App Store submission is established by
this source change. Publication additionally requires final-source CI, signed
native acceptance, notarization/stapling, package verification and the applicable
review gates. The initial production app release must be a prerelease. The
production demo and Store submission follow their own actual end-to-end evidence.
