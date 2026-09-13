# 0027: Genuine still-image wallpapers beside live wallpapers

- status: accepted
- date: 2026-09-13
- owner_role: agent_runtime_maintainer
- accepted_by: project_owner
- approval_reference: repository-owner explicit requirement for wallpapers and live wallpapers, followed by the 2026-09-12 AFK directive to complete the working application and release; implements that requested media family without a new permission, owner, process, dependency, or credential scope

## Context

The owner expects ordinary wallpapers and live wallpapers to work through the
same product. WALI currently accepts only video uploads and local imports. Its
signed manifest, worker claim, publication, local journal, Engine snapshot and
rendering assignment all require video artifacts. Adding image MIME types to the
picker would admit content that cannot finish processing, install or display.

There are useful existing seams. `WALIModel` artifacts and renderer requirements
are neutral, ImageIO already prepares and verifies local HEIC posters, and the
agent-owned desktop window has a generic CALayer canvas. The same process and
storage owners can support a bounded raster image without a looping video or a
second rendering engine.

This decision extends the first media family from ADRs 0014/0015 and the complete
product flows in ADR 0025. ADR 0017 continues to govern canonical video. Its
video codec and preview policy are not changed. This adds a compatible image family without changing the accepted video codec
policy or existing published bytes. Exact native and catalog contracts are
recorded in the linked still-image payload contract.

## Decision

### Image intake and canonical bytes

Initially accept single-frame JPEG and PNG. Use explicit supported UTTypes/MIME
values in local import, Creator, Edge validation and Storage policy. Do not expose
a generic promise to accept every image type. HEIC, animated images, vector
formats, image sequences and HDR image intake are outside this initial contract.

The bounds are 128 MiB encoded input, an oriented long edge at most 7680,
at most 33,177,600 pixels, and at most 128 MiB decoded raster storage. Decode
inspection must enforce dimensions, frame count and resource limits before
allocating the full raster. Malformed, animated, oversized or unsupported HDR
input fails with a bounded actionable error. Filenames and MIME hints never
prove media kind.

The existing networkless media sandbox fully decodes and canonicalizes the
image. Accept 8-bit sRGB or untagged input with an explicit sRGB assumption; reject embedded ICC, non-sRGB, conflicting gamma, or HDR input. Apply its orientation,
flatten alpha over black, and strip source metadata, including location and
embedded thumbnails. Produce a full-resolution opaque 8-bit PNG `image_default`,
a JPEG `poster` with a maximum 1920 long edge, and a 512-by-512 JPEG `thumbnail`.
Do not upscale the master. Full-resolution PNG avoids a new lossy master encode.
Independent verification re-decodes each artifact, checks the exact image role
set, format/frame count/dimensions, byte count and digest, and confirms absent
motion/audio metadata. No MP4 is produced for an image.

Image processing produces one classifier sample under a declared new sample
contract. It must not duplicate that image seven times to satisfy the video
contract. Existing classifier output remains optional taxonomy evidence, never
rights or publication authority.

### Catalog and publication

Record validated media kind as an immutable property of the submission
generation/release. Keep all real-subject, rights, generation, revision, quota,
promotion and system-policy decision checks in the existing publication flow.
Expected artifact sets become exact and kind-specific: video keeps its current
four required roles; still requires `thumbnail`, `poster`, `image_default`.
Existing storage tables already accept JPEG/PNG but their role enum, release
constraints, jobs and validators need an additive migration.

Keep existing video manifest 1.0 canonical bytes and signatures unchanged.
Use a still manifest epoch 2, revision 0, with explicit `media_kind: still`,
fixed canonical key/role order and the same identity/metadata-digest/trust and
revocation semantics. Duration and frame rate are absent from image detail;
where the declared canonical image-artifact shape retains duration, it is
exactly zero. Never invent a frame rate or treat an image as `video_default`.

Introduce a V2 catalog reader/install contract. The new app reads existing V1
videos and V2 stills. Existing V1 Home/Browse/search/Saved/related/detail and
install grant paths remain video-only, so shipped readers do not encounter an
unsupported card or partially decode an image. The current exact-key install
API has no effective media capability negotiation; do not imply it already does.
V2 reuses the existing eligibility, user category/rating preferences and truthful
save/download counts.

### Native preparation, storage and wire

Foreground download selects the signed master by kind and uses an opaque,
UUID quarantine reference. Its internal file suffix is selected only from the verified signed media kind: `.png` for still and the existing `.mp4` for video. The agent re-verifies manifest,
metadata, revocations, bytes and exact source identity. The existing private
transcoder service receives a typed still preparation request, fully decodes and
re-encodes a canonical PNG master and bounded HEIC poster using existing ImageIO
support, and returns immutable claims. The agent independently verifies those
claims and publishes them through its existing content-addressed journal.
Creator originals never become foreground/agent decoder input.

