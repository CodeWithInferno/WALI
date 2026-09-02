# Marketplace public-beta evidence

**Current status:** CODE READY — staging verified; public production activation remains blocked
**Evidence date:** 2026-09-01
**Release commit:** not selected
**Rollback point:** not selected

This document is intentionally honest. Replace each pending row with a durable
artifact or redacted command result from the exact candidate; do not paste
tokens, database URLs, signing private keys, rights evidence, or user data.

| Area | Environment/artifact | Result | Evidence |
| --- | --- | --- | --- |
| Architecture and API contracts | Local worktree | Pass | `make verify`: 161 mutation fixtures; architecture and marketplace contracts pass |
| Swift package/app/agent/helper tests | macOS 26.2 development host | Pass | `make verify`: WALICore 82 tests; Xcode tests/build and bundle topology verification pass |
| Supabase reset and pgTAP | Local Supabase | Pass | clean rebuild through migration head `202609010014`; 13 files and 219 pgTAP assertions pass |
| Staging schema/function repair | Staging Supabase `nkwz…` | Pass | local/remote migrations match through `202609010014`; `moderate-submission` version 2 is active |
| Edge functions | Local Supabase/Deno | Pass | format, check, lint, and 20 Deno tests pass; all 13 functions active in staging |
| Worker and classifier | Local | Pass | Go vet/race pass; frozen classifier suite 13/13 pass |
| Hostile-media corpus | Local immutable image | Pass locally | five hostile fixtures rejected by Docker image `sha256:84a7d4be464ba6b41601f2ad9de7f82a10c8d2482f8f2807c7592c4c71ef2794`; registry signing remains pending |
| Dedicated VM isolation | Shared host only | Blocked | reachable host `Lokus` is Ubuntu 20.04 with Docker and another production workload; it is not a dedicated replaceable rootless-Podman worker |
| Catalog performance | Staging | Pass at current fixture size | 120 requests, concurrency 8, 0 errors, median 219.84 ms, p95 772.24 ms |
| End-to-end canary | Staging | Pass | real Apple session accepted signed security state, downloaded and verified the hosted artifact, transcoded it, committed catalog provenance, applied it with `fill` scaling and active playback, then deleted it; one-use install recording succeeded and a second consumption was rejected as `install_receipt_consumed` |
| Database/object restore | Isolated restore project | Not run | backup/restore manifest digests required |
| Signing-key rotation/compromise | Staging | Partial pass | primary and recovery anchors accepted signed revocation revision 1; rotation and compromise drills remain pending |
| Legal review | N/A | Not approved | named counsel approval required |
| Swift trust-boundary coverage | Local candidate | Pass | measured file groups exceed their enforced floors: catalog runtime 64.61%, app coordination 54.62%, agent install/storage 45.81% |
| SBOM/license/secret hygiene | Candidate artifacts | Pass locally | SPDX generation and all 43 dependency-license checks pass; tracked secret-shape scan and ignored-config checks pass |
| Vulnerability scan | Candidate artifacts | Pending | attach scanner output from the exact shipped commit before public activation |
| Signed/notarized bundle | Candidate archive | Deferred | codesign/spctl/notary evidence required |
| Live display/Lock Screen matrix | Supported Macs | Pending | hardware/build/topology metrics required |

Public-production blockers are the legal/operator contact, a dedicated worker
host, an isolated production signer/recovery boundary, backup/restore and
incident drills, vulnerability evidence, notarization, and the manual
Apple/display/security matrix. Production remains fail-closed: the verified
Release bundle embeds `WALIMarketplaceEnabled=NO` and no Supabase URL.

The prior media-boundary stop-ship defects are closed in this candidate:
browse/detail/moderation media reaches Apple decoders only through a private,
digest- and length-verified local cache; WALIAgent copies the fixed-root
quarantine descriptor into agent-owned storage and revalidates type, link count,
allocation, length, and digest before transcoding. These controls do not waive
the external production gates above.
