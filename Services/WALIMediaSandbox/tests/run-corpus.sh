#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

run_static_checks() {
  bash -n "$ROOT/bin/process-media" "$ROOT/bin/verify-media"
  python3 -m json.tool "$ROOT/policy/ffmpeg-policy.json" >/dev/null
  grep -q -- '--disable-network' "$ROOT/Containerfile"
  grep -q -- '--disable-gpl' "$ROOT/Containerfile"
  grep -q -- '--disable-nonfree' "$ROOT/Containerfile"
  grep -q -- 'WALI_POLICY_DIGEST' "$ROOT/bin/process-media"
  grep -q -- 'keys | sort' "$ROOT/bin/verify-media"
  grep -q -- 'relative_path' "$ROOT/bin/verify-media"
  if grep -R -n -E '(^|[[:space:]])eval([[:space:]]|$)|curl|wget|/bin/sh -c' "$ROOT/bin"; then
    echo "runtime scripts contain a forbidden dynamic execution or network primitive" >&2
    return 1
  fi
}

run_runtime_corpus() {
  : "${WALI_SANDBOX_IMAGE:?set WALI_SANDBOX_IMAGE to an immutable Podman digest or local Docker image ID}"
  local runtime="${WALI_CONTAINER_RUNTIME:-podman}"
  [[ "$runtime" == podman || "$runtime" == docker ]]
  command -v "$runtime" >/dev/null
  if [[ "$runtime" == podman ]]; then
    [[ "$WALI_SANDBOX_IMAGE" =~ @sha256:[a-f0-9]{64}$ ]]
  else
    [[ "$WALI_SANDBOX_IMAGE" =~ ^sha256:[a-f0-9]{64}$ ]]
    [[ "$(docker image inspect --format '{{.Id}}' "$WALI_SANDBOX_IMAGE")" == "$WALI_SANDBOX_IMAGE" ]]
  fi

  local work
  work="$(mktemp -d)"
  trap 'chmod -R u+rwX -- "$work" 2>/dev/null || true; rm -rf -- "$work"' RETURN
  mkdir -p "$work/input" "$work/output"
  printf '' >"$work/empty.mp4"
  printf '\x00\x00\x00\x20ftypisomtruncated' >"$work/truncated.mp4"
  printf '#!/bin/sh\necho not-media\n' >"$work/spoofed.mp4"
  ln -s /etc/passwd "$work/symlink.mp4"
  mkfifo "$work/fifo.mp4"

  local policy_digest fixture input_digest result container_name
  policy_digest="$(sha256sum "$ROOT/policy/ffmpeg-policy.json" | cut -d' ' -f1)"
  for fixture in empty.mp4 truncated.mp4 spoofed.mp4 symlink.mp4 fifo.mp4; do
    result="$work/result-${fixture%.mp4}"
    mkdir -p "$result/input" "$result/output"
    if [[ -f "$work/$fixture" && ! -L "$work/$fixture" ]]; then
      cp -- "$work/$fixture" "$result/input/source.bin"
      input_digest="$(sha256sum "$result/input/source.bin" | cut -d' ' -f1)"
    else
      ln -s -- "$work/$fixture" "$result/input/source.bin"
      input_digest="$(printf '0%.0s' {1..64})"
    fi
    container_name="wali-corpus-${fixture%.mp4}-$$"
    local -a identity_args
    if [[ "$runtime" == podman ]]; then
      identity_args=(--userns=keep-id)
    else
      identity_args=(--user="$(id -u):$(id -g)")
    fi
    if timeout 30s "$runtime" run --rm --name="$container_name" --network=none --read-only --cap-drop=ALL \
      --security-opt=no-new-privileges "${identity_args[@]}" \
      --pids-limit=64 --cpus=1 --memory=1g --memory-swap=1g \
      --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=67108864 \
      --mount="type=bind,src=$result/input,dst=/work/input,readonly" \
      --mount="type=bind,src=$result/output,dst=/work/output" \
      --env=WALI_POLICY_DIGEST="$policy_digest" \
      --env=WALI_ATTEMPT_ID=11111111-1111-4111-8111-111111111111 \
      --env=WALI_SUBMISSION_ID=22222222-2222-4222-8222-222222222222 \
      --env=WALI_GENERATION=1 --env=WALI_INPUT_DIGEST="$input_digest" \
      "$WALI_SANDBOX_IMAGE" /opt/wali/bin/process-media; then
      echo "hostile fixture unexpectedly succeeded: $fixture" >&2
      return 1
    fi
    test -f "$result/output/failure.json"
    test "$(find "$result/output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 1
  done

  if "$runtime" ps -a --format '{{.Names}}' | grep -q '^wali-corpus-'; then
    echo "corpus left a container behind" >&2
    return 1
  fi
  echo "runtime hostile corpus passed with $runtime"
}

run_static_checks
bash "$ROOT/../../Tests/Worker/process-media-encode-contract-tests.sh"
if [[ "${1:-}" == "--runtime" ]]; then
  run_runtime_corpus
else
  echo "static sandbox contract checks passed; runtime corpus requires --runtime and WALI_SANDBOX_IMAGE"
fi
