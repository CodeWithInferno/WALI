# 0006: Publish authenticated XPC through a named service

- status: proposed
- date: 2026-08-30
- owner_role: ipc_maintainer
- accepted_by: pending
- approval_reference: signed lifecycle spike required before acceptance
- related: [0001](0001-process-topology.md), [0003](0003-agent-owned-runtime-state.md), [0004](0004-engine-owned-use-cases.md)

## Context

The main app and per-user agent have independent lifecycles and must reconnect
across launch, upgrade, crash, logout, and login. Persisting an anonymous
`NSXPCListenerEndpoint` in shared storage creates stale endpoint recovery,
provenance, and replacement races; possession of serialized endpoint data is
not a sufficient trust decision.

The actual launchd, ServiceManagement, signing, and upgrade lifecycle must be
exercised with signed Development products. Compilation and unsigned unit tests
cannot establish that the service is discoverable or that peer requirements
match real signatures.

## Decision

Subject to the acceptance gate below, publish the agent through a
configuration-specific, launchd-managed named Mach service. `AgentGateway`
encapsulates lookup, activation, interruption, invalidation, backoff, protocol
negotiation, sequencing, and full resynchronization.

The main app never persists an anonymous endpoint and never launches or connects
directly to the transcoder. `WALIAgent.app` owns a separate private XPC
connection to its embedded worker.

Messages use bounded `Data` envelopes or a narrowly allowlisted
`NSSecureCoding` object graph. Every envelope includes protocol version, message
type/version, request ID, idempotency key, expected revision when relevant, and
bounded payload length. Replies use stable error codes. Snapshot sequences
detect gaps and trigger a bounded full resync.

Both listeners evaluate the connecting process against an explicit
configuration-appropriate code-signature requirement before accepting
messages. Identity checks fail closed and occur in addition to payload
validation.

If the signed spike proves that this named-service lifecycle cannot satisfy the
per-user embedded-agent constraints, an explicitly evidenced alternative may be
proposed by revising or superseding this ADR. Persisted anonymous endpoints
remain prohibited.

## Invariants

- Service discovery is durable launchd configuration, not serialized endpoint
  capability data.
- Development and Release identities cannot connect across configurations.
- A peer is authenticated before its messages enter an Engine or worker.
- All payloads, collections, strings, identifiers, and progress streams have
  explicit limits.
- Duplicate request/idempotency keys return the prior terminal outcome rather
  than repeat a mutation.
- Expected revisions reject stale writes.
- Interruption and invalidation never imply command success.
- A sequence gap causes resync, not speculative local state repair.
- The main app cannot reach or activate `WALITranscoder.xpc`.

## Alternatives considered

- Persist an anonymous listener endpoint in the shared container: convenient
  discovery, but stale, replayable, and weakly tied to current service identity.
- Let the main app own the transcoder connection: shortens imports initially,
  but accepted jobs die with the UI and bypass Engine authority.
- Distributed notifications or URL schemes: suitable for hints or activation,
  not authenticated request/reply, progress, ordering, or bounded errors.
- A custom Unix socket: can be made secure but duplicates XPC lifecycle,
  serialization, audit-token, and integration behavior without evidence of
  benefit.

## Consequences

The connection is reconnectable and has an inspectable service identity.
Configuration-specific launchd metadata, activation ordering, signature
requirements, protocol negotiation, and signed integration tests become
mandatory. The transport adapter is more involved than serializing one
anonymous endpoint.

This ADR remains proposed; code must not describe the signed lifecycle as
proven until the gate passes and the status becomes accepted.

## Migration and rollback

No production IPC contract has shipped. Introduce transport-neutral
`AgentGateway` tests first, then add the named adapter and configuration-specific
service names. Existing scaffold code has no endpoint data to migrate.

If the spike fails, remove the launchd adapter while retaining wire and gateway
contracts. Document the failed assumptions and propose a bounded authenticated
alternative. Do not fall back to writing anonymous endpoint archives.

## Verification

Acceptance requires a signed lifecycle spike that proves:

- first launch and consent/registration behavior;
- connection from the matching signed main app and rejection of mismatched
  identities/configurations;
- agent activation, reconnect after interruption, and full resync;
- app and agent upgrade ordering without stale service discovery;
- logout/login and agent restart behavior;
- payload and allowlist rejection for malformed/oversized messages; and
- agent-private worker activation with no main-app route to the worker.

Unsigned adapter tests cover malformed input, protocol skew, duplicate requests,
stale revisions, interruption, invalidation, and sequence gaps, but do not
satisfy the acceptance gate.
