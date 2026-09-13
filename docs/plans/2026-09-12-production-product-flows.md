# Production product flows — integration acceptance

Owner directive: complete the product using one local editable signed app against
production, then release. Branch: `codex/product-flows`. Production Supabase:
`afgxvhhubqzgpijcstsv`. Never use the saved staging link implicitly.

| Flow | Required observed acceptance | Current evidence |
|---|---|---|
| Account | Real available email receives OTP; code admits session; relaunch restores; sign-out/switch clears private state | Fresh email OTP through hello inbox passed; account restored after two signed-app relaunches; sign-out passed. Direct account-switch regressions passed |
| Creator | Signed-in user accepts actual terms, enters rights/credits and metadata, uploads; status explains processing/failure | Real AAL1 account accepted2026-09-12 terms and uploaded Spider-Man clip with licensed rights/source/credits; processing visible after relaunch |
| Publication | Verified upload appears after processing with app closed, survives retry and does not invent human review | Real Rick and Morty upload independently processed in349.64s and automatically published with the app uninvolved. Anonymous V1 Home/Browse/detail and exact public artifact bytes pass. First4K attempt remains failed; retained-source retry006 is available |
| Catalog | 24 licensed supplied videos show actual posters/previews/credits; Browse all, search, filters, sorts | Two real licensed wallpapers are published, Rick and Morty Stargazing and Anime Girl Sword Blue Eyes;22 remain. Signed candidate6 shows Rick in Discover and Library; anonymous Browse sorts, categories, search, detail and exact public bytes pass for both |
| Download | Real verified install commits then displayed count increases once; failure/retry does not inflate | Signed candidate6 completed the real2.5MB catalog download and agent install; displayed download total changed0to1 after completion |
| Library | Downloaded and saved items remain available after relaunch | Signed candidate6 saved Rick, displayed save total0to1, and shows it in Saved and Downloaded. New catalog item relaunch check remains pending; prior still/live local imports persist |
| Discover | Category selection persists; suggestions obey choices; Trending/New have correct distinct ordering | Native Games preference saved successfully; both test accounts retain Games at revision2, personalization enabled. The two current items are Film & TV and Anime & Illustration, so no matching For You section is expected until a Games upload publishes |
| Navigation | Discover/Browse/Library/Downloads/Account/Creator and Settings exercised in native app | Account/Creator/Discover/empty Library/Settings exercised. Start Paused save/reopen passed and original value restored. Remaining content flows pending |
| Media | Both still and live wallpapers complete admission, verification, install and display path | Native3840x2160 sRGB PNG imports, persists and renders. Local4K video and production Rick both visibly animate on the agent desktop when the app Low Power Mode policy allows playback. Prior automatic suspension was Low Power Mode. Hosted still tests pass; activation remains held |
| Worker | Credential renewed; pipeline processes production input; cold reboot starts independently | 24-hour scoped token active until2026-09-13T22:00:35Z.005 renewal source built; Vault activation and cold-boot helpers each blocked by specific approval. Ultrafast4CPU64 sample48.318s vs medium2CPU241.883s. Full2CPUultrafast376-frame4K pipeline passed the unchanged verifier in484.714s. Reviewed video-only ultrafast4CPU worker activated at2026-09-13T03:47:08Z; exact binary and unchanged warm namespace verified.008 is applied for new90-minute video attempts. Full production4K completion remains pending |
| Distribution | Stable GitHub build tested from actual download; Store signed runtime and submission proper | Pending product acceptance |

Root owns integration, ADRs, deployment/trust/worker and native acceptance. Backend
worker owns automatic publication and Creator migration. Native Creator worker
owns upload/terms. Catalog worker owns saved Library/counts/preferences/discovery.
No task publishes a PR/release while these integrated behaviors are incomplete.

## Production observations,2026-09-12

The first native submission is `d512bf4e-5eb8-4666-a340-c61a788433a4`
(wallpaper `d4cba1cc-2d90-4849-84a8-baee2d616d2a`). Its6,141,755-byte
12.533-second4K source was admitted with real account consent and unchanged
licensed attribution. Normal Quit stopped app and agent while the server encoded.
No wallpaper is called published or visible until public fetch and native UI prove it.

The next65,255,408-byte batch reservation exposed a provider mismatch: production
Storage globally permits50MiB, although the app and media buckets permit1GiB.
The1GiB global correction was applied after the owner's completion directive;
provider readback confirmed1073741824. Earlier rejection remains historical. Its exact reservation/idempotency
identity is retained for retry; no source or receipt was deleted.

The first encoder is CPU-bound in the pinned10-bit Kvazaar build under the existing
two-CPU sandbox. The first64-frame comparison completed: medium241.883s,
fast128.784s at QP20; seven sampledRGB16 frames measured40.446vs40.383dB PSNR.
A full-source run was stopped by stale monitoring after an IAP interruption;
the same worker process safely thawed and remained healthy. Full-source
verification is still required.004 now freezes future job deadlines at first
lease;006 creates a bounded new generation on retained-source retry.

