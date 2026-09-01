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
- Runtime-review hardening committed as `18305a1`; no live Apple-store mutation or WallpaperAgent restart occurred.
- Live opt-in preflight then exposed a supported `25F80` Index shape with global/system image choices and empty display maps. Four focused synthesized-display regressions fail at the old “connected display missing” guard, confirming the compatibility gap before implementation.
- Added fixture-backed top-level display override synthesis for missing connected displays. The rollback journal records whole-node absence; disable removes only exact, unchanged WALI-created nodes and preserves external changes.
- Twenty focused agent tests now pass, including three-display enable, exact-root disable, both prepared-crash phases, external-change preservation, known-owned alternate-asset rejection, and malformed-Index zero-partial-mutation.
- Final verification passed: full build, all package and application tests, 19 focused agent tests, architecture checks, 148 architecture mutation cases, and whitespace validation.
- The live Apple wallpaper store and WallpaperAgent remained untouched throughout implementation and verification.
- Subsequent live behavior showed that synthesized display nodes are not a reliable activation surface. Accepted ADR 0009 supersedes that mechanism with compatibility epoch 1 revision 1 while leaving ADR 0008 unchanged as the historical safety boundary.
- Revision 1 selects only the main display's asset through `AllSpacesAndDisplays` and `SystemDefault`, clears `Displays` and `Spaces` while active, and restores the exact four-root preimage on disable. WallpaperAgent is quiesced before a required Apple-store write and refreshed only after commit.
- Twenty-six agent tests now pass on synthetic roots, including global activation/rollback, A-to-B and disable crash recovery, date-only daemon drift, other-field conflict preservation, journal-size preflight, main-display selection, pre-write quiesce ordering, single-flight transactions, and overlapping refresh generations.
- Architecture checks and all 148 architecture mutation cases pass for the revision-1 fixture and ADR 0009 contract. No live Apple store or WallpaperAgent process was touched by this implementation or verification.