Local records use an explicit still master/poster set; video keeps its existing
master/preview/poster set. Avoid `CaseIterable.allCases` as the required release
set after introducing another media family. Advance the runtime snapshot schema
with a declared legacy video migration, preserving IDs, bytes, assignments,
leases and successful imports. Unknown newer schemas reject before write.

Use the existing open renderer identifier seam for `wali.image` and a tagged
payload in Engine/library presentation wire and rendering assignments:

- video: master, efficient preview and poster, duration/frame rate as applicable;
- still: master image and poster, pixel dimensions, no duration/frame rate.

The payload contract fixes app/agent and private worker protocol version 3,
RuntimeSnapshot epoch 1 revision 2 with readable revisions 0 through 2, and
strict explicit video/still coding keys. EngineWallpaperMediaContent and AgentWallpaperMediaContent have separately
validated coding shapes and an explicit adapter mapping. Foundation remains
absent from WALIModel. Old clients must
not silently ignore the tag and send an image URL into video playback.

### Static desktop presentation

The agent remains the only renderer owner. A still assignment uses the existing
desktop window and a small static-image surface on its CALayer canvas. The
surface accepts an already verified CGImage, retains one current image and
layer, applies fill/fit/center/stretch, and re-lays out only on assignment,
scaling or display geometry changes. Center uses native pixels divided by the
display scale and shrinks only when necessary. No AVPlayer, recurring timer,
network access, foreground-owned renderer or system-wallpaper-store write is
needed. Teardown clears image references, removes its layer and detaches its
layout callback once. Each display owns an independent surface.

A preparatory implementation of this isolated surface and fake-canvas tests is
permitted within existing main-actor presentation ownership. It is not wired to
runtime assignment, advertised as image support, or evidence that the complete end-to-end architecture has been verified.

Catalog and Library show image dimensions/format and omit video-only controls
and progress placeholders. The existing direct Lock Screen helper remains
video-only; an image cannot enter that helper by changing its file extension.
Store keeps the same separate identity and sandbox boundaries. Both editions
use their own agent-owned canvas for static desktop images.

## Invariants

- No image is converted to a video to disguise a missing image path.
- Preserve video V1 bytes, codec policy, working playback and production flows.
- The agent remains sole local install/persistence/render authority; private
  worker output is independently verified before publication.
- No new process, dependency, network host, telemetry or system permission.
- No weakening of Creator rights, actual authentication, generation/revision
  binding, signed catalog trust, revocations or exact Storage paths.
- Image metadata and timing remain truthful; no fake duration, FPS or samples.
- Tests use fake canvases and private fixtures, never Apple's live wallpaper store.

## Alternatives considered

Picker-only MIME expansion fails downstream validators. Encoding each image as
a video wastes processing and playback resources and misrepresents its type.
Making the foreground render or writing the system wallpaper store would change
existing authority and Store behavior unnecessarily. General renderer plugins
or a second engine add variation that this single raster adapter does not need.
Reusing the video manifest with missing fields breaks signed V1 readers; silently
rewriting old releases breaks their immutable identities.

## Consequences

Still images receive a real, efficient display path and retain full-resolution
raster quality. Several strict format boundaries must evolve together. PNG
masters can be larger than lossy images, so encoded/decoded caps and observed
memory measurements are required. The isolated surface is a presentation piece;
it does not solve decoding, signing, storage migration or hosted processing by
itself. Existing physical-footprint and latency budgets remain acceptance targets,
not claims established by these unit tests.

## Migration and rollback

Add new schema/API versions and preserve V1 video behavior. Deploy worker and
server support before exposing image intake, then ship the compatible native
reader/agent together. Enable still admission only after the entire production
journey passes. On rollback, stop new still intake and continue serving V1 videos;
retain published image bytes and records. Clients with an older local schema must
fail clearly rather than discard still records. Do not edit frozen migration
002, rewrite old signed manifests or delete user source media.

## Verification

Focused fixtures cover valid JPEG/PNG, malformed/truncated/animated/oversized
images, orientation/color/alpha policy, exact claim sets, independent digest and
decode checks, signed V2 verification and V1 compatibility. Native tests cover
image-specific journal recovery, cancellation, deduplication, version mismatch,
account isolation and count acknowledgement only after publication. Fake-canvas
tests cover static replacement, all four scaling modes, Retina centering,
bounded input, separate display ownership and idempotent teardown without a
window, player or timer.

End-to-end acceptance uploads a real JPEG and PNG through the editable signed
production app, observes genuine image publication, downloads, displays, Quits,
relaunches and restores the assignment. Check Library/Saved/detail/preferences,
old-reader exclusion, multiple displays and video regression. Record physical
footprint, CPU and first-image latency under the existing performance contract.
See [the implementation plan](../plans/2026-09-13-genuine-still-wallpapers.md).
