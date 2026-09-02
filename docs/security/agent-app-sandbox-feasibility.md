# WALIAgent App Sandbox feasibility spike

- date: 2026-09-01
- outcome: retain Hardened Runtime without App Sandbox pending signed runtime acceptance
- scope: `WALIAgent.app`; this decision does not affect the separately permissioned Lock Screen helper

## Evidence collected

The generated Development target reports:

```text
CODE_SIGN_ENTITLEMENTS = Config/WALIAgent.entitlements
CODE_SIGN_IDENTITY = Apple Development
ENABLE_HARDENED_RUNTIME = YES
PRODUCT_BUNDLE_IDENTIFIER = com.wali.development.WALIAgent
```

`Config/WALIAgent.entitlements` contains only the WALI application group. It
does not contain App Sandbox, Full Disk Access, network, automation,
user-selected-file, or temporary-exception entitlements. The helper entitlement
file is likewise limited to the application group; Full Disk Access remains an
optional user TCC grant rather than a checked-in entitlement.

The agent currently depends on behaviors whose acceptance is runtime-specific:

- desktop-level AppKit windows on every connected display;
- display and Space change observation;
- sleep, wake, lock, and unlock session events;
- security-scoped imports handed off by the foreground app;
- launchd registration and the agent/transcoder/helper containment graph.

A compile/signing experiment cannot prove these behaviors. Automated tests are
also forbidden from touching the live Apple wallpaper store or changing the
user's active desktop session. There is therefore no honest automated result
that establishes global wallpaper behavior under App Sandbox.

## Decision and exit criteria

Keep Hardened Runtime enabled and keep Full Disk Access out of `WALIAgent`.
Do not add broad temporary sandbox exceptions. App Sandbox may be enabled only
after a signed Development build passes a manual matrix for first launch,
three-display playback, Spaces, display reconnect, sleep/wake, lock/unlock,
security-scoped import, agent relaunch, and helper unavailable/revoked cases.
Record the OS build, signing Team ID, topology, and outcome without personal
paths or media. Failure leaves the current hardened, no-FDA agent unchanged.

Ad-hoc Debug builds have no Team ID and cannot satisfy the helper's designated
peer requirement. They must not receive Full Disk Access; continuity is
expected to fail closed while ordinary desktop playback remains available.
