# Third-party notices

The media sandbox build uses these separately licensed components:

- **FFmpeg 7.1.2**, configured without GPL or nonfree components and invoked as
  separate executables. FFmpeg is available under LGPL-2.1-or-later. Source:
  <https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz>.
- **Kvazaar 2.3.1**, built from source as a 10-bit library (`KVZ_BIT_DEPTH=10`)
  and dynamically loaded by FFmpeg as `libkvazaar`. Kvazaar is BSD-3-Clause.
  Source: <https://github.com/ultravideo/kvazaar/releases/tag/v2.3.1>.
- A small in-tree LGPL patch,
  `patches/ffmpeg-7.1.2-libkvazaar-10bit.patch`, teaches FFmpeg's libkvazaar
  wrapper to request Kvazaar's 10-bit API and accept `yuv420p10le`. FFmpeg
  remains configured without GPL or nonfree features.
- **Debian bookworm-slim** and runtime packages. Package copyright files remain
  in the image under `/usr/share/doc`; individual package terms apply.

The exact source and base-image digests are recorded in `Containerfile`. Anyone
publishing an image must also publish the corresponding SBOM and the complete
FFmpeg corresponding-source offer required by LGPL.
