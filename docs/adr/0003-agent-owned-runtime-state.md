# 0003: Agent-owned runtime and persistent state

- status: accepted
- date: 2026-08-30
- owner_role: engine_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- clarified_by: [0004](0004-engine-owned-use-cases.md), [0005](0005-content-addressed-artifacts.md), [0006](0006-named-authenticated-xpc.md)

> **Clarification:** “verified artifacts” in the original decision means
> immutable worker claims that become verified only after independent agent
> verification. ADR 0005 defines the install and publication boundary.

## Context

The foreground app and agent may run independently. Allowing both processes to mutate assignments, imports, and library metadata would introduce stale reads, write races, duplicated sessions, and difficult crash recovery.

## Decision

`WALIAgent` is the authority for assignments, active sessions, import installation, and persistent writes. `WALI.app` sends intentions and renders versioned snapshots. The transcoder returns immutable verified artifacts to be installed by the authority.

## Invariants

- One command has one idempotency key and one terminal result.
- Snapshots carry a monotonic revision.
- Stale clients cannot overwrite a newer revision.
- The app does not open the writable SQLite store.
- Transcoder output is untrusted until the agent verifies and atomically installs it.
- Mutations are serialized by an explicit actor and transaction.

## Alternatives considered

- Multi-writer SQLite WAL: technically possible but leaves business ordering and runtime reconciliation distributed.
- Main-app authority: fails when the catalog process is closed.
- File-based eventual consistency: simple transport but weak command acknowledgement and conflict semantics.

## Consequences

The agent interface becomes critical infrastructure and must be versioned, authenticated, reconnectable, and backward-compatible during upgrades. Reads may be cached in the UI, but writes require agent availability.

## Migration and rollback

Every stored schema and IPC envelope includes a version. Unsupported versions fail closed with a recoverable upgrade message. Read-only database tooling remains possible for diagnostics.

## Verification

- Concurrent command ordering and idempotency tests.
- Stale-revision rejection tests.
- Agent restart/reconnect tests.
- Transcoder artifact validation and interrupted-install recovery tests.
