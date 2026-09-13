# WALI legal documents

These documents describe the intended WALI marketplace rules for the public
beta. They are source-controlled. The implemented Creator Terms acceptance
flow records the document version accepted by each account holder.

| Document | Version | Status |
| --- | --- | --- |
| [Privacy Policy](privacy-policy.md) | 2026-09-01 | Draft for counsel review |
| [Terms of Service](terms-of-service.md) | 2026-09-01 | Draft for counsel review |
| [Creator Content License](creator-content-license.md) | 2026-09-12 | Effective 12 September 2026 |
| [Content Guidelines](content-guidelines.md) | 2026-09-01 | Draft for counsel review |
| [Copyright Policy](copyright-policy.md) | 2026-09-01 | Draft for counsel review |
| [Account Deletion](account-deletion.md) | 2026-09-01 | Draft; staging flow implemented |

Ordinary video uploads through Creator Studio are enabled in production under
[ADR0025](../adr/0025-public-creator-and-catalog-flows.md). A signed-in account
accepts the effective Creator Content License, version 2026-09-12, and supplies
its rights declaration and metadata before processing. Eligible verified
submissions publish automatically; this does not claim human review or proof of
legal rights. The native document must match production
`wali.runtime_configuration.creator_terms_version`, and acceptance is recorded
in `wali.terms_acceptances`. This is not general privacy-policy acceptance and
does not make the other draft documents effective. Repository issues are not a
private channel for personal data, credentials, copyright notices, or security
reports.

The owner has confirmed Pratham Patel as the operator and hello@tryclean.ai as
the support/privacy contact. The privacy draft now identifies Supabase and
Resend's sign-in email role. The Creator Content License is effective as listed
above; the other documents retain their stated draft status. Production email
API results and remaining native/legal gates are recorded in the
[10 September ledger](../release/2026-09-10-production-auth-status.md).

These documents state intended public-beta policy, not deployment status.
Account export is verified in staging, including restart recovery and file verification. Deletion is implemented but its full native journey remains a release gate. Rights-proof handling, production support intake, and backup/restore remain gated; consult the release evidence ledger for the current candidate.

The separate [licensed catalog notice](wali-licensed-catalog.md) records the
scope presented for the owner-authorized initial catalog. Staff use the Catalog
License Attestation in [ADR0023](../adr/0023-staff-curated-licensed-catalog.md).
Those catalog documents did not enable ordinary Creator enrollment. That later
change is authorized by ADR0025 and the effective Creator Content License; it
does not mark the other drafts above as approved.
