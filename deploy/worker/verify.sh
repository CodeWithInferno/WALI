#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly ENV_FILE=/etc/wali-worker/worker.env
readonly UNIT=wali-media-worker.service
readonly IMAGE_PATTERN='^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$'
quick=false
[[ "${1:-}" == --quick ]] && quick=true

read_env_value() {
  local key=$1 count value
  count="$(grep -c -E "^${key}=" "$ENV_FILE" || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n -E "s/^${key}=//p" "$ENV_FILE")"
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$value"
}

read_optional_env_value() {
  local key=$1 count value
  count="$(grep -c -E "^${key}=" "$ENV_FILE" || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n -E "s/^${key}=//p" "$ENV_FILE")"
  [[ ! "$value" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$value"
}

fail() { echo "verification failed: $1" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'run as root'
id wali-worker >/dev/null 2>&1 || fail 'dedicated identity missing'
if id -nG wali-worker | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker|adm)$'; then fail 'worker has a privileged group'; fi
[[ "$(stat -c '%U:%G:%a' "$ENV_FILE")" == root:wali-worker:640 ]] || fail 'environment ownership/mode is not root:wali-worker 0640'
[[ "$(stat -c '%U:%G:%a' /var/lib/wali-worker/attempts)" == wali-worker:wali-worker:700 ]] || fail 'scratch ownership/mode is incorrect'
systemctl is-active --quiet "$UNIT" || fail 'worker service is not active'

for property in 'User=wali-worker' 'Group=wali-worker' 'ProtectSystem=strict' 'PrivateDevices=yes' 'Delegate=yes' 'MemoryMax=6442450944' 'TasksMax=256'; do
  systemctl show "$UNIT" | grep -q "^${property}$" || fail "unit property ${property} is not active"
done
pid="$(systemctl show -p MainPID --value "$UNIT")"
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'worker MainPID is invalid'
if ss -ltnup | grep -q "pid=$pid,"; then fail 'worker opened a TCP or UDP listener'; fi

health_socket="$(read_env_value WALI_HEALTH_SOCKET)" || fail 'health socket setting missing'
[[ "$health_socket" == /run/wali-media-worker/health.sock && -S "$health_socket" ]] || fail 'health Unix socket missing'
[[ "$(curl --silent --show-error --fail --unix-socket "$health_socket" http://localhost/healthz)" == '{"status":"ok"}' ]] || fail 'database role/queue readiness failed'
metrics="$(curl --silent --show-error --fail --unix-socket "$health_socket" http://localhost/metrics)"
grep -q '^wali_worker_jobs_total ' <<<"$metrics" || fail 'aggregate metrics missing'
if grep -Eqi 'attempt|submission|database|token|secret|password' <<<"$metrics"; then fail 'metrics contain forbidden detail'; fi

runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman info --format '{{.Host.Security.Rootless}}' | grep -qx true || fail 'Podman is not rootless'
for key in WALI_MEDIA_IMAGE WALI_VERIFIER_IMAGE; do
  image="$(read_env_value "$key")" || fail "$key missing"
  [[ "$image" =~ $IMAGE_PATTERN ]] || fail "$key is mutable"
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman image inspect "$image" >/dev/null || fail "$key is not present"
done
classifier_image="$(read_optional_env_value WALI_CLASSIFIER_IMAGE)" || fail 'WALI_CLASSIFIER_IMAGE missing'
if [[ -n "$classifier_image" ]]; then
  [[ "$classifier_image" =~ $IMAGE_PATTERN ]] || fail 'WALI_CLASSIFIER_IMAGE is mutable'
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman image inspect "$classifier_image" >/dev/null || fail 'WALI_CLASSIFIER_IMAGE is not present'
  classifier_label() {
    runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf \
      podman image inspect --format "{{ index .Labels \"$1\" }}" "$classifier_image"
  }
  [[ "$(classifier_label com.wali.classifier.production)" == true ]] || fail 'classifier image is not a verified production build'
  [[ "$(classifier_label com.wali.classifier.model-id)" == google/siglip-base-patch16-224 ]] || fail 'classifier model ID differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.model-revision)" == 7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed ]] || fail 'classifier model revision differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.model-digest)" == 2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877 ]] || fail 'classifier model digest differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.taxonomy-revision)" == wali-taxonomy-v1 ]] || fail 'classifier taxonomy differs from the reviewed contract'
fi

if runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman ps -a --format '{{.Names}}' | grep -q '^wali-'; then
  fail 'a supposedly ephemeral WALI sandbox remains'
fi
if find /var/lib/wali-worker/attempts -mindepth 1 -maxdepth 1 -mmin +30 -print -quit | grep -q .; then fail 'stale scratch directory exists'; fi

$quick && { echo 'WALI worker quick verification passed'; exit; }

media_image="$(read_env_value WALI_MEDIA_IMAGE)"
policy_digest="$(read_env_value WALI_MEDIA_POLICY_DIGEST)" || fail 'media policy digest missing'
[[ "$policy_digest" =~ ^[a-f0-9]{64}$ ]] || fail 'media policy digest invalid'
probe_root="$(mktemp -d /var/lib/wali-worker/verify.XXXXXX)"
install -d -o wali-worker -g wali-worker -m 0700 "$probe_root/input" "$probe_root/output"
install -o wali-worker -g wali-worker -m 0600 /dev/null "$probe_root/input/source.bin"
set +e
runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman run --rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --pids-limit=64 --cpus=1 --memory=1g --memory-swap=1g --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=67108864 --mount="type=bind,src=$probe_root/input,dst=/work/input,ro=true" --mount="type=bind,src=$probe_root/output,dst=/work/output,rw=true" --env=WALI_POLICY_DIGEST="$policy_digest" --env=WALI_ATTEMPT_ID=verification --env=WALI_SUBMISSION_ID=verification --env=WALI_GENERATION=1 --env=WALI_INPUT_DIGEST=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "$media_image" /opt/wali/bin/process-media >/dev/null 2>&1
probe_status=$?
set -e
[[ "$probe_status" != 0 && "$(jq -r .safe_code "$probe_root/output/failure.json")" == input_too_large ]] || fail 'networkless decoder containment probe failed'
unlink "$probe_root/output/failure.json" "$probe_root/input/source.bin"
rmdir "$probe_root/output" "$probe_root/input" "$probe_root"

if [[ -n "$classifier_image" ]]; then
  classifier_root="$(mktemp -d /var/lib/wali-worker/classifier-verify.XXXXXX)"
  install -d -o wali-worker -g wali-worker -m 0700 "$classifier_root/input" "$classifier_root/output"
  set +e
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman run --rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --pids-limit=32 --cpus=1 --memory=1g --memory-swap=1g --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=67108864 --mount="type=bind,src=$classifier_root/input,dst=/work/input,ro=true" --mount="type=bind,src=$classifier_root/output,dst=/work/output,rw=true" "$classifier_image" >/dev/null 2>&1
  classifier_status=$?
  set -e
  [[ "$classifier_status" != 0 && "$(jq -r .safe_code "$classifier_root/output/failure.json")" == invalid_request ]] || fail 'networkless classifier containment probe failed'
  unlink "$classifier_root/output/failure.json"
  rmdir "$classifier_root/output" "$classifier_root/input" "$classifier_root"
fi
echo 'WALI worker full verification passed'
