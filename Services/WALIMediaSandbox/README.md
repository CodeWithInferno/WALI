# Networkless media sandbox

Video continues to use `policy/ffmpeg-policy.json`, schema 1 jobs and claims,
four required artifacts and seven classifier samples. `WALI_MEDIA_KIND=still`
selects `process-still` / `verify-still` under the separate
`policy/still-image-policy.json` digest. Empty or `video` uses the existing video
entry point; the Go runner rejects other kinds.

Still admission accepts one 8-bit JPEG (three components) or PNG (RGB/indexed
RGB, optionally alpha), up to 128 MiB, 7680 on either edge and 33,177,600 pixels.
It admits tagged sRGB or explicitly assumes untagged RGB is sRGB. Embedded ICC,
conflicting gamma/chromaticity/EXIF color space, HDR markers, grayscale,
animations and unsupported formats require conversion to an 8-bit sRGB JPEG or
PNG. EXIF orientations 1–8 are applied once. Source metadata and thumbnails are
stripped. No source file is modified.

`still-image-contract.c` is a bounded header/metadata parser, not a decoder. It
uses the existing zlib dependency for PNG CRC checks. FFmpeg fully decodes the
source. RGB pixels retain their values; alpha is composited over black with a
16-bit intermediate, then emitted as opaque RGB8 PNG with the standard sRGB
chunk. Input/decoded RGB8 are bounded at 128 MiB; the alpha working allocation is
bounded separately at 256 MiB within the existing sandbox memory limit. Output
contains only the full-resolution `image_default`, a JPEG poster with at most
1920 on either edge, a 512-square JPEG thumbnail, and one 384×224 JPEG sample.
No MP4 or motion preview is created. The total encoded output bound is 192 MiB.

The second sandbox checks exact schema2/still identity, paths/roles, bytes and
SHA256, absence of private metadata, and performs a complete independent decode
of every artifact and classifier sample. Rehashing corrupt raster data does
not turn it into a verified image. Claims retain existing duration/rate fields
only as the declared image sentinels `0`, `0/1`; those are not UI timing values.
Failure records retain the existing schema1 bounded safe-code envelope.

## Local validation

```sh
bash Services/WALIMediaSandbox/tests/run-corpus.sh
python3 -m unittest discover -s Services/WALIMediaSandbox/tests -p 'test_still*.py'
```

The second command uses the shipped scripts and local FFmpeg in private test
folders, replacing only fixed sandbox paths and GNU stat. It checks all eight
orientations against actual RGB pixels, alpha/metadata, JPEG intake, exact image
roles and samples, and independent rejection of rehashed corrupt output. It
does not prove Linux container behavior.

For the actual Linux binaries, build the existing Containerfile and run the
same pixel corpus with its exact local Docker image ID:

```sh
docker build --platform linux/amd64 -f Services/WALIMediaSandbox/Containerfile \
  --iidfile /tmp/wali-still-image-id Services/WALIMediaSandbox
WALI_STILL_TEST_IMAGE="$(cat /tmp/wali-still-image-id)" \
  bash Services/WALIMediaSandbox/tests/run-corpus.sh --still-runtime
```

Existing `--runtime` hostile-video and provenance checks remain applicable to
the same image. No test changes the user's wallpaper store, uses private media,
or uploads data. Image creation alone is not a deployment or production proof.
