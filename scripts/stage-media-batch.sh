#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly POLICY="$SCRIPT_ROOT/Services/WALIMediaSandbox/policy/ffmpeg-policy.json"
readonly IMAGE_PATTERN='^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$'

usage() {
  echo 'usage: stage-media-batch.sh audit|process --source-dir DIR --staging-dir DIR --image IMAGE@sha256:DIGEST' >&2
}

fail() {
  echo "staging media batch failed: $1" >&2
  exit 65
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

file_bytes() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

title_for() {
  local name=$1 stem
  stem="${name%.mp4}"
  stem="$(printf '%s' "$stem" | sed -E 's/^[0-9a-fA-F]{10}_//; s/[-_]+/ /g; s/[[:space:]]+(live )?wallpaper([[:space:]]+(wallsflow|walsflow)[[:space:]]+com|[[:space:]]+free)?$//I')"
  printf '%s' "$stem" | awk '{for (i=1; i<=NF; i++) {$i=toupper(substr($i,1,1)) substr($i,2)}; print}'
}

container_common() {
  printf '%s\0' \
    run --rm --platform=linux/amd64 --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --user="$(id -u):$(id -g)" \
    --pids-limit=32 --cpus=1 --memory=1g --memory-swap=1g \
    --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=67108864
}

run_bounded_sandbox() {
	local seconds=$1 container_name=$2 log_file=$3
	shift 3
	set +e
	(
		ulimit -f 2048
		exec "$timeout_binary" --signal=TERM --kill-after=10s "${seconds}s" docker "$@"
	) >"$log_file" 2>&1
	local status=$?
	set -e
	if [[ "$status" -ne 0 ]]; then
		docker rm -f "$container_name" >/dev/null 2>&1 || true
	fi
	return "$status"
}

mode="${1:-}"
[[ "$mode" == audit || "$mode" == process ]] || { usage; exit 64; }
shift
source_dir=''
staging_dir=''
image=''
while (($# > 0)); do
  case "$1" in
    --source-dir) source_dir="${2:-}"; shift 2 ;;
    --staging-dir) staging_dir="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -d "$source_dir" && ! -L "$source_dir" ]] || fail 'source directory must be a real directory'
[[ -n "$staging_dir" && "$staging_dir" == /* && ! -e "$staging_dir" && ! -L "$staging_dir" ]] || fail 'staging target must be a new absolute path'
[[ "$image" =~ $IMAGE_PATTERN ]] || fail 'image must be an immutable named SHA-256 reference'
command -v docker >/dev/null 2>&1 || fail 'docker is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$POLICY" && ! -L "$POLICY" ]] || fail 'checked-in media policy is missing'

probe_timeout="${WALI_STAGE_PROBE_TIMEOUT_SECONDS:-60}"
[[ "$probe_timeout" =~ ^[1-9][0-9]{0,2}$ && "$probe_timeout" -le 120 ]] || fail 'probe timeout must be 1 through 120 seconds'
timeout_binary="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$timeout_binary" ]] || fail 'GNU timeout or gtimeout is required'

source_dir="$(cd -- "$source_dir" && pwd -P)"
staging_parent="${staging_dir%/*}"
staging_name="${staging_dir##*/}"
[[ -d "$staging_parent" && ! -L "$staging_parent" && "$staging_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || fail 'staging target parent or name is invalid'
staging_parent="$(cd -- "$staging_parent" && pwd -P)"
if git -C "$staging_parent" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail 'staging directory must be outside a Git worktree'
fi
staging_dir="$(mktemp -d "$staging_parent/$staging_name.XXXXXX")"
chmod 700 "$staging_dir"
[[ "$staging_dir" != "$source_dir" && "$staging_dir" != "$source_dir"/* ]] || fail 'staging directory must be separate from source media'

repo_digests="$(docker image inspect --format '{{json .RepoDigests}}' "$image")" || fail 'immutable image is not available'
jq -e --arg image "$image" 'type == "array" and index($image) != null' <<<"$repo_digests" >/dev/null || fail 'local image does not contain the exact approved repository digest'
actual_image_id="$(docker image inspect --format '{{.Id}}' "$image")" || fail 'local image config digest is unavailable'
[[ "$actual_image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'local image config digest is invalid'

mkdir -p -- "$staging_dir/probes"
chmod 700 "$staging_dir/probes"
item_root="$(mktemp -d "${TMPDIR:-/tmp}/wali-stage-items.XXXXXX")"
result_item_root=''
cleanup() {
  chmod -R u+rwX "$item_root" 2>/dev/null || true
  rm -rf -- "$item_root"
  if [[ -n "$result_item_root" ]]; then
    chmod -R u+rwX "$result_item_root" 2>/dev/null || true
    rm -rf -- "$result_item_root"
  fi
}
trap cleanup EXIT

source_count=0
while IFS= read -r -d '' media_file; do
  source_count=$((source_count + 1))
  ((source_count <= 100)) || fail 'source batch exceeds 100 files'
  [[ -f "$media_file" && ! -L "$media_file" ]] || fail 'source entry must be a regular non-symlink file'
  name="${media_file##*/}"
	[[ "$name" == *.mp4 && ${#name} -le 255 && "$media_file" != *','* && "$media_file" != *':'* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || fail 'source filename is invalid'
  source_digest="$(sha256_file "$media_file")"
  source_bytes="$(file_bytes "$media_file")"
  [[ "$source_digest" =~ ^[a-f0-9]{64}$ && "$source_bytes" =~ ^[1-9][0-9]*$ && "$source_bytes" -le 1073741824 ]] || fail 'source digest or size is invalid'

	probe="$staging_dir/probes/$source_digest.json"
	probe_temp="$(mktemp "$staging_dir/probes/.probe.XXXXXX")"
	container_name="wali-stage-probe-${source_digest:0:12}-$$"
	docker_args=()
	while IFS= read -r -d '' argument; do docker_args+=("$argument"); done < <(container_common)
	set +e
	(
		ulimit -f 1024
		exec "$timeout_binary" --signal=TERM --kill-after=5s "${probe_timeout}s" \
		docker "${docker_args[@]}" --name="$container_name" --mount="type=bind,src=$media_file,dst=/work/input/source.mp4,readonly" \
			"$image" /opt/ffmpeg/bin/ffprobe -v error -show_format -show_streams -of json /work/input/source.mp4
	) >"$probe_temp"
	probe_status=$?
	set -e
	if [[ "$probe_status" -ne 0 ]]; then
		docker rm -f "$container_name" >/dev/null 2>&1 || true
		unlink "$probe_temp" 2>/dev/null || true
		fail "sandbox probe rejected $name"
	fi
	probe_bytes="$(file_bytes "$probe_temp")"
	if [[ ! "$probe_bytes" =~ ^[1-9][0-9]*$ || "$probe_bytes" -gt 1048576 ]] || ! jq -e . "$probe_temp" >/dev/null; then
		unlink "$probe_temp" 2>/dev/null || true
		fail 'sandbox probe returned invalid or oversized JSON'
	fi
  mv -f -- "$probe_temp" "$probe"
  [[ "$(sha256_file "$media_file")" == "$source_digest" && "$(file_bytes "$media_file")" == "$source_bytes" ]] || fail 'source changed during inspection'

  route="$(jq -r --argjson source_bytes "$source_bytes" '
    ([.streams[] | select(.codec_type == "video")]) as $videos |
    ([.streams[] | select(.codec_type != "video")]) as $extras |
    ($videos[0].avg_frame_rate | split("/") | map(tonumber)) as $fps |
    (.format.tags.major_brand // "") as $brand |
    if (.streams | length) < 1 or (.streams | length) > 3 or ($videos | length) != 1 then "reject"
    elif ($extras | any(.codec_type != "audio" and .codec_type != "data")) then "reject"
    elif ($videos[0].codec_name != "h264" and $videos[0].codec_name != "hevc") then "reject"
    elif ($videos[0].width <= 0 or $videos[0].width > 7680 or $videos[0].height <= 0 or $videos[0].height > 4320) then "reject"
    elif ($fps | length) != 2 or $fps[1] <= 0 or ($fps[0] / $fps[1]) > 120 then "reject"
    elif ((.format.duration | tonumber) <= 0 or (.format.duration | tonumber) > 600) then "reject"
    elif (.format.size | tonumber) != $source_bytes then "reject"
    elif (["isom","iso2","mp41","mp42","avc1","M4V","qt  "] | index($brand)) == null then "reject"
    elif ($extras | length) == 0 then "direct_canonicalization"
    else "normalize_then_canonicalize" end
  ' "$probe")"
  stream_types="$(jq -c '[.streams[].codec_type]' "$probe")"
  safe_code=ok
  eligible=true
  if [[ "$route" == reject ]]; then safe_code=intake_policy_rejected; eligible=false; fi
  title="$(title_for "$name")"
  jq -S -n --arg file_name "$name" --arg title "$title" --arg source_digest "$source_digest" \
    --argjson source_bytes "$source_bytes" --arg probe_digest "$(sha256_file "$probe")" --arg route "$route" \
    --arg safe_code "$safe_code" --argjson eligible "$eligible" --argjson stream_types "$stream_types" --slurpfile probe "$probe" '
    {file_name:$file_name,title:$title,source_digest:$source_digest,source_bytes:$source_bytes,
     probe_digest:$probe_digest,container_brand:($probe[0].format.tags.major_brand // "unknown"),
     duration_ms:(($probe[0].format.duration | tonumber) * 1000 | floor),
     video:([ $probe[0].streams[] | select(.codec_type == "video") ][0] |
       {codec:.codec_name,width:.width,height:.height,frame_rate:.avg_frame_rate}),
     stream_types:$stream_types,route:$route,eligible_for_private_processing:$eligible,safe_code:$safe_code,
     rights_status:"third_party_unverified",publication_allowed:false,wali_ownership_claimed:false}
  ' >"$item_root/$(printf '%03d' "$source_count").json"
done < <(find "$source_dir" -maxdepth 1 -type f -iname '*.mp4' -print0)

((source_count > 0)) || fail 'source directory contains no MP4 files'
policy_digest="$(sha256_file "$POLICY")"
manifest_temp="$(mktemp "$staging_dir/.intake-manifest.XXXXXX")"
jq -S -s --arg image "$image" --arg image_id "$actual_image_id" --arg policy_digest "$policy_digest" '
  sort_by(.file_name) as $items |
  {schema_version:1,batch_status:"staging_only",rights_status:"third_party_unverified",
   publication_allowed:false,wali_ownership_claimed:false,media_image:$image,media_image_id:$image_id,
   media_policy_digest:$policy_digest,source_count:($items|length),
   direct_count:([$items[]|select(.route=="direct_canonicalization")]|length),
   normalization_count:([$items[]|select(.route=="normalize_then_canonicalize")]|length),
   rejected_count:([$items[]|select(.route=="reject")]|length),items:$items}
' "$item_root"/*.json >"$manifest_temp"
mv -f -- "$manifest_temp" "$staging_dir/intake-manifest.json"
digest_temp="$(mktemp "$staging_dir/.intake-digest.XXXXXX")"
sha256_file "$staging_dir/intake-manifest.json" >"$digest_temp"
mv -f -- "$digest_temp" "$staging_dir/intake-manifest.sha256"
chmod 600 "$staging_dir/intake-manifest.json" "$staging_dir/intake-manifest.sha256" "$staging_dir"/probes/*.json

if [[ "$mode" == audit ]]; then
	echo "staging audit complete: $source_count sources; manifest $staging_dir/intake-manifest.json"
	exit
fi

mkdir -p "$staging_dir/normalized" "$staging_dir/candidates" "$staging_dir/logs"
chmod 700 "$staging_dir/normalized" "$staging_dir/candidates" "$staging_dir/logs"
result_item_root="$(mktemp -d "${TMPDIR:-/tmp}/wali-stage-results.XXXXXX")"
result_index=0
while IFS= read -r item; do
	result_index=$((result_index + 1))
	file_name="$(jq -er '.file_name' <<<"$item")"
	source_digest="$(jq -er '.source_digest' <<<"$item")"
	route="$(jq -er '.route' <<<"$item")"
	media_file="$source_dir/$file_name"
	result_path="$result_item_root/$(printf '%03d' "$result_index").json"
	if [[ "$route" == reject ]]; then
		jq -S -n --argjson item "$item" '$item + {status:"failed",safe_code:"intake_policy_rejected",normalization_applied:false}' >"$result_path"
		continue
	fi
	if [[ ! -f "$media_file" || -L "$media_file" || "$(sha256_file "$media_file")" != "$source_digest" ]]; then
		jq -S -n --argjson item "$item" '$item + {status:"failed",safe_code:"source_changed",normalization_applied:false}' >"$result_path"
		continue
	fi

	processing_input="$media_file"
	normalization_applied=false
	if [[ "$route" == normalize_then_canonicalize ]]; then
		normalization_applied=true
		normalized_directory="$staging_dir/normalized/$source_digest"
		mkdir "$normalized_directory"
		chmod 700 "$normalized_directory"
		normalize_log="$(mktemp "$staging_dir/logs/.normalize.XXXXXX")"
		normalize_name="wali-stage-normalize-${source_digest:0:12}-$$"
		if ! run_bounded_sandbox 900 "$normalize_name" "$normalize_log" \
			run --rm --name="$normalize_name" --platform=linux/amd64 --network=none --read-only --cap-drop=ALL \
			--security-opt=no-new-privileges --user="$(id -u):$(id -g)" --pids-limit=64 --cpus=2 --memory=8g --memory-swap=8g \
			--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=536870912 \
			--mount="type=bind,src=$media_file,dst=/work/input/source.bin,readonly" \
			--mount="type=bind,src=$normalized_directory,dst=/work/output" \
			"$image" /opt/ffmpeg/bin/ffmpeg -nostdin -hide_banner -loglevel error -i /work/input/source.bin \
			-map 0:v:0 -an -sn -dn -map_metadata -1 -map_chapters -1 \
			-c:v copy \
			-movflags +faststart -y /work/output/source.mp4; then
			mv -f "$normalize_log" "$staging_dir/logs/$source_digest-normalize.log"
			jq -S -n --argjson item "$item" '$item + {status:"failed",safe_code:"normalization_failed",normalization_applied:true}' >"$result_path"
			continue
		fi
		mv -f "$normalize_log" "$staging_dir/logs/$source_digest-normalize.log"
		processing_input="$normalized_directory/source.mp4"
		if [[ ! -f "$processing_input" || -L "$processing_input" ]]; then
			jq -S -n --argjson item "$item" '$item + {status:"failed",safe_code:"normalized_output_missing",normalization_applied:true}' >"$result_path"
			continue
		fi
		normalized_bytes="$(file_bytes "$processing_input")"
		if [[ ! "$normalized_bytes" =~ ^[1-9][0-9]*$ || "$normalized_bytes" -gt 1073741824 || "$(sha256_file "$media_file")" != "$source_digest" ]]; then
			jq -S -n --argjson item "$item" '$item + {status:"failed",safe_code:"normalized_output_invalid",normalization_applied:true}' >"$result_path"
			continue
		fi
	fi

	processing_digest="$(sha256_file "$processing_input")"
	attempt_id="batch-${source_digest:0:24}"
	submission_id="unverified-${source_digest:0:24}"
	candidate_directory="$staging_dir/candidates/$source_digest"
	media_directory="$candidate_directory/media"
	verification_directory="$candidate_directory/verification"
	mkdir -p "$media_directory" "$verification_directory"
	chmod 700 "$candidate_directory" "$media_directory" "$verification_directory"
	process_log="$(mktemp "$staging_dir/logs/.process.XXXXXX")"
	process_name="wali-stage-process-${source_digest:0:12}-$$"
	if ! run_bounded_sandbox 1800 "$process_name" "$process_log" \
		run --rm --name="$process_name" --platform=linux/amd64 --network=none --read-only --cap-drop=ALL \
		--security-opt=no-new-privileges --user="$(id -u):$(id -g)" --pids-limit=64 --cpus=2 --memory=8g --memory-swap=8g \
		--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=536870912 \
		--mount="type=bind,src=$processing_input,dst=/work/input/source.bin,readonly" \
		--mount="type=bind,src=$media_directory,dst=/work/output" \
		--env=WALI_POLICY_DIGEST="$policy_digest" --env=WALI_ATTEMPT_ID="$attempt_id" \
		--env=WALI_SUBMISSION_ID="$submission_id" --env=WALI_GENERATION=1 --env=WALI_INPUT_DIGEST="$processing_digest" \
		"$image" /opt/wali/bin/process-media; then
		mv -f "$process_log" "$staging_dir/logs/$source_digest-process.log"
		jq -S -n --argjson item "$item" --argjson normalized "$normalization_applied" '$item + {status:"failed",safe_code:"canonicalization_failed",normalization_applied:$normalized}' >"$result_path"
		continue
	fi
	mv -f "$process_log" "$staging_dir/logs/$source_digest-process.log"
	media_claim="$media_directory/media-claim.json"
	if [[ ! -f "$media_claim" || -L "$media_claim" || "$(file_bytes "$media_claim")" -gt 1048576 ]] || ! jq -e \
		--arg attempt_id "$attempt_id" --arg submission_id "$submission_id" --arg input_digest "$processing_digest" --arg policy_digest "$policy_digest" '
		.schema_version == 1 and .kind == "media" and .safe_code == "ok" and
		.attempt_id == $attempt_id and .submission_id == $submission_id and .generation == 1 and
		.input_digest == $input_digest and .policy_digest == $policy_digest and
		(.artifacts | length) == 4 and ([.artifacts[].role] | sort) == ["poster","preview","thumbnail","video_default"] and
		(all(.artifacts[]; .has_audio == false)) and (.sample_frames | length) == 7
	' "$media_claim" >/dev/null; then
		jq -S -n --argjson item "$item" --argjson normalized "$normalization_applied" '$item + {status:"failed",safe_code:"media_claim_invalid",normalization_applied:$normalized}' >"$result_path"
		continue
	fi

	verify_log="$(mktemp "$staging_dir/logs/.verify.XXXXXX")"
	verify_name="wali-stage-verify-${source_digest:0:12}-$$"
	if ! run_bounded_sandbox 600 "$verify_name" "$verify_log" \
		run --rm --name="$verify_name" --platform=linux/amd64 --network=none --read-only --cap-drop=ALL \
		--security-opt=no-new-privileges --user="$(id -u):$(id -g)" --pids-limit=64 --cpus=1 --memory=2g --memory-swap=2g \
		--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=134217728 \
		--mount="type=bind,src=$media_directory,dst=/work/input,readonly" \
		--mount="type=bind,src=$verification_directory,dst=/work/output" \
		--env=WALI_POLICY_DIGEST="$policy_digest" --env=WALI_ATTEMPT_ID="$attempt_id" \
		--env=WALI_SUBMISSION_ID="$submission_id" --env=WALI_GENERATION=1 --env=WALI_INPUT_DIGEST="$processing_digest" \
		"$image" /opt/wali/bin/verify-media; then
		mv -f "$verify_log" "$staging_dir/logs/$source_digest-verify.log"
		jq -S -n --argjson item "$item" --argjson normalized "$normalization_applied" '$item + {status:"failed",safe_code:"verification_failed",normalization_applied:$normalized}' >"$result_path"
		continue
	fi
	mv -f "$verify_log" "$staging_dir/logs/$source_digest-verify.log"
	verification_claim="$verification_directory/verification-claim.json"
	if [[ ! -f "$verification_claim" || -L "$verification_claim" || "$(file_bytes "$verification_claim")" -gt 1048576 ]] || ! jq -e \
		--arg attempt_id "$attempt_id" --arg submission_id "$submission_id" --arg input_digest "$processing_digest" --arg policy_digest "$policy_digest" '
		.schema_version == 1 and .kind == "verification" and .safe_code == "ok" and
		.attempt_id == $attempt_id and .submission_id == $submission_id and .generation == 1 and
		.input_digest == $input_digest and .policy_digest == $policy_digest and
		(.artifacts | length) == 4 and ([.artifacts[].role] | sort) == ["poster","preview","thumbnail","video_default"] and
		(all(.artifacts[]; .has_audio == false))
	' "$verification_claim" >/dev/null; then
		jq -S -n --argjson item "$item" --argjson normalized "$normalization_applied" '$item + {status:"failed",safe_code:"verification_claim_invalid",normalization_applied:$normalized}' >"$result_path"
		continue
	fi

	jq -S -n --argjson item "$item" --argjson normalized "$normalization_applied" --arg processing_input_digest "$processing_digest" \
		--arg media_claim_digest "$(sha256_file "$media_claim")" --arg verification_claim_digest "$(sha256_file "$verification_claim")" \
		--slurpfile claim "$media_claim" '
		$item + {status:"verified_private_candidate",safe_code:"ok",normalization_applied:$normalized,
		 processing_input_digest:$processing_input_digest,media_claim_digest:$media_claim_digest,
		 verification_claim_digest:$verification_claim_digest,artifacts:$claim[0].artifacts}
	' >"$result_path"
done < <(jq -c '.items[]' "$staging_dir/intake-manifest.json")

results_temp="$(mktemp "$staging_dir/.processing-results.XXXXXX")"
jq -S -s --arg image "$image" --arg policy_digest "$policy_digest" '
	sort_by(.file_name) as $results |
	([$results[] | select(.status == "verified_private_candidate")] | length) as $verified |
	{schema_version:1,batch_status:(if $verified == ($results|length) then "verified_private_candidates" else "partial_failure" end),
	 rights_status:"third_party_unverified",publication_allowed:false,wali_ownership_claimed:false,
	 media_image:$image,media_policy_digest:$policy_digest,source_count:($results|length),verified_count:$verified,
	 failed_count:(($results|length)-$verified),results:$results}
' "$result_item_root"/*.json >"$results_temp"
mv -f "$results_temp" "$staging_dir/processing-results.json"
results_digest_temp="$(mktemp "$staging_dir/.processing-digest.XXXXXX")"
sha256_file "$staging_dir/processing-results.json" >"$results_digest_temp"
mv -f "$results_digest_temp" "$staging_dir/processing-results.sha256"
chmod 600 "$staging_dir/processing-results.json" "$staging_dir/processing-results.sha256" "$result_item_root"/*.json "$staging_dir"/logs/*

verified_count="$(jq -r '.verified_count' "$staging_dir/processing-results.json")"
failed_count="$(jq -r '.failed_count' "$staging_dir/processing-results.json")"
echo "staging processing complete: $verified_count verified private candidates, $failed_count failures; results $staging_dir/processing-results.json"
[[ "$failed_count" -eq 0 ]]
