# Genuine still wallpapers implementation plan

Status: implementation in progress under accepted [ADR 0027](../adr/0027-genuine-still-wallpapers.md).
The owner requires wallpapers and live wallpapers. Existing production video
acceptance continues independently. Tagged native presentation and the static
renderer are implemented; preparation, storage and hosted catalog integration
continue before image intake is enabled.

## Contract checkpoint

The accepted tagged payload contract records the exact native format and
version choices. The media family uses JPEG/PNG intake, opaque 8-bit sRGB PNG
master, JPEG catalog poster/thumbnail, one classifier sample, typed still media,
new still manifest 2.0, V2 reader/install API, and a versioned native image payload.
Image bounds and orientation/alpha policy must match native and hosted workers.
Preserve existing V1 video bytes and direct/Store authority.

The agreed seams are:

| Interface | Form | Implementing owner |
|---|---|---|
| Hosted submission/job | Immutable validated kind with exact expected artifact set | Catalog and media worker maintainers |
| Image signed manifest | Epoch 2.0, media_kind=still, thumbnail/poster/image_default | Catalog maintainer |
| Reader/install API | V2 accepts V1 videos and V2 stills; every V1 reader stays video-only | Catalog and foreground runtime maintainers |
| Private preparation | Versioned still request and claim, no video duration/rate | IPC and media worker maintainers |
| Local release/journal | Explicit video or still artifact family, declared schema migration | Storage maintainer |
| Engine/wire payload | Tagged video(master/preview/poster) or still(master/poster) | Engine and IPC maintainers |
| Renderer assignment | Tagged video or still, existing display and fit fields | Agent runtime maintainer |

Ownership names describe responsibilities, not invented people or teams. The
active tasks must explicitly divide files before implementation.

## Native renderer implementation

`StaticImageWallpaperSurface` owns one bounded CGImage/CALayer presentation on the
existing agent canvas. `WallpaperContentPresenter` selects it for stills and
constructs the existing video player only for video content. It checks replacement
generations after suspension, releases each canvas owner on a kind switch, and
keeps an existing valid still if a replacement fails. Still images truthfully
report `displaying` and remain visible when motion is paused. Stop/Quit cancels
pending work and releases the image and canvas.

`StaticWallpaperImageLoader` serializes off-main decoding of canonical worker
claims and installed object files. Containment/authority belongs to the caller.
It bounds file and raster sizes, rejects nonregular/symlink sources, and verifies
single-frame opaque 8-bit sRGB PNG. A bounded chunk walk rejects animation,
EXIF/text/XMP, unknown chunks and trailing bytes while retaining declared color
information. ImageIO generates an EXIF chunk even without source metadata; the
canonical encoder must remove it before the agent accepts the output.

The focused native suite currently has 24 passing tests: seven presenter tests,
seven surface tests including actual Core Animation pixel rendering, eight PNG
loader tests, and two existing runtime composition tests. These tests use fake
canvases and temporary synthetic media; they do not assign a user wallpaper.
Integrated live import, restore and performance acceptance remain below.

## Delivery sequence

1. **Native image preparation and storage.** Add ImageIO inspection and raster
   preparation to the existing private worker. Enforce bounds before decode,
   reject animation/HDR, normalize orientation/color, strip metadata and return
   exact immutable claims. Add image master media kind/role and kind-specific
   journal commit. Migrate legacy video records without touching their objects.
   First tests: hostile input, digest mismatch, interrupted commit, relaunch,
   unknown newer schema and legacy-video fixtures.
2. **Native typed presentation.** Agree then update Engine items, app/agent wire
   and renderer assignments. Select the prepared static surface for stills and
   preserve existing LoopingVideoPlayback for videos. Update detail/Library
   preview, dimensions and controls. Filter image items out of the direct video
   Lock Screen helper. First tests: protocol mismatch, image assignment/restore,
   replacement, display scaling, Quit, and unchanged video behavior.
3. **Hosted canonical image processing.** Add explicit still jobs to the
   networkless sandbox and independent verifier, then Go claim/promotion and
   classifier validation. No fabricated video or duplicated sample frames.
   First tests: exact image role set and byte bindings, single-frame rejection,
   output budgets, worker retries and valid image promotion.
4. **Catalog publication and compatible readers.** Add a new migration after
   the frozen video migration; add image kind/role, immutable version rules,
   automatic decision and signing integration. Add V2 views/RPCs/Edge/Swift DTOs
   with nullable video-only fields and an explicit media kind. Preserve public
   eligibility, preferences, active counts and account privacy. Test each V1
   Home/Browse/search/Saved/related/detail/install path excludes unsupported
   stills and every V2 path preserves the same ranking/filter rules.
5. **Admission and foreground upload.** Only after all downstream pieces work,
   widen exact JPEG/PNG types in Creator/local pickers, request validators and
   Storage buckets. Reuse the current metadata/rights/terms flow and TUS replay
   behavior. Start no new upload session on a resume. Test wrong MIME, subject
   switch, source replacement and retries.
6. **Production acceptance and release.** Upload one known-permitted JPEG and
   PNG using the signed editable app against production. Confirm real
   publication with no video master; download, assign, close, Quit, relaunch and
   restore. Check Saved and truthful counts. Run the same known-good video to
   establish no regression. Measure CPU, memory and first-image latency with
   hardware/macOS/display/media evidence. Enable advertised image intake only
   after this succeeds. Publishing remains a separate owner-authorized action.

## Documentation and compatibility inventory

Update accepted ADR supersession metadata only after final acceptance. Record
catalog manifest/API, app/agent/private worker versions, runtime snapshot and
image policy fixtures in `docs/compatibility/surfaces.yml` and its checker/schema
where required. Update `docs/security/media-policy.yml`, native/remote media
contracts, API examples, data inventory and user-visible limits. Keep current
video golden fixtures unchanged. Do not edit frozen migration002.

## Reversal and boundaries

Before admission, rollback removes the unused new reader/processor paths. After
admission, disable new still uploads while retaining compatible readers, signed
releases and user-installed image records. An older app cannot rewrite a newer
local snapshot. Do not delete originals, reset databases, change worker
credentials or modify the Apple wallpaper store as part of tests. Isolated unit
tests, source review, deployed APIs and observed native production behavior must
be reported as separate evidence.

The [tagged payload contract](2026-09-13-still-image-payload-contract.md) specifies
the Engine, app/agent/private worker, runtime snapshot and catalog shapes under
the accepted architecture record.
