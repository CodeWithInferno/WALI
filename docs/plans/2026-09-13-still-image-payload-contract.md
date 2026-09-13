# Tagged payload contract for still wallpapers

Status: accepted with [ADR0027](../adr/0027-genuine-still-wallpapers.md).
This document specifies the shared interfaces being implemented. Native model,
wire and renderer work is in progress; intake remains gated until the complete
preparation, persistence, catalog and rendering path passes end-to-end acceptance.
Existing published video bytes and their canonical manifest remain unchanged.

## Shared media meaning

Use `video` and `still` as the only closed media kinds. Kind is validated by
actual decoder inspection, bound to the source digest and immutable processing
generation, and copied into the release. A filename, upload hint or publisher
field alone cannot establish kind. Do not reuse the upload target's existing
`kind: new|wallpaper_update` field for media kind.

Catalog/local image intake starts with JPEG and PNG under the image bounds in
ADR0027. Video intake and HEVC output retain their existing policy. Kind changes
on an existing wallpaper require a new generation/release; never mutate a
published release or an active preparation attempt.

## Engine and app/agent presentation wire

Use app/agent protocol version **3**, retaining version2 rejection behavior
rather than silently accepting unknown content. App and embedded agent ship
together. A mismatched peer receives the existing bounded incompatible-protocol
failure before any mutation.

The common item fields stay: identifier, name, createdAt, pixelWidth/pixelHeight,
posterURL, digest, byteCount and favorite state. Replace required video-shaped
masterURL/previewURL/duration with a typed content value:

```swift
enum WallpaperMediaContent: Codable, Sendable, Hashable {
    case video(masterURL: URL, previewURL: URL, duration: TimeInterval)
    case still(imageURL: URL)
}
```

Exact explicit coding shape, not synthesized associated-value enum encoding:

```json
{"kind":"video","master_url":"file:///…","preview_url":"file:///…","duration_seconds":12.5}
{"kind":"still","image_url":"file:///…"}
```

Reject unknown keys, unknown kind, mixed image/video members, missing required
members, non-file URLs and invalid video duration. Existing scoped presentation
URL/grant validation still applies. Still has no duration or frame rate, including
no zero sentinel. The Engine value and wire DTO can have separately named types
with explicit mapping, preserving package dependency direction.

Remove video assumptions at compile time. Do not keep a convenience `masterURL`
that returns imageURL for old playback callers: that would quietly pass a raster
to AVPlayer. Update UI metadata, preview preparation, assignment, quality choice,
menu status and Lock Screen adapters to switch explicitly on content.

## Agent renderer

The assignment retains displayID and contentFit and contains:

```swift
enum WallpaperRenderingContent: Sendable, Hashable {
    case video(videoURL: URL, efficientVideoURL: URL?, posterURL: URL?,
               lowPowerResponse: PresentationLowPowerResponse)
    case still(imageURL: URL)
}
```

Renderer selection is exhaustive. Video still uses LoopingVideoPlayback. Still
loads only a verified agent-owned canonical raster, then calls
StaticImageWallpaperSurface on the existing desktop canvas. Loading is bounded,
cancellable and generation-checked before swapping surfaces. The static surface itself does not decode files or replace these trust checks.
A serial off-main loader enforces the canonical PNG format, single frame, opaque
8-bit sRGB raster, local regular-file identity and encoded/decoded bounds.

Each canvas has exactly one active presentation adapter. Tear down the old owner
before installing another owner of its onLayout callback. A replacement failure
keeps the existing valid display where possible. The static surface remains one
image/layer; it must not allocate a player, timer or per-frame task.

Add a truthful `displaying` session status for a shown still. Pause/resume and
low-power quality controls affect motion; an image remains visible without
pretending it is playing a video. Explicit Stop/Quit tears it down. Direct Lock
Screen continuity accepts only video content; switching to a still must safely
remove/restore only WALI-owned video continuity records according to the existing
helper transaction, with no raster passed to the Aerial provider. Store remains
helper-free.

## Private preparation wire

Use private worker protocol version **3**, with existing request jobID,
attemptGeneration, bookmark, sourceURL, stagingURL and byte limit plus required
`media_kind`. An inferred upload MIME is only the expected kind; the worker must
inspect bytes and reject mismatch. Existing cancellation and exactly-one-terminal
result behavior remains.

Source media and artifact claims become explicit typed values:

