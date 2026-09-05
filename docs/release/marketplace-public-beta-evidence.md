# Marketplace public-beta evidence

**Current status:** REPAIR CANDIDATE — not production-ready
**Evidence date:** 2026-09-05 UTC
**Candidate:** `wali-production-repair`, based on `70d13b5`
**Hosted environment:** `wali-staging` (`nkwzjuzoyuanjimexulz`) only
**Production release/rollback commit:** not selected

This ledger separates current native evidence from earlier fixture checks. A
successful canary does not prove release readiness or capacity for hundreds of
thousands of downloads. Keep credentials, signed grants, private rights evidence,
and account exports out of this document and public artifacts.

## Confirmed repairs and evidence

| Area | Result | Current evidence and limit |
| --- | --- | --- |
| Creator agreement | Native staging pass | Current draft terms accepted and active creator grant persisted. This is functional evidence, not counsel approval. |
| Creator processing | Native staging pass | Original synthetic 8-second MP4 uploaded through the app; actual dedicated worker generated and verified media; submission `f7921ceb-dc83-425f-bb45-07cbd152ae97` reached ready, then Submitted at 21:58:52 UTC. Earlier failed attempts remain visible. |
| Creator reload | Native staging pass | Optional wallpaper/source fields no longer reject valid original-work submissions. Reopening Studio displays the submitted canary and older rows. |
| Creator listing visibility | Native staging pass | The creator list and submission details now show Removed from Marketplace for the removed canary while retaining its historical publication/processing state. The authenticated creator projection includes current listing status without private moderation notes. |
| Revision recovery | Native staging pass | Separate moderator requested corrected metadata; creator saw the note, changed category and description, and resubmitted at revision7 without reuploading or changing generation1. |
| Worker isolation | Dedicated staging VM pass | `wali-worker` on `wali-tryclean`: rootless Podman, isolated decoder/verifier containers, pinned signed image, bounded resources, local-only health socket. Full host verifier passed. Network egress and capacity gates remain below. |
| Worker failure handling | Native canary and existing checks pass | Fixed SQL failure-code case, immutable artifact names, duplicate-object verification, policy digest rollout, and rootless namespace setup. |
| Deployment recovery | Live staging pass | Content-addressed full configuration snapshots; manual rollback/forward succeeded. Deliberately rejected worker activation restored the previous healthy payload automatically, preserving rollback pointers and removing the pending transaction. Abrupt power-loss/first-install drills remain. |
| Account export | Native staging pass | Build17 restored the existing export after restart through authenticated server references, refreshed its grant, and saved a verified 13,221-byte schema1 JSON for the same subject. Export contents remain private. Deletion recovery is implemented but its destructive journey is unverified. |
| Shared page surfaces | Native pass at 920×620 | Account, Creator Studio, Library use a consistent semantic background. Header content is outside scrolling content. Screenshots retained locally. |
| Library inspector/sidebar | Native geometry pass at 920×620 and minimum width | Search, all navigation rows, and Import Video retain identical horizontal positions and widths before/after opening inspector. Inspector is scoped to detail; native sidebar material remains. |
| Transient catalog failures | Native failure captured; recovery patch built | Observed `NSURLErrorNetworkConnectionLost` (-1005); manual Retry succeeded. Read-only RPCs retry once, cancellation is preserved, and only actual no-connectivity is called Offline. |
| Wallpaper detail | Native staging pass | Found and removed a SwiftUI task/disappearance reload loop. Metadata loaded in 258ms with a single generation; verified video advanced, related navigation and Show in Library worked. |
| Detail appearance and narrow layout | Native pass at 820×612 | Actual system light appearance exposed white metadata on a light background. Semantic foreground colors and an opaque system background repair contrast; narrow metadata stacks and tags wrap. Screenshots216/219 verify readable light/dark details. Library, Account, and Creator Studio were also inspected in light appearance. Original dark appearance was restored. |
| Moderator access/review | Native staging pass for canary | Dedicated test moderator entered TOTP in Account; review routes unlocked. Native full-video playback, changes request, creator correction/resubmission, and approval reached revision8. AAL1 was denied403. Native report hiding/removal is verified below; policy, rights-proof and screening gates remain incomplete. |
| Publication | Native staging pass for canary | Found and fixed an incomplete promotion queue payload. Worker verified and promoted all four artifacts; native publication completed September5 at00:01:40UTC with edition1, release `b9583645-e337-4664-994e-0a646d42b1df`, manifest SHA-256 `fb45f061ff7a960179d3a7c1a98e18c47d37f15f87832283ed2844172dbe56dc`. Only the generated original sample was published. |
| Catalog options | Staging migration applied; native pass | Added the12 product categories, standard tags, and CC0/CC BY license choices without replacing existing IDs or operator edits. Creator selected Abstract and CC0 in the actual submission form. Local synthetic seeds resolve shared options by slug. |
| Report decisions | Native staging pass for original canary | Creator submitted a real report. A separate AAL2 moderator opened its full video, recorded Hide Pending Review (report revision2/triaged, wallpaper revision6/hidden), reopened it and recorded Remove from Marketplace (report revision3/closed, wallpaper revision7/removed). Queue became empty; a new install grant was rejected; native Library retained all8 items including the original sample. Database checks also verified no-self-review, assignment, role/MFA denial, idempotency, stale revisions, audit and six report categories. Public-object deletion, restoration and copyright case handling remain incomplete. |
| Presentation cache | Implemented; focused checks pass; native pressure check pending | Managed verified media is bounded to 3GiB/512 files with concurrent reservations, oldest unleased eviction, active presentation leases, and recognized stale quarantine cleanup. Catalog38 passes including active-file protection and eviction after lease release. Home/Browse/Search and moderator poster hydration have four concurrent downloads. Native cache held47 managed files/143,933,874 bytes. Single metadata timings were883ms Discover and238ms Browse; these are not first-pixel/p95/capacity evidence. Active playback under cache pressure remains unverified. |
| Local import/rendering | Isolated native partial pass | Original sample imported/converted/committed and applied with continuity disabled. Desktop renderer windows and a rendered frame confirmed; continuously advancing playback has not yet been established. |
| Marketplace install | Native staging pass, recovery incomplete | Signed Development agent accepted the matching transcoder. The original generated canary installed with the matching published release/manifest, growing Library7→8. A supplied staging fixture then installed into Library9. A second fixture was cancelled while Preparing; Downloads showed Download cancelled and Try Again, with no new runtime job. Try Again from Downloads completed into Library10/job14; restart retained all10 items. Foreground byte progress is implemented but the fast transfer was not captured. Durable agent progress/cancellation and interrupted-install recovery remain incomplete. Supplied fixtures were not published by this repair and their distribution rights remain unverified. |
| Fastlane/release | Development and verification pass; archive blocked | Pinned fastlane2.237.0 builds and verifies signed staging bundles. Developer ID certificate exists; production app/agent/helper provisioning profiles are missing. No notarization or public package yet. |
| Existing validation | Pass for recorded boundaries | Architecture/API contracts, Go vet/race, 22 Deno checks, Core82, App48, Catalog38, Agent64, bundle23, and signature18 checks pass for recorded revisions. Debug validation16 and signed Development27 include report-status correction, foreground download controls, creator listing visibility, and detail appearance/layout repairs. App48/Catalog38 pass on validation16. Final candidate must be rechecked after further changes. |

