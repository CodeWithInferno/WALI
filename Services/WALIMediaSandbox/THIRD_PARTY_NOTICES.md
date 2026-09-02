# Third-party notices

The media sandbox build uses these separately licensed components:

- **FFmpeg 7.1.2**, configured without GPL or nonfree components and invoked as
  separate executables. FFmpeg is available under LGPL-2.1-or-later. Source:
  <https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz>.
- **Cisco OpenH264 2.6.0**, built from source and dynamically loaded by FFmpeg.
  OpenH264 source is BSD-2-Clause. Source:
  <https://github.com/cisco/openh264/tree/v2.6.0>. WALI does not redistribute
  Cisco's separately offered binary module.
- **Debian bookworm-slim** and runtime packages. Package copyright files remain
  in the image under `/usr/share/doc`; individual package terms apply.

The exact source and base-image digests are recorded in `Containerfile`. Anyone
publishing an image must also publish the corresponding SBOM and the complete
FFmpeg/OpenH264 source offer required by the resulting distribution terms.