```json
{"kind":"video","pixel_width":3840,"pixel_height":2160,"duration_seconds":12.5,"nominal_frame_rate":30,"has_audio":false,"is_hdr":false,"codec":"hevc"}
{"kind":"still","pixel_width":3840,"pixel_height":2160,"frame_count":1,"bits_per_component":8,"color_space":"srgb","has_alpha":false}
```

Byte count remains common to the enclosing source/artifact claim. Exact image
output roles are `master_image` and `poster_image`, with PNG master and existing
HEIC poster preparation under ADR0027. Video keeps master_video, preview_video,
poster_image. Worker/agent validators compare against the kind's required set,
not every enum case. The agent checks bytes, dimensions, actual codec/frame count
and source digest before journal publication.

## Native persistence

Propose RuntimeSnapshot **epoch1, revision2**, with readable revisions0–2 and an
explicit migration. CommittedLibraryRecord records `media_kind`; stored artifacts
add `master_image` and `png_image`. Existing video records retain their IDs,
source names, hashes, objects, release/variant IDs and the three-role set. A still
has exactly master_image/poster_image and one `wali.image` variant bound through
the existing open renderer/role identifier seam. Model image characteristics
leave duration/rate absent.

Only a pre-revision2 record with the exact legacy video artifact set may infer
video kind during migration. A revision2 record missing kind is invalid. Do not
turn arbitrary incomplete sets into images. Journal validation derives its
required roles from the committed record's explicit kind. Recovery, leases,
tombstones and GC apply to both without changing the sole-writer authority.
Old binaries reject the new snapshot before any state rewrite. An older-binary
rollback must retain the new state and explain incompatibility, never discard
installed images or reset the library.

## Hosted jobs and image claims

Use a declared new worker job/claim version with `media_kind` and a pinned image
policy digest. The exact canonical image role set is:

```json
["thumbnail","poster","image_default"]
```

Media and independent-verification claims agree on source identity, dimensions,
codec, digest/bytes, role set, one raster frame and one classifier sample. Video
jobs keep their current four roles and seven samples. The new worker must read
existing queued video jobs during rollout; an old worker cannot claim an image
job. Promotion uses the same immutable destination/path verification, with
kind-specific allowed roles and MIME. No publisher-provided original is promoted
or signed directly.

## Catalog manifest and API

V1 video manifests and metadata bytes remain immutable. Still manifest:

```json
{"schema":{"epoch":2,"revision":0},"media_kind":"still","key_id":"…","wallpaper_id":"…","release_id":"…","edition":1,"issued_at":"…","artifacts":[{"role":"thumbnail","url":"https://…","sha256":"…","byte_count":1,"media_type":"image/jpeg","width":512,"height":512,"duration_ms":0},{"role":"poster","url":"https://…","sha256":"…","byte_count":1,"media_type":"image/jpeg","width":1920,"height":1080,"duration_ms":0},{"role":"image_default","url":"https://…","sha256":"…","byte_count":1,"media_type":"image/png","width":3840,"height":2160,"duration_ms":0}],"metadata_digest":"…"}
```

The ellipses and byte counts above are explanatory placeholders, not valid signed
fixtures. Canonical key order is exactly the shown order; image role order is
thumbnail, poster, image_default. All image artifacts require duration_ms=0 and
an approved raster MIME. No video role is accepted. Existing bibliography-only
install metadata retains its exact V1 schema and semantics;
it is still bound by the manifest's digest, wallpaper/release and edition.

Add `catalog.v2` reader/install responses with required media_kind. Summary has
required poster and optional preview only for video. Detail has a tagged media
object instead of mandatory duration/FPS/video_default. The new app accepts V1
video manifests and V2 image manifests, selecting the corresponding strict
canonical verifier. Existing signatures, metadata, trust transitions and
revocations retain their current custody and validation.

Every V1 query and request-install path explicitly excludes/rejects non-video
releases before pagination or grant creation. V2 Home, Browse, search, Saved,
related and detail share eligibility/rating/preferences/count logic but bind
cursors to the V2 filter contract. Updates require a new release; old signed
editions remain valid until a normal revocation. This is a versioned API change,
not an extra unchecked field slipped into current exact-key endpoints.

## Integration gate

Approve or adjust these concrete choices before assigning shared source files.
Then split native storage/private worker, Engine/wire/renderer/UI and hosted
schema/processor/API ownership. The migration002 freeze and root-owned video
production test remain intact. Read new and old fixtures, compile both direct
and Store graphs, and complete the real production JPEG/PNG journey before
enabling image intake or advertising still support.
