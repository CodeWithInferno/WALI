# Display Canvas and Lock Screen Continuity Progress

## 2026-08-31

- Status: display canvas committed; authenticated-session Lock Screen adapter implemented and verified against isolated stores.
- Checkpoint `6ae74e8` pushed to private branch `origin/wali-production`.
- Verified existing build before checkpoint push.
- Reverse-engineered installed Backdrop behavior read-only and confirmed the modern per-user Aerial integration.
- Display geometry and the visual assignment canvas landed in checkpoint `4276a4e`.
- Fresh foreground launch exposed an NSXPC callback executor violation; fixed separately in `b2aa2a7` and verified by a clean launch without a new crash report.
- Accepted ADR 0008, activated compatibility epoch 1 revision 0, and added a synthetic redacted modern-Aerial fixture.
- Added backward-compatible opt-in preferences, native Settings copy, transactional manifest/Index editors, WALI-owned rollback journals, and startup/apply/system-event reconciliation.
- Hardened recovery for both crash-before-replace and crash-after-replace states, removed empty ownership journals after disable, and cleaned orphan UUID files left by an interrupted asset install.
- Isolated transaction verification covered semantic no-op behavior, unrelated manifest data, global and Space defaults, two display-scoped choice nodes, rollback, orphan cleanup, and disabled/no-journal behavior.
- Fresh verification passed: `make build`, `make check-architecture`, 147 architecture mutation cases, `make test` (57 package tests plus four macOS runtime test bundles), and `git diff --check`.
- The live Apple wallpaper store and WallpaperAgent were not mutated or restarted during implementation or verification.
- Runtime-review hardening added exact-byte CAS, pre/post choice transactions, stale display/Space retirement, full cross-file preflight, opt-in validation before persistence, durable refresh intent, and successful desktop commands with truthful Lock Screen warnings.
- Fifteen focused cases in the existing `WALIAgentTests` target cover A-to-B and disable crash recovery, stale and newly cloned Spaces, external-choice preservation, CAS rejection, corrupt-poster and invalid-Index zero-partial-mutation, pre-persistence opt-in rejection, desktop-success warnings, refresh recovery after commit, and overlapping refresh generations.
- Next: commit the runtime-review hardening without pushing, then reserve live opt-in validation for an explicit manual checkpoint.
