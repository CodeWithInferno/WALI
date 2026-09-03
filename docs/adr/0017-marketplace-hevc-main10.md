# 0017: Marketplace canonical video is 10-bit HEVC

- status: accepted
- date: 2026-09-02
- owner_role: media_worker_maintainer
- accepted_by: project_owner
- approval_reference: project-owner AFK marketplace implementation directive 2026-09-01
- supersedes: 0015
- supersedes_scope: 0015=marketplace_canonical_codec

## Context

ADR 0015 requires the media sandbox to fully decode and re-encode untrusted
uploads. The first implementation used OpenH264 Constrained Baseline at 1080p
and a fixed 8 Mbps. Catalog Discover, Browse, and detail then played the even
cheaper 1280p / 2.5 Mbps preview. That conferencing encode is the wrong tool for
cinematic live wallpapers: 8-bit 4:2:0 plus starved bitrate produces banding and
blocking on sunsets and neon, and 120 fps sources were crushed further by a 30
fps Mac recode.

WALI is Apache-2.0. The sandbox FFmpeg build must remain `--disable-gpl
--disable-nonfree`. x264 and x265 are GPL and are not acceptable in this
image. Apple Silicon HEVC hardware decode is the desktop playback path.

## Decision

Marketplace canonical `video_default` is HEVC Main 10 (`yuv420p10le`) MP4
tagged `hvc1`, encoded with Kvazaar (`libkvazaar`, BSD-3-Clause) inside the
existing networkless sandbox. Kvazaar is compiled with `KVZ_BIT_DEPTH=10`.
FFmpeg 7.1.2's libkvazaar wrapper is hardcoded to 8-bit, so the sandbox applies
the in-tree LGPL patch `patches/ffmpeg-7.1.2-libkvazaar-10bit.patch` to request
the 10-bit API and `yuv420p10le`. FFmpeg stays `--disable-gpl --disable-nonfree`.
Native aspect is preserved. The long edge is
capped at 7680 (8K); smaller sources are not upscaled. Playback frame rate is
`min(source, 60)`. Audio, metadata, and extra tracks remain stripped.

`preview` is a separate cheaper HEVC Main 10 rung: long edge at most 1920,
frame rate at most 30, duration at most 30 seconds. Grid surfaces may play
preview. Marketplace detail and desktop install use `video_default`.

Local macOS import and catalog recode keep HEVC Main 10 via VideoToolbox, with
a 60 fps cap and an 8192 long-edge master bound. Catalog bytes remain hostile:
the private transcoder still re-encodes before content-store publication.

## Invariants

- Sandbox FFmpeg stays `--disable-gpl --disable-nonfree`.
- Canonical catalog video is HEVC Main 10, Rec.709, one video track, no audio.
- `video_default` must not be forced to 1080p or a conferencing bitrate.
- Preview remains a distinct, smaller rung and is not a substitute for desktop
  playback quality.
- Creator originals are never decoder-visible in the app or agent.
- Optional ladder roles (`video_1080p`, `video_1440p`, `video_2160p`) stay
  optional; they are not required for V1.

## Alternatives considered

- Shipping creator originals was rejected by ADR 0015.
- OpenH264 at a higher bitrate still cannot do 10-bit or cinematic High
  Profile and remains a conferencing encoder.
- x264/x265 would require `--enable-gpl`.
- SVT-AV1/libaom raise decode and tooling cost on macOS wallpaper surfaces.
- Apple `hevc_videotoolbox` is not available in the Linux sandbox image.

## Consequences

Catalog files are larger than the previous 1080p H.264 defaults, but short
wallpaper loops stay far below feature-film storage. Detail views must fetch
`video_default` through the verified presentation cache. Existing H.264 catalog
releases are not rewritten; new processing uses the new policy digest.

## Migration and rollback

Policy digest change invalidates in-flight attempts. Published artifacts stay
immutable. Rolling back means pinning a previous sandbox image and policy
digest, not mutating stored objects. Reprocessing unpublished submissions
produces a new generation.

## Verification

- `Tests/Worker/process-media-encode-contract-tests.sh` forbids OpenH264,
  1080p `video_default`, and GPL FFmpeg flags, and requires Kvazaar + 10-bit.
- `Services/WALIMediaSandbox/tests/run-corpus.sh` keeps the hostile corpus.
- Rebuilt sandbox `process-media` must emit HEVC Main 10 `yuv420p10le` at native
  resolution (long-edge cap 7680) and pass `verify-media`.
- Marketplace contract checks require `canonical_output.video.codec: hevc`.
- Transcoder tests require master export to preserve frame rate up to 60.
