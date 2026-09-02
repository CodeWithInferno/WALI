#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if [[ "${0##*/}" == docker ]]; then
  {
    printf 'docker'
    printf ' <%s>' "$@"
    printf '\n'
  } >>"$WALI_TEST_DOCKER_LOG"
  if [[ "${1:-} ${2:-}" == "rm -f" ]]; then exit 0; fi
  if [[ "$1 $2" == "image inspect" ]]; then
    if [[ "$*" == *RepoDigests* ]]; then
      printf '["registry.example.invalid/wali/media@sha256:%s"]\n' "$(printf 'a%.0s' {1..64})"
    else
      printf 'sha256:%s\n' "$(printf 'b%.0s' {1..64})"
    fi
    exit 0
  fi
  output_mount=''
  input_mount=''
  attempt_id=''
  submission_id=''
  generation=''
  input_digest=''
  policy_digest=''
  for argument in "$@"; do
    case "$argument" in
      --mount=type=bind,src=*,dst=/work/output*)
        output_mount="${argument#--mount=type=bind,src=}"
        output_mount="${output_mount%%,dst=/work/output*}"
        ;;
      --mount=type=bind,src=*,dst=/work/input*)
        input_mount="${argument#--mount=type=bind,src=}"
        input_mount="${input_mount%%,dst=/work/input*}"
        ;;
      --env=WALI_ATTEMPT_ID=*) attempt_id="${argument##*=}" ;;
      --env=WALI_SUBMISSION_ID=*) submission_id="${argument##*=}" ;;
      --env=WALI_GENERATION=*) generation="${argument##*=}" ;;
      --env=WALI_INPUT_DIGEST=*) input_digest="${argument##*=}" ;;
      --env=WALI_POLICY_DIGEST=*) policy_digest="${argument##*=}" ;;
    esac
  done
  if [[ "$*" == *'/opt/ffmpeg/bin/ffmpeg'* ]]; then
    printf 'normalized-video' >"$output_mount/source.mp4"
    exit 0
  fi
  if [[ "$*" == *'/opt/wali/bin/process-media'* ]]; then
    mkdir -p "$output_mount/artifacts" "$output_mount/frames"
    printf 'thumbnail' >"$output_mount/artifacts/thumbnail.jpg"
    printf 'poster' >"$output_mount/artifacts/poster.jpg"
    printf 'preview' >"$output_mount/artifacts/preview.mp4"
    printf 'video' >"$output_mount/artifacts/video-default.mp4"
    for ordinal in 1 2 3 4 5 6 7; do printf 'frame-%s' "$ordinal" >"$output_mount/frames/frame-$(printf '%03d' "$ordinal").jpg"; done
    jq -n --arg attempt_id "$attempt_id" --arg submission_id "$submission_id" --argjson generation "$generation" \
      --arg policy_digest "$policy_digest" --arg input_digest "$input_digest" '
      {schema_version:1,kind:"media",attempt_id:$attempt_id,submission_id:$submission_id,generation:$generation,
       policy_digest:$policy_digest,input_digest:$input_digest,safe_code:"ok",encoder_build:"test",
       artifacts:[{role:"thumbnail",has_audio:false},{role:"poster",has_audio:false},{role:"preview",has_audio:false},{role:"video_default",has_audio:false}],
       sample_frames:[range(1;8)|{ordinal:.}]}
    ' >"$output_mount/media-claim.json"
    exit 0
  fi
  if [[ "$*" == *'/opt/wali/bin/verify-media'* ]]; then
    jq '.kind = "verification"' "$input_mount/media-claim.json" >"$output_mount/verification-claim.json"
    exit 0
  fi
  case "$*" in
    *src=*hang.mp4,dst=/work/input/source.mp4*)
      sleep 5
      ;;
    *src=*flood.mp4,dst=/work/input/source.mp4*)
      head -c 2097152 /dev/zero | tr '\000' x
      ;;
    *src=*one.mp4,dst=/work/input/source.mp4*)
      printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30/1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"10.000000","size":"10","tags":{"major_brand":"isom"}}}'
      ;;
    *src=*two.mp4,dst=/work/input/source.mp4*)
      printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"avg_frame_rate":"60/1"},{"codec_type":"audio","codec_name":"aac"},{"codec_type":"data","codec_name":"tmcd"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"20.000000","size":"10","tags":{"major_brand":"qt  "}}}'
      ;;
    *) exit 90 ;;
  esac
  exit
fi

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly SCRIPT="$ROOT/scripts/stage-media-batch.sh"
readonly WORK="$(mktemp -d)"
readonly WORK_REAL="$(cd -- "$WORK" && pwd -P)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"' EXIT

test -x "$SCRIPT"
bash -n "$SCRIPT"

mkdir -p "$WORK/bin" "$WORK/source"
printf 'opaque-one' >"$WORK/source/one.mp4"
printf 'opaque-two' >"$WORK/source/two.mp4"
ln -s "$ROOT/Tests/Worker/staging-media-batch-tests.sh" "$WORK/bin/docker"

