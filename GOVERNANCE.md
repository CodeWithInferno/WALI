# WALI Governance

WALI is pre-alpha. Governance is role-based so the policy remains accurate
without inventing GitHub teams, maintainers, contact addresses, or service-level
agreements that do not exist.

## Roles

- **Repository owner:** sets product scope, appoints or fills maintainer roles,
  grants explicit architecture approval, resolves deadlocks, and authorizes
  releases and publication.
- **Architecture maintainer:** stewards the module graph, accepted ADRs,
  compatibility policy, and architecture checker.
- **Module maintainer:** owns the responsibilities and compatibility surfaces
  assigned to a role in [`modules.yml`](docs/architecture/modules.yml) and
  [`surfaces.yml`](docs/compatibility/surfaces.yml).
- **Security responder:** privately triages reports under
  [`SECURITY.md`](SECURITY.md), coordinates containment, and may pause a release.
- **Contributor:** proposes and implements scoped changes while preserving
  module ownership, tests, and migration obligations.

One person may fill several roles. A role name in a manifest is an
accountability category, not evidence that a team or individual has been
appointed.

### Controlled role IDs

Policy manifests and ADR metadata use only:

- `project_owner`: product scope, delegations, releases, and tie-breaks.
- `architecture_maintainer`: module graph, ADR coherence, and policy checker.
- `module_maintainer`: temporary generic owner for an undelegated module.
- `domain_maintainer`: stable model values and policy.
- `ipc_maintainer`: wire formats, service identity, and transport adapters.
- `engine_maintainer`: use cases, revisions, jobs, and orchestration.
- `presentation_maintainer`: reusable WALIUI presentation.
- `foreground_runtime_maintainer`: main-app composition and adapters.
- `agent_runtime_maintainer`: agent composition, renderer, and system adapters.
- `media_worker_maintainer`: bounded transcoder composition and adapters.
- `storage_maintainer`: SQLite, manifests, artifacts, journals, and GC.
- `compatibility_maintainer`: version-gated system compatibility surfaces.
- `diagnostics_maintainer`: metrics and redacted exports.
- `catalog_maintainer`: deferred remote catalog contracts.
- `security_responder`: private security triage and release-stop authority.

These identifiers do not assert that a person or hosted team currently fills
the role.

## Decision authority and precedence

[`AGENTS.md`](AGENTS.md) is the normative repository operating policy.
Accepted ADRs are normative for their scoped architecture decisions. A newer
accepted ADR wins only when it explicitly supersedes an older record.

Other material has these roles:

1. `ARCHITECTURE.md` summarizes the accepted architecture.
2. Machine-readable inventories are the authoritative registries for module
   paths/imports/owners and compatibility-surface versions/gates. They project
   accepted policy and cannot override it.
3. `DESIGN.md` governs visual and interaction behavior.
4. Active plans sequence work but do not override accepted decisions.
5. `.cursor/rules/*.mdc` files are concise projections for tooling. They never
   override `AGENTS.md` or an accepted ADR.
6. Research and superseded plans preserve evidence and history; they are not
   implementation authority.

If normative sources appear to conflict, stop the affected work. Resolve a
process-only ambiguity by updating `AGENTS.md`; resolve an architecture conflict
through a new ADR that names the records it supersedes. Do not silently choose
the most convenient source.

## How decisions are made

Lazy consensus applies to reversible, in-scope changes that preserve accepted
ownership, dependencies, compatibility, security boundaries, and user-visible
behavior. A proposal should state its invariant, file scope, tests, and
rollback. Work may proceed when review raises no unresolved technical objection
and the relevant module maintainer—or repository owner while that role is
unfilled—is participating.

Explicit architecture approval is required before changing:

- process or actor ownership;
- package or target dependency direction;
- persistent schema or migration policy;
- IPC contracts, service discovery, or peer authentication;
- security or privacy boundaries;
- rendering or codec strategy;
- supported macOS compatibility;
- runtime dependencies or plugin mechanisms.

Such a proposal needs an ADR in `proposed` state. Approval is recorded by
changing it to `accepted` with `accepted_by` and `approval_reference` metadata.
Bootstrap decisions may use `project_owner_delegation` and
`founding autonomous architecture mandate`; this records repository delegation,
not an external review. Implementation does not imply acceptance.

Objections must identify an invariant, evidence gap, compatibility cost,
security risk, or credible alternative. Preference alone does not create a
veto. The repository owner resolves product-priority deadlocks; architecture
maintainers resolve technical ambiguity through evidence and an ADR.

## Security handling

Follow [`SECURITY.md`](SECURITY.md). Reports involving code execution, path
traversal, signature or IPC authorization, update/catalog integrity, or
destructive data loss stay private until a mitigation and disclosure plan
exist. Do not place exploit details, credentials, personal media, or sensitive
diagnostics in a public issue.

The security responder may request a release pause or narrowly restrict affected
work. Security urgency does not permit erasing evidence, weakening tests, or
silently changing a trust boundary; emergency deviations must be documented and
followed by an ADR when architecture changed.

## Ownership, handoff, and inactivity

The manifests assign modules and compatibility surfaces to roles. Before
editing, identify the responsible role and any active task owning the same
files. One active task owns a file set at a time.

A contributor who pauses work should leave a handoff with current state,
changed paths, verification, unresolved risks, and safe next action. There is no
fixed response SLA while WALI is pre-alpha. After checking for active work, the
repository owner may reassign an inactive area and must preserve the prior work
for review rather than overwrite it.

When ownership overlaps:

1. narrow the file sets or sequence the work;
2. compare proposals against accepted invariants and fresh evidence;
3. ask the relevant maintainers to recommend one path;
4. use a proposed ADR for any remaining architecture disagreement; and
5. let the repository owner record the final tie-break when needed.

Abandoned abstractions are removed or completed before parallel alternatives are
added.

## Enforcement status

Today, enforcement consists of repository policy, review, local tests, and
`scripts/check-architecture.sh`. This document does **not** claim that GitHub
branch protection, required reviews, CODEOWNERS, private reporting, or other
hosted controls are configured.

## License and contributions

Covered WALI code and source documentation use
[Apache License 2.0](LICENSE). Contributions require
[Developer Certificate of Origin 1.1](DCO) sign-off. The repository owner does
not receive a copyright assignment through DCO.

[NOTICE](NOTICE) defines scope: the code license does not grant rights to
wallpaper or other media unless that content carries its own explicit license.
Third-party notices and license terms must remain intact.
