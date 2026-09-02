# Architectural Decision Records

WALI uses immutable ADRs for decisions that would be expensive or unsafe to rediscover independently.

## Status lifecycle

`proposed` → `accepted` → `partially_superseded`, `superseded`, or `deprecated`

Accepted records are not rewritten to hide history. Add a new ADR and link both records when a decision changes.
`partially_superseded` requires metadata and a short note naming the exact
clauses that no longer govern.

## Controlled metadata

Every ADR starts with:

- `status`
- `date`
- `owner_role`
- `accepted_by`
- `approval_reference`

Use controlled role IDs from `GOVERNANCE.md`. Proposed ADRs use
`accepted_by: pending`; accepted bootstrap decisions may use
`accepted_by: project_owner_delegation` and
`approval_reference: founding autonomous architecture mandate`. These values
record repository authority, not a person, team, or external approval.
Other controlled `accepted_by` values are `project_owner` and
`architecture_maintainer`.

A scoped supersession uses reciprocal metadata:

- a single reciprocal pair may use a comma-separated scope list;
- when an ADR participates in multiple pairs, each scope field uses
  semicolon-separated `NNNN=scope_a,scope_b` entries, one per counterpart;
- the older ADR records `superseded_by` and `superseded_scope`, while the
  newer record uses `supersedes` and the matching `supersedes_scope` entry.

For every accepted, partially superseded, or superseded ADR, the checker
validates reciprocal references and exact scope-set equality regardless of
whether `accepted_by` is `project_owner_delegation`, `project_owner`, or
`architecture_maintainer`. Scope IDs name clauses; the checker deliberately
does not infer meaning from prose.

## Naming

Use `NNNN-short-kebab-title.md` with the next available four-digit number.

## Required structure

```markdown
# NNNN: Decision title

- status: proposed
- date: YYYY-MM-DD
- owner_role: controlled_role_id
- accepted_by: pending
- approval_reference: required evidence or approval record

## Context
What forces a decision now?

## Decision
What is being committed to?

## Invariants
What must remain true?

## Alternatives considered
What credible options were rejected and why?

## Consequences
What becomes easier, harder, or constrained?

## Migration and rollback
How can existing data/callers move, and how is failure reversed?

## Verification
Which tests, checks, or measurements enforce the decision?
```
