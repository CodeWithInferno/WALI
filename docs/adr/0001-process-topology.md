# 0001: Separate foreground app, runtime agent, and transcoder

- status: partially_superseded
- date: 2026-08-30
- owner_role: architecture_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- superseded_by: [0004](0004-engine-owned-use-cases.md)
- superseded_scope: shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback
- related: [0006](0006-named-authenticated-xpc.md)

> **Scoped supersession:** ADR 0004 supersedes the `WALICore` shared-module
> clause, resolves the previously unspecified transcoder host in favor of an
> agent-private worker, and supersedes the rollback clause that allowed the main
> app to host agent authority. The three-product separation and independent
> agent lifetime remain accepted. The checked-in bundle has not completed those
> migrations.

## Context

Wallpaper rendering must survive closing the catalog window, while the heavy catalog and encoder should consume no resources when unused. Media conversion also needs crash and memory isolation from desktop rendering.

## Decision

Use three executable products:

- `WALI.app` for foreground library, import, settings, and diagnostics;
- embedded `WALIAgent.app` (`LSUIElement`) for menu-bar control, display sessions, playback, and persistent runtime state;
- embedded `WALITranscoder.xpc` for on-demand analysis and encoding.

Shared domain values live in `WALICore`; reusable status presentation lives in `WALIUI`.

## Invariants

- Closing the main window does not stop assigned wallpaper.
- Quitting WALI explicitly terminates app and agent.
- The agent remains useful without the main app running.
- A transcoder crash cannot tear down wallpaper sessions.
- Executable targets never import each other's implementation.

## Alternatives considered

- One process: simpler initially, but retains catalog memory and couples encoder failure to rendering.
- System LaunchDaemon: unnecessary privilege and incompatible with normal per-user WindowServer UI.
- One always-running app with hidden windows: weaker lifecycle/resource separation.

## Consequences

IPC, helper embedding, login-item approval, versioned messages, and multi-process diagnostics become required. Idle resource usage and fault isolation improve.

## Migration and rollback

The main app can temporarily host agent behavior behind the same agent interface if helper startup is broken. Persisted messages and data must remain versioned.

## Verification

- Bundle structure test.
- Main-window close/agent-still-running integration test.
- Agent/transcoder crash-isolation test.
- Idle process and memory benchmark.
