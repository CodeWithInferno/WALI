# 0023: Admit staff-curated licensed catalog content without opening Creator intake

- status: accepted
- date: 2026-09-12
- owner_role: catalog_maintainer
- accepted_by: project_owner
- approval_reference: project-owner approval of the admin licensed catalog upload tool and backend access change, 2026-09-12

## Context

The owner has authorized an initial catalog of licensed third-party videos with
required source and publisher credits. The private import manifest retains the
batch-specific permission and provenance. Neither the uploading account nor WALI
becomes the original author.

The existing media, moderation, and signed publication pipeline is suitable.
Admission is not: ordinary uploads require a creator role and current Creator
Terms acceptance; production has no effective Creator Terms configured. Merely
initializing the existing runtime singleton with a terms version permits public
self-enrollment. Licensed submissions are also deliberately rejected by the
current Creator API despite existing rights/attribution schema support.

An attestation-only catalog agreement is not Creator Terms. Existing
`terms_acceptances.document_kind` can record it honestly, but rights declarations
currently lack a document-kind discriminator and every ordinary command treats
their version as Creator Terms. Putting a bespoke agreement date into those
fields without distinguishing the document would misstate consent and would not
close public self-enrollment.

## Decision

Add one named, bounded **staff-curated catalog admission** endpoint using actual
Supabase-authenticated administrator AAL2. It accepts licensed content under an
explicit, versioned **Catalog License Attestation**, then feeds the existing
upload, canonicalization, staged-artifact, independent-review, and signed-release
pipeline. It does not confer a creator role or accept Creator Terms.

Keep the production `creator_terms_version` null. A null/missing version explicitly
disables all ordinary Creator enrollment and upload mutations. Add an independently
nullable `catalog_license_attestation_version` to runtime configuration; null
disables curated admission. Catalog reads and worker configuration remain usable
with public Creator Terms absent. Both document versions are public configuration
facts; no account ID, private contract, or operator credential is added there.

The new endpoint is `curated-catalog-command`, with API version
`curated_catalog.v1` and a fixed action set: `accept_attestation`, `create_upload`,
`complete_upload`, `save_draft`, `submit`, `status`, and `withdraw`. Requests use the
existing bounded envelope, idempotency, exact-key validation, normalized text,
expected revisions/generations, and safe-error conventions. The client cannot
provide actor identity, assurance level, a public artifact path, processing
success, approval, or publication facts. Each action independently authenticates
the current token and rechecks the active administrator grant in the database.

The uploaded session is immutably marked `staff_curated`; existing sessions default
to `creator`. Ordinary Creator endpoints reject a curated session/submission even
when that account also holds a creator grant. This prevents an AAL1 or old-client
alternate path after the initial privileged upload. A curated session is owned by
the actual authenticated uploading account, preserving exact-path Storage RLS and
the moderator's existing self-review check.

The Catalog License Attestation states that the operator has authority under the
recorded agreement to process, host, distribute, and display each selected work
for WALI; will use the recorded license scope; will preserve original authorship
and required credit; and will retain the agreement reference. It is a factual
operator declaration, not a claim that public Creator legal drafts received
counsel approval. Its immutable text/version is reviewed with this implementation.
Acceptance records use the existing document-kind field with the value
`catalog_license_attestation` and the actual authenticated subject.

Add `attestation_document_kind` to rights declarations, defaulting existing rows
to `creator_terms`. For compatibility, the existing physical
`creator_terms_version` column remains the version slot, but is explicitly paired
with this discriminator. Curated RPCs call it `attestation_version`; they never
write a `creator_terms` acceptance or report acceptance through
`creator_authorization_v1`. The owner export labels the kind and version together.
Database checks bind the declaration kind to its immutable upload admission and
the actual subject's acceptance. This small schema expansion avoids a second
rights/consent store and avoids silently changing the meaning of historic rows.

Only the curated path admits `rights_basis=licensed` with no proof objects. It
requires explicit attestation, an active license permitting redistribution,
truthful rights-holder/source fields, and nonempty required credit. `other` rights,
proof-object grants, proof documents, and public licensed Creator intake remain
closed. No PDF/image upload or scanner is introduced. Private agreement references
stay out of public catalog data; public license terms and credits remain visible.

The negotiated content license must be recorded as its own accurate license/policy
record, not relabeled CC0 or CC-BY. Existing license fields already support this.
Its allowed-use flags and public terms URL are populated from the agreement scope;
the confirmation that credit is required does not establish unrelated rights.
This is controlled deployment configuration, not insertion of wallpaper,
processing, review, or published-release fixtures.

## Invariants

- Supabase remains the public control plane. All authoritative records remain
  behind the private schema, default-deny grants, fixed-search-path functions, and
  existing RLS. Curated service RPCs are allowlisted and executable only by the
  service role; the Edge boundary authenticates real user authority as today.
