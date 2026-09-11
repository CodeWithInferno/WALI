# Direct production configuration

[ADR 0022](../adr/0022-direct-production-email-otp-authentication.md) authorizes the
email-code design. The direct app remains a local preview until the real
production configuration and independent operational gates are complete.

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
