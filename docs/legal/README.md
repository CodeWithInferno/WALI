# WALI legal documents

These documents describe the intended WALI marketplace rules for the public
beta. They are source-controlled. The implemented Creator Terms acceptance
flow records the document version accepted by each account holder.

| Document | Version | Status |
| --- | --- | --- |
| [Privacy Policy](privacy-policy.md) | 2026-09-01 | Draft for counsel review |
| [Terms of Service](terms-of-service.md) | 2026-09-01 | Draft for counsel review |
| [Creator Content License](creator-content-license.md) | 2026-09-01 | Draft for counsel review |
| [Content Guidelines](content-guidelines.md) | 2026-09-01 | Draft for counsel review |
| [Copyright Policy](copyright-policy.md) | 2026-09-01 | Draft for counsel review |
| [Account Deletion](account-deletion.md) | 2026-09-01 | Draft; staging flow implemented |

Public creator uploads must remain disabled until counsel approves the legal
documents, a real legal/support contact is configured, and the approved Creator
Terms version is supported by the native app and matches production
`wali.runtime_configuration.creator_terms_version`. The acceptance flow records
that version in `wali.terms_acceptances` before allowing submission. It does not
implement general privacy-policy acceptance. Repository issues are not a private
channel for personal data, credentials, copyright notices, or security reports.

The owner has confirmed Pratham Patel as the operator and hello@tryclean.ai as
the support/privacy contact. The privacy draft now identifies Supabase and
Resend's sign-in email role. These factual updates do not change any document's
effective version or draft/counsel-review status. Production email API results
and remaining native/legal gates are recorded in the
[10 September ledger](../release/2026-09-10-production-auth-status.md).

These documents state intended public-beta policy, not deployment status.
Account export is verified in staging, including restart recovery and file verification. Deletion is implemented but its full native journey remains a release gate. Rights-proof handling, production support intake, and backup/restore remain gated; consult the release evidence ledger for the current candidate.

The separate [licensed catalog notice](wali-licensed-catalog.md) records the
scope presented for the owner-authorized initial catalog. Staff use the Catalog
License Attestation in [ADR0023](../adr/0023-staff-curated-licensed-catalog.md).
Neither document enables public Creator enrollment or marks the drafts above
as approved.
