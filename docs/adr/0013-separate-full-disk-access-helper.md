# 0013: Separate the Full Disk Access Lock Screen helper

- status: partially_superseded
- date: 2026-09-01
- owner_role: security_responder
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01
- supersedes: 0008, 0009, 0010
- supersedes_scope: 0008=lock_screen_privileged_process_ownership;0009=lock_screen_privileged_process_ownership;0010=lock_screen_privileged_process_ownership
- superseded_by: 0018
- superseded_scope: 0018=store_helper_presence,store_agent_sandbox_requirement

> **Scoped supersession:** [ADR 0018](0018-sandboxed-mac-app-store-distribution.md)
> limits this record's helper-presence and unsandboxed-agent decisions to direct
> distribution. The Store graph excludes private Lock Screen integration and
> requires a sandboxed agent. Direct-distribution privileges, behavior,
> authentication, restoration, and signed acceptance requirements remain
> unchanged. Store implementation and signed feasibility are separate gates.

## Context

The experimental authenticated-session Lock Screen adapter needs access to
private per-user Apple wallpaper stores. Marketplace media is hostile input.
Putting Apple-store access, media parsing, playback, catalog networking, and
the application's long-lived engine in one Full-Disk-Access process would turn
a decoder or network compromise into broad filesystem access.

## Decision

Create `WALILockScreenHelper.app` as the only WALI binary eligible for Full
Disk Access. Remove that permission requirement from `WALIAgent`. The helper
owns only the accepted, version-gated Apple-store compatibility transactions
and process refreshes described by ADRs 0008–0010. Their product behavior,
current-user scope, build/schema gates, ownership identifiers, journals,
compare-and-swap rules, and rollback guarantees remain accepted.

The helper exposes four authenticated, versioned operations:
`status`, `activateVerifiedRelease`, `deactivate`, and `restore`. Activation
contains bounded release identifiers and expected digests, never caller-chosen
paths or media bytes. The helper resolves every location beneath compiled fixed
roots, revalidates WALI-owned artifacts, authenticates caller code-signature
requirements, and fails closed before private-store access on any mismatch.
The live peer rule requires the exact expected bundle identifier and the same
non-empty Apple signing Team ID on both processes, then evaluates that
designated requirement against the connecting process. There is no bundle-ID-
only Debug fallback. Consequently an ad-hoc Debug helper is deliberately
unavailable and must never be granted Full Disk Access. Synthetic identities
can be injected only into unit-level policy tests, not the helper composition
root.

The helper has no networking, catalog client, media decoder, preview, database,
WebKit, JavaScriptCore, plug-in loader, shell, arbitrary process launcher,
archive parser, or generic filesystem API. Its dependency and forbidden-import
contract is recorded in `docs/architecture/modules.yml`.

## Invariants

- Ordinary desktop wallpaper operation and `WALIAgent` require no Full Disk
  Access; declining or revoking permission disables only Lock Screen continuity.
- Remote, imported, transcoder, poster, and thumbnail bytes are never parsed in
  a process eligible for Full Disk Access.
- The helper cannot accept URLs, security-scoped bookmarks, absolute paths,
  relative paths, file descriptors from arbitrary locations, scripts, or
  commands.
- Both IPC peers are authenticated by designated requirement before a request
  is decoded or executed.
- Requests are bounded, versioned, replay-resistant, and carry the expected
  release identity, digest, compatibility revision, and mutation intent.
- Supported Apple roots, builds, providers, schema shapes, ownership IDs,
  maximum assets, and journal bounds stay allowlisted and fixture-backed.
- The helper never handles FileVault preboot, loginwindow, another user, root,
  SIP bypass, or direct protected-screen drawing.
- A helper failure is a scoped warning and cannot roll back desktop playback.

## Alternatives considered

- Retaining Full Disk Access in the agent preserves the existing implementation
  shape but creates an unacceptable marketplace privilege combination.
- Giving Full Disk Access to the main app additionally exposes auth sessions,
  catalog responses, previews, and UI attack surface.
- A privileged root daemon is broader than required and does not solve unsafe
  parsing or caller authentication.
- Removing Lock Screen continuity entirely is safer but discards verified,
  reversible functionality that can be isolated behind a voluntary permission.

## Consequences

Lock Screen continuity gains another signed embedded application, IPC contract,
registration lifecycle, peer-authentication rule, bundle-verification path, and
permission UX. The helper can be independently disabled or removed. The agent
remains the engine, SQLite, install, and renderer authority but no longer owns
private Apple-store reads or writes.

`WALIAgent` retains Hardened Runtime without App Sandbox for this change. An
App Sandbox build/signing probe succeeds, but a build does not prove the
desktop-level multi-display window, Spaces, reconnect, security-scoped import,
and current-session event behavior. Those behaviors cannot be exercised safely
by repository automation. Enabling App Sandbox therefore remains blocked on a
signed, interactive acceptance matrix; the privilege split does not weaken
Hardened Runtime or give the agent Full Disk Access in the meantime. The
recorded probe and exit criteria are in
`docs/security/agent-app-sandbox-feasibility.md`.

## Migration and rollback

Before enabling the marketplace, existing Lock Screen journals and WALI-owned
artifacts are discovered by the helper under the same fixed roots and validated
without changing their logical format. Agent-side store mutations are disabled
before helper registration. If the helper migration cannot prove ownership, it
does not write and asks the user to disable/restore with the previous signed
build. Rolling back the helper requires disabling continuity and proving exact
preimage restoration before returning to a build whose agent held permission.

## Verification

- Static policy rejects forbidden helper imports/APIs, network dependencies,
  unaccepted helper source, and missing compatibility entries.
- Bundle verification proves exact containment, identifiers, Hardened Runtime,
  signatures, entitlements, and designated requirements.
- Peer-policy tests reject missing Team IDs, mismatched Team IDs, and spoofed
  bundle identifiers; only the exact same-team identity is accepted.
- Synthetic-store tests cover every operation, bounds, unsupported build/schema,
  path escape, symlink/hardlink, race, interruption, recovery, and rollback.
- Live testing is manual and opt-in; automated tests never open the user's Apple
  wallpaper store or terminate live wallpaper processes.
