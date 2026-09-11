#!/usr/bin/env bash
# Sourced by deploy.sh. The receipt pin is supplied through an independently
# reviewed management channel; these checks do not authenticate arbitrary roots.
image_trust_fail() { echo "image verification: $1" >&2; return 65; }

validate_offline_trust() {
  local root=$1 receipt=$2 expected=$3 freshness=${4:-current} bytes receipt_bytes now
  [[ "$freshness" == current || "$freshness" == historical ]] || { image_trust_fail 'invalid freshness policy'; return 65; }
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { image_trust_fail 'invalid reviewed receipt SHA-256'; return 65; }
  [[ -f "$root" && ! -L "$root" && -s "$root" && -f "$receipt" && ! -L "$receipt" && -s "$receipt" ]] || {
    image_trust_fail 'trust inputs must be nonempty regular files'; return 65;
  }
  bytes=$(wc -c < "$root"); receipt_bytes=$(wc -c < "$receipt")
  ((bytes <= 1048576 && receipt_bytes <= 65536)) || { image_trust_fail 'trust input exceeds its bound'; return 65; }
  command -v jq >/dev/null || { image_trust_fail 'jq is required for offline trust validation'; return 69; }
  [[ "$(file_digest "$receipt")" == "$expected" ]] || { image_trust_fail 'receipt differs from its reviewed SHA-256'; return 65; }
  jq -e -s 'length == 1 and (.[0] | type == "object" and .mediaType == "application/vnd.dev.sigstore.trustedroot+json;version=0.1")' "$root" >/dev/null 2>&1 || {
    image_trust_fail 'invalid trusted-root document'; return 65;
  }
  now=$(date +%s)
  # Accept UTC Z or +00:00, including the export receipt's fractional seconds.
  # Round-trip the calendar fields because strptime can normalize invalid dates.
  jq -e -s --arg digest "$(file_digest "$root")" --argjson bytes "$bytes" --argjson now "$now" --arg freshness "$freshness" '
    def instant:
      if type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|\\+00:00)$") | not) then error("date") else . end |
      sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | . as $date |
      fromdateiso8601 | if strftime("%Y-%m-%dT%H:%M:%SZ") == $date then . else error("date") end;
    length == 1 and (.[0] |
      .verified_at as $verified | .freshness_valid_before as $deadline |
      ($verified | instant) as $start | ($deadline | instant) as $end |
      ([.metadata.root.expires, .metadata.timestamp.expires, .metadata.snapshot.expires, .metadata.targets.expires] | map(instant) | min) as $expires |
      .status == "authenticated-public-trust-exported" and
      .trusted_root.sha256 == $digest and .trusted_root.bytes == $bytes and
      .trusted_root.media_type == "application/vnd.dev.sigstore.trustedroot+json;version=0.1" and
      $start < $end and $end <= $expires and
      ($freshness == "historical" or ($start <= $now and $now < $end)))
  ' "$receipt" >/dev/null 2>&1 || { image_trust_fail 'trust receipt binding or freshness is invalid'; return 65; }
}

verify_worker_images() {
  local key=$1 root=$2 receipt=$3 expected=$4 image
  shift 4
  (($# >= 2 && $# <= 3)) || { image_trust_fail 'expected media, verifier and optional classifier'; return 65; }
  # Verify the entire set before the caller may pull or activate any image.
  for image in "$@"; do
    [[ "$image" =~ $IMAGE_PATTERN ]] || { image_trust_fail 'image is not an immutable named digest'; return 65; }
    if [[ -n "$root" || -n "$receipt" || -n "$expected" ]]; then
      validate_offline_trust "$root" "$receipt" "$expected" || return
      cosign verify --offline --new-bundle-format=false --trusted-root "$root" \
        --key "$key" --check-claims=true "$image" >/dev/null || return
      validate_offline_trust "$root" "$receipt" "$expected" || return
    else
      # Preserve the existing online/default Cosign policy and arguments.
      cosign verify --key "$key" "$image" >/dev/null || return
    fi
  done
}

snapshot_offline_trust() {
  local payload=$1 freshness=${2:-historical} key present=0 absent=0 missing=0
  local keys=(cosign-trust-root cosign-trust-receipt cosign-trust-receipt-digest)
  for key in "${keys[@]}"; do
    if [[ -e "$payload/$key" || -L "$payload/$key" ]]; then
      [[ -f "$payload/$key" && ! -L "$payload/$key" && ! -e "$payload/$key.absent" && ! -L "$payload/$key.absent" ]] || {
        image_trust_fail 'ambiguous snapshot trust input'; return 65;
      }
      present=$((present + 1))
    elif [[ -e "$payload/$key.absent" || -L "$payload/$key.absent" ]]; then
      [[ -f "$payload/$key.absent" && ! -L "$payload/$key.absent" && ! -s "$payload/$key.absent" ]] || {
        image_trust_fail 'invalid snapshot trust absence marker'; return 65;
      }
      absent=$((absent + 1))
    else
      missing=$((missing + 1))
    fi
  done
  # Old complete snapshots predate these optional fields. Do not rewrite them.
  ((missing == 3 || absent == 3)) && return 0
  ((present == 3)) || { image_trust_fail 'snapshot contains an incomplete trust set'; return 65; }
  [[ "$(wc -c < "$payload/cosign-trust-receipt-digest")" -eq 65 ]] || { image_trust_fail 'invalid snapshot receipt pin'; return 65; }
  cmp -s "$payload/cosign-trust-receipt-digest" <(printf '%s\n' "$(cat "$payload/cosign-trust-receipt-digest")") || {
    image_trust_fail 'noncanonical snapshot receipt pin'; return 65;
  }
  validate_offline_trust "$payload/cosign-trust-root" "$payload/cosign-trust-receipt" \
    "$(cat "$payload/cosign-trust-receipt-digest")" "$freshness"
}

verify_rollback_offline_images() {
  local payload=$1 media verifier classifier
  snapshot_offline_trust "$payload" current || return
  [[ -f "$payload/cosign-trust-root" ]] || return 0
  media=$(read_env_value WALI_MEDIA_IMAGE "$payload/environment") || return
  verifier=$(read_env_value WALI_VERIFIER_IMAGE "$payload/environment") || return
  classifier=$(read_optional_env_value WALI_CLASSIFIER_IMAGE "$payload/environment") || return
  local images=("$media" "$verifier")
  [[ -z "$classifier" ]] || images+=("$classifier")
  verify_worker_images "$payload/cosign" "$payload/cosign-trust-root" "$payload/cosign-trust-receipt" \
    "$(cat "$payload/cosign-trust-receipt-digest")" "${images[@]}"
}
