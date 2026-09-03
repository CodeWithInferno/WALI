#!/usr/bin/env bash
# Contract: marketplace canonical video is 10-bit HEVC at native resolution,
# not conferencing H.264 crushed to 1080p. Preview stays a cheaper HEVC rung.
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly PROCESS="$ROOT/Services/WALIMediaSandbox/bin/process-media"
readonly VERIFY="$ROOT/Services/WALIMediaSandbox/bin/verify-media"
readonly POLICY="$ROOT/Services/WALIMediaSandbox/policy/ffmpeg-policy.json"
readonly CONTAINER="$ROOT/Services/WALIMediaSandbox/Containerfile"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[[ -f "$PROCESS" && -f "$VERIFY" && -f "$POLICY" && -f "$CONTAINER" ]] || fail "sandbox sources missing"

grep -q 'libkvazaar' "$PROCESS" || fail "process-media must encode with libkvazaar"
grep -q 'yuv420p10le' "$PROCESS" || fail "process-media must produce 10-bit 4:2:0"
grep -q 'scale=min(7680' "$PROCESS" || fail "process-media must keep up to 8K long edge"
grep -q 'kvazaar-params preset=medium,qp=' "$PROCESS" || fail "process-media must pass comma-separated Kvazaar quality params"
if grep -q 'libopenh264' "$PROCESS"; then
  fail "process-media must not use OpenH264 for catalog video"
fi
if grep -q -- '-b:v 8000k' "$PROCESS"; then
  fail "process-media must not use a fixed 8 Mbps conferencing bitrate"
fi
if grep -q 'VIDEO_FILTER=".*scale=min(1920' "$PROCESS"; then
  fail "process-media must not force video_default down to 1080p"
fi
grep -q 'PREVIEW_FILTER=".*scale=min(1920' "$PROCESS" || fail "preview must use a 1920 long-edge HEVC rung"
grep -q 'fps=60' "$PROCESS" || fail "process-media must cap playback at 60 fps"

grep -q 'libkvazaar' "$POLICY" || fail "ffmpeg-policy encoder must be libkvazaar"
python3 - "$POLICY" <<'PY' || fail "ffmpeg-policy canonical codec/pixel mismatch"
import json, sys
policy = json.load(open(sys.argv[1]))
canonical = policy["canonical"]
assert canonical["video_codec"] == "hevc", canonical
assert canonical["video_encoder"] == "libkvazaar"
assert canonical["pixel_format"] == "yuv420p10le"
PY

grep -q 'hevc' "$VERIFY" || fail "verify-media must expect HEVC catalog video"
grep -q 'yuv420p10le' "$VERIFY" || fail "verify-media must require 10-bit pixel format"
if grep -q 'video-default.mp4 video/mp4 h264' "$VERIFY"; then
  fail "verify-media still expects H.264 video_default"
fi

grep -q -- '--disable-gpl' "$CONTAINER" || fail "sandbox FFmpeg must remain non-GPL"
grep -q -- '--disable-nonfree' "$CONTAINER" || fail "sandbox FFmpeg must remain nonfree-free"
grep -q -- '--enable-libkvazaar' "$CONTAINER" || fail "Containerfile must enable libkvazaar"
grep -q 'KVZ_BIT_DEPTH=10' "$CONTAINER" || fail "Containerfile must compile Kvazaar as 10-bit"
grep -q 'ffmpeg-7.1.2-libkvazaar-10bit.patch' "$CONTAINER" || fail "Containerfile must apply the 10-bit libkvazaar patch"
[[ -f "$ROOT/Services/WALIMediaSandbox/patches/ffmpeg-7.1.2-libkvazaar-10bit.patch" ]] || fail "FFmpeg 10-bit libkvazaar patch missing"
grep -q -- '--platform=linux/amd64' "$CONTAINER" || fail "sandbox image must be pinned to linux/amd64"
if grep -q -- '--enable-gpl' "$CONTAINER"; then
  fail "Containerfile must not enable GPL"
fi

echo "process-media encode contract passed"