## Exact staging worker candidate

- Worker binary SHA-256: `7b4aef9f91ccf396f34f8d30a2b8e947f3d15d9fb0e9fad3a65b35ff6f07d19e`.
- Media/verifier image: `us-central1-docker.pkg.dev/wali-tryclean/wali-media/sandbox@sha256:415fe754c7da9eb7d9effe442176bbbb2608fec3894fe2aa850f28dc63810a6c`.
- Current deployment snapshot: `052d2a7168cddd1f839fe58c59ef2e0572f12fcab67b9ceb535f8c31028192a0`.
- Previous snapshot: `0085139f0212bbce0d0dcb82651bd7262b9f35ba7f86ca368a472afe2d825c1d`.
- Schema includes September4 migrations001–011: media policy, revision recovery, full review video, authenticated account operation recovery, approved publication queue, deployed catalog options, complete promotion messages, publication queue visibility, audited report resolution/private reported-video access, native report categories, and creator listing visibility.
- Empty-input sandbox rejection verifies startup/mounts/policy, not media processing. The native original-video canary supplies processing evidence.

## Work still required before a public release

1. Complete post-publication object/copyright handling, account deletion,
   expired-session recovery, download/install, cancellation and interrupted-job
   recovery. Export reference recovery is verified; exercise deletion recovery with a disposable staging account.
2. Finish the native UI matrix: minimum window size, all pages and empty/error
   states, light/dark appearance, keyboard navigation, accessibility settings,
   and multiple displays. Confirm advancing desktop playback, sleep/wake,
   occlusion, hot-plug, and long-running resource use.
3. Validate the Lock Screen helper against the supported hardware/OS matrix and
   recovery behavior. Its separate worktree changes are not part of this
   candidate's evidence. No live Apple wallpaper-store mutation was used here.
4. Obtain counsel-approved immutable Creator Terms and bind acceptance to their
   content digest. Obtain redistribution rights for supplied fixture media,
   finalize public operator/support/privacy contacts, and review deletion/export
   retention behavior. Staging fixture presence is not distribution permission.
5. Run database **and object** restore into an isolated project. Staging has
   daily backups; PITR was not enabled and restore has not been proven.
6. Exercise signer rotation/compromise recovery and isolate production signing
   and recovery authority. Select and verify a production rollback candidate.
7. Establish worker and delivery capacity with realistic media/traffic, queue
   age and saturation targets, failure alerts, storage/CDN limits, cost budgets,
   provider quotas, and enforced worker egress policy. The original 8-second
   clip took about 134 seconds to process; no 100k-download claim follows from
   this single-worker result.
8. Run final candidate dependency/license/secret/SBOM checks, signed archive,
   notarization, distribution/update checks, and open-source onboarding review.
   Earlier September 1 reports are historical and must not be reused as exact
   candidate verification.

Production activation remains blocked. Do not replace these gates with a
"code ready" label or treat fixture RPC completion as worker end-to-end proof.
