# Third-party notices

The media sandbox build uses these separately licensed components:

- **FFmpeg 7.1.2**, configured without GPL or nonfree components and invoked as
  separate executables. This configuration is available under
  LGPL-2.1-or-later. Complete upstream source:
  <https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz>.
- **Kvazaar 2.3.1**, built from source as a 10-bit library (`KVZ_BIT_DEPTH=10`)
  and dynamically loaded by FFmpeg as `libkvazaar`. Kvazaar is BSD-3-Clause.
  Complete upstream source:
  <https://github.com/ultravideo/kvazaar/releases/download/v2.3.1/kvazaar-2.3.1.tar.xz>.
- The in-tree LGPL patch
  `patches/ffmpeg-7.1.2-libkvazaar-10bit.patch` modifies FFmpeg's libkvazaar
  wrapper to request Kvazaar's 10-bit API and accept `yuv420p10le`. FFmpeg
  remains configured without GPL or nonfree features. This is the only WALI
  patch applied to these upstream sources.
- **Debian bookworm-slim** and runtime packages. Package copyright files remain
  in the image under `/usr/share/doc`; individual package terms apply.

This software is based in part on the work of the Independent JPEG Group.

## Source and license files included in the image

Every built image includes `/opt/wali/share/media-compliance/`:

- `sources/ffmpeg-7.1.2.tar.xz` and `sources/kvazaar-2.3.1.tar.xz` are the
  complete, unmodified upstream archives used by the build, including their
  original copyright notices and source licenses.
- `licenses/ffmpeg/COPYING.LGPLv2.1` contains the complete applicable LGPL
  text; `licenses/ffmpeg/LICENSE.md` preserves FFmpeg's additional licensing
  details and acknowledgements.
- `licenses/kvazaar/LICENSE` contains Kvazaar's complete BSD license and
  copyright notice. `licenses/kvazaar/LICENSE.EXT.greatest` preserves its
  source test-library notice; that test library is not a media runtime feature.
- `build-context/` contains the exact `Containerfile`, WALI's Apache-2.0
  `LICENSE`, these notices, the checksum manifest, the LGPL patch, the media
  policy, and both runtime scripts. These are the explicit source inputs
  needed to rebuild the image. The recipe retains its pinned Debian image
  and package snapshot, compiler settings, dependency digests, and build-time
  source downloads.
- `SOURCE-LICENSES.sha256` records the hashes of the complete upstream
  archives, extracted license texts, project license, and applied patch.
  The build verifies those bytes before copying the bundle into the final
  image. The image corpus additionally checks all bundle files against the
  checkout that built the image.

To inspect the bundle, create a stopped container from the immutable image and
copy `/opt/wali/share/media-compliance` out with the container runtime's
`cp` command. Rebuild from the copied `build-context/` using the included
`Containerfile`; the original archives are also provided alongside it.
The build requires access to the pinned upstream archives and Debian snapshot.
The media runtime itself has no network access.

These files preserve the components' own terms. WALI's Apache-2.0 license
applies to WALI's code and build files and does not replace third-party licenses.