- Admission, private status, and curated raw-upload writes require the current
  active admin account and real AAL2. No synthetic JWT claims, admin impersonation,
  temporary role fabrication, or automated authenticator custody is introduced.
- The administrator who uploads is the submission owner. A different real,
  authorized moderator/admin account must review it at AAL2. The existing
  `WALI_SELF_REVIEW_FORBIDDEN` rule is retained. No shadow submitter account may be
  created to simulate independent review.
- The current isolated worker, media policy, generation checks, four verified
  staged artifacts, promotion, immutable paths, canonical manifest format,
  signatures, and final publication transaction remain required. No direct
  publication, staging-record adoption, or production `seed.sql` route exists.
- A rights or metadata correction invalidates prior review. Private publication
  snapshot checks bind the attestation kind/version alongside the existing rights
  data; these private consent facts do not enter the public signed metadata.
- All acceptances, state transitions, rights decisions, and publications remain
  auditable. Existing rights/consent retention, export, deletion, and legal-hold
  policy applies; public responses expose only allowed attribution/license facts.
- Existing two-submission processing/review backpressure remains. The curated
  create-upload quota is separately bounded at 24 new sessions per administrator
  per rolling day for this initial batch; ordinary Creator limits do not change.
  Idempotent replays do not consume new-session quota.
- No public Creator legal document is marked effective. No creator grant is
  automatically inserted. Curated publishing metadata can create the existing
  public creator-profile projection for the actual publisher account, but that
  presentation row grants no upload or review capability.
- Public authorship and credit remain truthful. The account is identified as
  publisher; the rights holder and attribution identify the actual credited party.
  The signed metadata's existing creator identity remains the accountable
  publishing account, not a fabricated author identity.

## Relationship to accepted policy

This adds a documented administrative admission operation within ADRs 0011/0014
and preserves their authority, RLS, audit, and independent-review invariants.
ADRs 0012, 0015, and 0017 continue to govern signed releases and canonical media.
It narrows the current Creator API's blanket unavailable-licensed policy only for
this separately authorized staff operation and separates runtime catalog
configuration from public Creator activation. It does not supersede the broader
ADRs or weaken any of their invariants; accepted ADR history is not rewritten.

AGENTS.md's change protocol and GOVERNANCE.md's schema/security decision rules are
why this proposal requires architecture approval before implementation. The
owner's paid-media confirmation already supplies publication authorization; no
second proof-of-permission request is part of this proposal.

## Alternatives considered

- **Invite-only creators plus bespoke dates in Creator Terms fields:** avoids one
  endpoint but still requires a genuinely effective Creator Terms document and
  conflates the private publishing agreement with public consent. A discriminator
  and admission enforcement are necessary either way.
- **Enable all licensed creators and build proof uploads:** much broader than the
  initial licensed catalog, requires document handling that this batch does not
  need, and prematurely opens public intake.
- **Manually insert catalog/review rows or promote staging fixtures:** bypasses
  current authority, rights review, observed-media, and publication invariants.
- **Leave runtime configuration absent:** keeps Creator closed but also suppresses
  the public catalog and omits required worker/publication configuration.

## Consequences

Production can serve the licensed initial catalog without offering public Creator
enrollment. Staff use a bounded operator client rather than a new general native
upload product. Existing Review Tools handle independent review and publication;
end users use the existing Discover, Browse, detail, and install screens.

The remaining human authority requirement is a real authenticated independent
reviewer. The pinned owner currently has no MFA factor; enrollment uses the
existing native Review Access flow. This proposal does not authorize granting a
new person a role or manufacture a second reviewer.

## Migration and rollback

Use one forward migration after approval, retaining old creator defaults and
signatures. Deploy the new Edge endpoint and operator client with curated
activation off, then configure only the reviewed catalog attestation and license.
Leave Creator Terms null. Do not copy data from staging or relink the root project.

Disable new curated admission by clearing its configured version and disabling
the endpoint; reject later uploads/completions/saves/submits while preserving safe
status/withdrawal recovery for existing owned work. In-flight worker jobs can
finish into private storage; no automatic publication follows. Retain additive
schema, consent, and audit history. Existing published catalog stays readable.
If a published item must be removed, use the existing audited visibility/removal
mechanism; use security revocation only for its already-supported reasons.

## Verification

Focused database/Edge tests cover real authorization propagation, AAL1/revoked
roles, disabled intake, cross-mode calls, Storage owner/path checks, truthful
attestation kinds, state/idempotency failures, license/credit validation,
self-review rejection, and unchanged worker/publication invariants. Native tests
cover the closed-Creator/open-catalog presentation and truthful publisher/credit
labels. One staged end-to-end synthetic licensed fixture demonstrates the path
before production. Production acceptance is all 24 accounted for with verified
signed published releases visible in Discover/Browse; source media is preserved.