Temporary test preference: Games selected on the owner account; restore the prior
empty category selection after the native matching-content acceptance. Content
rating Teen and personalization enabled are unchanged.

## Integration updates,2026-09-13

Native direct build tests now cover explicit still catalog2.0/video1.0 signatures,
V2 reader models, kind-bound quarantine, private-worker output identities,
agent-owned image installation, persisted still reopening, Store poster-only
projection, static CALayer presentation and image metadata/size bounds. These
remain local verification; no catalog media is called publicly visible or
installed from GitHub until those journeys are observed.

Automatic approval review specifically rejected activation of the existing
project HS256 issuer in Supabase Vault for fixed900-second worker renewal. The
question is pending; no Vault issuer/binding was created. This is separate from
the earlier private-ID-map helper rejection. Both source implementations remain
inactive in production; the current scoped credential is still valid.

## First public wallpaper and native observations,2026-09-13

Submission `a21e0d70-b469-414c-913f-89120327c4c6` produced public wallpaper
`88ae9098-1a1d-43c0-add3-cf2825227a33` and signed release
`31c16d61-c116-4c62-b51e-da6b337a0661` at00:56UTC. Anonymous Home, Browse,
detail, poster, preview and canonical-video fetches returned200 and exact
projected SHA-256/byte counts. Public credits and category match the supplied
licensed metadata. This is one published item, not completion of the24-item
catalog. Native save/install/count checks remain separate.

Migration007 repairs existing V1 visibility for ordinary creators using a
LEFT JOIN and a truthful unverified badge fallback; existing view access and
eligibility remain. The35 local assertions include the actual installed view.
The held still migrations are now009/010/011 after the video-budget008 migration;010 carries the compatible video budget while still remains20minutes.
Public V2 activation remains subject to the specific pending approval.

Local signed candidate5 restored the ordinary account and still Library item;
both the still and4K video are Ready. Preview captures show actual animation.
Desktop captures remain unchanged and the engine reports suspended. Renderer
diagnostics must distinguish automatic pause causes before changing policy;
stored low-power/thermal/player fields are currently defaults and are not live
measurements. No screen lock was attempted because a reliable unlock path is
unavailable. GitHub still has beta releases only; no stable release or Store
upload is claimed.


## Candidate6 native acceptance,2026-09-13

Rick and Morty Stargazing completed the actual production account download,
verified agent install, Save, and Apply journey. The displayed totals changed
from0to1 for both save and completed download. Saved and Downloaded both show it;
Library contains this item plus the prior still and4K video. Agent desktop frame
captures visibly show different meteors and character poses (196102and198902bytes).
This is direct renderer evidence, not a database-only check.

The earlier desktop suspension was the configured Low Power Mode Pause policy,
confirmed by signed renderer diagnostics. Setting WALI to Continue Playing
temporarily proved motion for both the local4K video and catalog download.
Restore the original Pause policy after UI access returns. Existing resource
fields were unpopulated defaults; their reporting is being corrected without a
wire/schema or playback-policy change. Do not apply the unused visibility probe.

The Mac locked automatically before the next category/relaunch check. No lock or
unlock operation was initiated. Native continuation awaits manual unlock while
backend work proceeds. Stable GitHub and App Store publication remain incomplete.

## Production worker activation and additional catalog evidence

The video-only worker activation completed at2026-09-13T03:47:08Z, with
main process25078 and binary SHA-256
`26e51abcf03b68e407a86db5b4833acdf0ee36e601fd55db51ca2a20da32f6f5`.
The existing Podman namespace retained start identity333625263. The signed
immutable media image is
`us-central1-docker.pkg.dev/wali-tryclean/wali-media/sandbox@sha256:26ea1d87c51ce6b87cf49730397b1f12fd94f1330d157f9ab21550fcad9812cf`.
Registry read authentication used the VM's existing service account for the
transaction; temporary auth files were removed and no pending transaction
remained. Held ID-map helpers, Vault issuer and hosted still/V2 activation were
not included. The reduced deployment packet applied only008 afterward.

Anime Girl Sword Blue Eyes automatically published at2026-09-13T02:47:00Z
as wallpaper `a9d3a07d-990f-4fe1-bd9c-46e4fca83aad`. Its public poster,
preview and canonical video match the projected bytes and hashes. Nine
anonymous catalog checks pass for the two published items. Herobrine Minecraft,
the longest supplied clip, has now entered the production processing pipeline.

A fresh ordinary email login received and consumed the real code and passed
the provider identity check at2026-09-13T03:48:57Z. That account correctly
cannot read the owner account's failed Spider-Man submission, so no retry
command was issued under the wrong subject. A direct production ownership read
identified the existing owner account for the retained-source retry.

The prepared stable version is0.1.0/build4, above public beta.3/build3.
Existing candidate6 native evidence and candidate7 build evidence do not
substitute for final source, signed build4, notarization and actual GitHub
download acceptance.
