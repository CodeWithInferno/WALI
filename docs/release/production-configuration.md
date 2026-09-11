# Direct production configuration

[ADR 0022](../adr/0022-direct-production-email-otp-authentication.md) authorizes the
email-code design. An unconfigured checkout remains a local preview. Rendering
the reviewed manifest selects production mode for direct Release; publication
still requires the independent operational gates below.

`Config/Marketplace.production.json` is a reviewed public source input. Its exact
shape is `{ "schema_version": 1, "settings": { ... } }`; the allowed setting names
are `WALIProductionConfig::MANIFEST_KEYS` in `scripts/production-config.rb`.
Do not copy the synthetic fixtures into this file. Populate it only from the
verified production publishable key and independently established primary and
recovery public catalog keys. No SMTP password, service-role key, database
password, JWT, private signing key, or provider credential is accepted.

The validator fixes project `afgxvhhubqzgpijcstsv`, its Supabase API and Storage
origin, authentication `email_otp`, and the reviewed legal-page location. It
checks the public key fingerprint and distinct canonical 32-byte catalog keys.
The fingerprint identifies bytes; a private provider receipt must separately
prove the publishable key works with the exact production service. Key presence
does not prove catalog bootstrap or recovery readiness.

The current source manifest uses the production publishable key verified against
the exact Auth settings endpoint (HTTP 200 in the retained receipt dated
11 September 2026 UTC). Its SHA256 is
`4d9c2b130f7b4c46abfe86485d5e87ef3298763619bd37d8821a149cc876ee6e`.
The primary and recovery raw public files each contain 32 bytes and match the
key-custody receipt:

| Role | Key ID | Raw public-key SHA256 |
| --- | --- | --- |
| Primary | `wali-production-primary-20260910` | `7f4f2416e8ba0ed6eba0b8b132e419644223803e17a63db9c508bd9a60c768ef` |
| Recovery | `wali-production-recovery-20260910` | `579d8306209c8026b2e083fa263552ff6ef299a0a9952ddde4b95be53dab5e46` |

Both keys passed the recorded local Keychain roundtrip. A separate production
receipt confirms that the primary signing identifier, private key and approved
CDN configuration were installed, with all three provider SHA256 metadata values
matching the expected inputs. The recovery private key was not uploaded.
Independent-host recovery, backup or migration, catalog key registration and
catalog bootstrap remain separate gates. The source manifest's canonical
configuration digest is
`ad33b18a127ae5bd305166371fb3e132ed04852b6c249f7ee553b12e7afc3ee7`.
The CDN host is the same approved Supabase Storage host,
`afgxvhhubqzgpijcstsv.supabase.co`; the legal base remains the repository's public
`docs/legal` directory on `main`. This public configuration does not establish
catalog activation or make draft legal documents effective.

The configuration digest is SHA256 over UTF-8 `schema_version=1\n` followed by
all manifest setting names in ascending ASCII order, each encoded as
`NAME=value\n`. Values are bounded ASCII without whitespace or Xcode references.
This avoids JSON-formatting differences. Ruby release validators and the native
Swift adapter use the same format, checked against a shared fixed digest vector.

After reviewing the source manifest, render the ignored local build input from
the repository root:

```bash
ruby scripts/production-config.rb render . > Config/Marketplace.production.local.xcconfig
```

`ruby scripts/production-config.rb json .` exports the fourteen compiled public
fields for the hosted workflow's `WALI_MARKETPLACE_CONFIG_JSON` variable. Both
outputs add the derived `WALI_PRODUCTION_CONFIGURATION_SHA256`. Slash escaping
in the xcconfig output is for Xcode parsing only;
resolved values must equal the original reviewed bytes. Conditional overrides,
staging/localhost/alternate origins, missing fields, wrong methods, changed
public keys and mixed app/agent trust all fail.

The foreground carries the auth/API fields. The agent carries only release
mode, configuration digest, CDN and catalog trust; it has no Auth client, account
token or publishable-key field. Runtime account ownership stays in the foreground.
Archive, notarization and publication revalidate the source, actual signed
bundle and receipts. Production publication rejects local-preview receipts and bare stable-version
tags; the initial production release must use a prerelease tag such as
`v0.1.0-beta.1` until the broader graduation criteria are accepted.

A release still requires verified custom SMTP and appropriate signup/existing
account code templates; actual new/existing account delivery, refresh, cancel,
sign-out, MFA and deletion journeys; signed catalog/recovery and worker readiness;
and exact-source CI, signed native acceptance, notarization and package hashes.
These are separate results, not properties inferred from a valid configuration.
