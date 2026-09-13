# WALI Privacy Policy

**Version:** 2026-09-01
**Status:** Draft for counsel review; not yet effective
**Draft revision:** 2026-09-10; production publication requires a new effective
version and the applicable acceptance updates.

WALI is an open-source macOS live-wallpaper application. This policy separates
information that stays on the Mac from information used by the optional WALI
marketplace.

## Information that stays on the Mac

Ordinary local-library wallpaper files and filenames, display layout,
per-display assignments, playback state, Lock Screen history, and the contents
of unrelated files stay on the Mac. WALI does not upload them as marketplace
analytics. Media, the original submission filename, and user-provided metadata
are uploaded only when a user explicitly submits through Creator Studio. The
optional Lock Screen helper has a narrow fixed-store role; it does not make
network requests, parse media, or browse arbitrary files.

## Marketplace information

When a person signs in or uses marketplace features, WALI may process:

- an account identifier and, for the direct email-code edition, the email
  address and authentication data needed to request and verify a sign-in code;
- Sign in with Apple identity claims in editions that use native Apple sign-in;
- profile and creator information the person submits;
- favorites, saves, follows, reports, downloads, and verified installs;
- upload bytes and source/attribution metadata, plus rights evidence only when
  the deferred proof workflow is enabled;
- moderation decisions and security/audit records;
- bounded technical data needed to prevent abuse and diagnose failures.

WALI does not need contacts, precise location, advertising identifiers, or the
contents of unrelated files. Public catalog metrics are aggregated and are not
intended to identify an individual user.

## Purposes and sharing

Information is used to authenticate accounts, publish licensed content,
operate search and ranking, prevent abuse, respond to reports, and secure the
service. Service providers may process the minimum data needed to host the
database, objects, authentication, sign-in email delivery, and isolated media
pipeline. WALI does not sell personal information or use marketplace activity
for third-party ads.

Supabase provides hosted authentication, database, and object storage. For the
direct email-code edition, Resend delivers sign-in emails on WALI's behalf.
Resend processes the recipient email address, authentication-message contents
including the sign-in code, and delivery metadata. Its
[Data Processing Addendum](https://resend.com/legal/dpa) describes that provider
processing. WALI's local-data and logging restrictions do not establish that
service providers retain no operational records.

## Retention and deletion

Account data is retained while the account is active and then deleted or
anonymized according to [Account Deletion](account-deletion.md), subject to
security, legal, copyright, and backup-retention requirements. Immutable public
release artifacts may remain when continued redistribution is legally allowed;
otherwise they are delisted and removed under the applicable policy.

## Security and choices

Uploads are treated as hostile, processed without network access, and never
sent directly to the wallpaper renderer. Users may use local wallpapers without
creating a marketplace account. Production Creator Studio accepts ordinary
signed-in video submissions after
acceptance of the effective Creator Content License and an upload-specific
rights declaration. Eligible media publishes automatically after processing and
verification; this does not claim human review or establish legal rights.

The native Account screen implements export and deletion request/status UX.
That is separate from the enabled Creator flow: complete account-operation
readiness still requires hosted processing, private export retrieval, fresh MFA
for deletion, session revocation, Auth identity cleanup, production support
intake, and an exercised end-to-end deployment.

WALI is operated by Pratham Patel. Support and privacy requests may be directed
to hello@tryclean.ai. This document remains a draft pending the required review
and publication gates. Material policy changes require a new version and
renewed acceptance when required.
