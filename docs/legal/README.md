# WALI legal documents

These documents describe the intended WALI marketplace rules for the public
beta. They are source-controlled so the app and backend can pin every
acceptance to an immutable document version.

| Document | Version | Status |
| --- | --- | --- |
| [Privacy Policy](privacy-policy.md) | 2026-09-01 | Draft for counsel review |
| [Terms of Service](terms-of-service.md) | 2026-09-01 | Draft for counsel review |
| [Creator Content License](creator-content-license.md) | 2026-09-01 | Draft for counsel review |
| [Content Guidelines](content-guidelines.md) | 2026-09-01 | Draft for counsel review |
| [Copyright Policy](copyright-policy.md) | 2026-09-01 | Draft for counsel review |
| [Account Deletion](account-deletion.md) | 2026-09-01 | Draft; staging flow implemented |

Public creator uploads must remain disabled until counsel approves the legal
documents, a real legal/support contact is configured, and the accepted
versions are present in the production `legal_documents` table. Repository
issues are not a private channel for personal data, credentials, copyright
notices, or security reports.

These documents state intended public-beta policy, not deployment status.
Account export is verified in staging, including restart recovery and file verification. Deletion is implemented but its full native journey remains a release gate. Rights-proof handling, production support intake, and backup/restore remain gated; consult the release evidence ledger for the current candidate.