image="registry.example.invalid/wali/media@sha256:$(printf 'a%.0s' {1..64})"
test_mode="$(stat -f '%Lp' "$WORK")"
if PATH="$WORK/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" WALI_TEST_DOCKER_LOG="$WORK/docker.log" \
  "$SCRIPT" audit --source-dir "$WORK/source" --staging-dir "$WORK" --image "$image" >/dev/null 2>&1; then
  echo 'existing broad staging target was accepted' >&2
  exit 1
fi
test "$(stat -f '%Lp' "$WORK")" == "$test_mode"

PATH="$WORK/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" WALI_TEST_DOCKER_LOG="$WORK/docker.log" \
  "$SCRIPT" audit --source-dir "$WORK/source" --staging-dir "$WORK/staging" --image "$image"
staging_dir="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'staging.*' -print -quit)"
test -n "$staging_dir"

manifest="$staging_dir/intake-manifest.json"
test -f "$manifest"
jq -e '
  .schema_version == 1 and .batch_status == "staging_only" and
  .source_count == 2 and .rights_status == "third_party_unverified" and
  .publication_allowed == false and .wali_ownership_claimed == false and
  ([.items[].route] | sort) == ["direct_canonicalization","normalize_then_canonicalize"] and
  all(.items[]; .rights_status == "third_party_unverified" and .publication_allowed == false)
' "$manifest" >/dev/null
expected_digest="$(sha256sum "$manifest" | cut -d' ' -f1)"
test "$(cat "$staging_dir/intake-manifest.sha256")" == "$expected_digest"
test "$(grep -c -- '--network=none' "$WORK/docker.log")" -eq 2
test "$(grep -c -- '--read-only' "$WORK/docker.log")" -eq 2
test "$(grep -c -- '--cap-drop=ALL' "$WORK/docker.log")" -eq 2
test "$(grep -c -- '--security-opt=no-new-privileges' "$WORK/docker.log")" -eq 2
grep -Fq -- "--mount=type=bind,src=$WORK_REAL/source/one.mp4,dst=/work/input/source.mp4,readonly" "$WORK/docker.log"
grep -Fq -- "--mount=type=bind,src=$WORK_REAL/source/two.mp4,dst=/work/input/source.mp4,readonly" "$WORK/docker.log"

for hostile in hang flood; do
  mkdir -p "$WORK/$hostile-source"
  printf 'opaque-hostile' >"$WORK/$hostile-source/$hostile.mp4"
  set +e
  PATH="$WORK/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" WALI_TEST_DOCKER_LOG="$WORK/docker.log" \
    WALI_STAGE_PROBE_TIMEOUT_SECONDS=1 timeout 4s "$SCRIPT" audit \
      --source-dir "$WORK/$hostile-source" --staging-dir "$WORK/$hostile-staging" --image "$image" \
      >"$WORK/$hostile.stdout" 2>"$WORK/$hostile.stderr"
  status=$?
  set -e
  test "$status" -ne 0
  test "$status" -ne 124
  hostile_staging="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name "$hostile-staging.*" -print -quit)"
  test -n "$hostile_staging"
  test ! -f "$hostile_staging/intake-manifest.json"
  while IFS= read -r -d '' output_file; do
    test "$(stat -f '%z' "$output_file")" -le 1048576
  done < <(find "$hostile_staging" -type f -print0)
done

set +e
PATH="$WORK/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" WALI_TEST_DOCKER_LOG="$WORK/docker.log" \
  "$SCRIPT" process --source-dir "$WORK/source" --staging-dir "$WORK/process-staging" --image "$image"
process_status=$?
set -e
process_staging="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'process-staging.*' -print -quit)"
test -n "$process_staging"
if [[ "$process_status" -ne 0 ]]; then
  jq . "$process_staging/processing-results.json" >&2
  find "$process_staging/logs" -type f -maxdepth 1 -exec sh -c 'echo "--- $1" >&2; cat "$1" >&2' _ {} \;
  exit "$process_status"
fi
test "$(grep -c -F '</opt/ffmpeg/bin/ffmpeg>' "$WORK/docker.log")" -eq 1
normalization_command="$(grep -F '</opt/ffmpeg/bin/ffmpeg>' "$WORK/docker.log")"
grep -Fq '<-map> <0:v:0>' <<<"$normalization_command"
grep -Fq '<-an> <-sn> <-dn>' <<<"$normalization_command"
grep -Fq '<-map_metadata> <-1> <-map_chapters> <-1>' <<<"$normalization_command"
grep -Fq '<-c:v> <copy>' <<<"$normalization_command"
for forbidden_encoder_argument in '<-vf>' '<libopenh264>' '<-b:v>' '<-colorspace>' '<-color_primaries>' '<-color_trc>'; do
  if grep -Fq "$forbidden_encoder_argument" <<<"$normalization_command"; then
    echo "normalization performed forbidden pre-canonical encoding: $forbidden_encoder_argument" >&2
    exit 1
  fi
done
jq -e '
  .schema_version == 1 and .batch_status == "verified_private_candidates" and
  .source_count == 2 and .verified_count == 2 and .failed_count == 0 and
  .rights_status == "third_party_unverified" and .publication_allowed == false and
  ([.results[].normalization_applied] | sort) == [false,true] and
  all(.results[]; .status == "verified_private_candidate" and .publication_allowed == false)
' "$process_staging/processing-results.json" >/dev/null

echo 'staging media batch contract tests passed'
