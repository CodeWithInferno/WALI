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

verify_database_ca() {
  local ca=/etc/wali-worker/database-ca.crt base=/opt/wali-worker current payload count
  count="$(grep -c -E '^[[:space:]]*PGSSLROOTCERT[[:space:]]*=' "$ENV_FILE" || true)"
  if [[ "$count" != 0 ]]; then
    [[ "$count" == 1 ]] && grep -qxF "PGSSLROOTCERT=$ca" "$ENV_FILE" ||
      fail 'database CA environment binding is invalid'
  fi
  current="$(readlink "$base/current")" || fail 'database CA release link is missing'
  [[ "$current" =~ ^releases/[a-f0-9]{64}$ ]] || fail 'database CA release link is invalid'
  payload="$base/$current/payload"
  [[ -d "$payload" && ! -L "$payload" && "$(stat -c '%U:%G:%a' "$payload")" == root:root:700 ]] ||
    fail 'database CA snapshot directory is unsafe'
  if [[ -e "$payload/database-ca" || -L "$payload/database-ca" ]]; then
    [[ "$count" == 1 && ! -e "$payload/database-ca.absent" && ! -L "$payload/database-ca.absent" ]] ||
      fail 'database CA snapshot binding is incomplete'
    [[ -f "$payload/database-ca" && ! -L "$payload/database-ca" && "$(stat -c '%U:%G:%a' "$payload/database-ca")" == root:root:400 ]] ||
      fail 'database CA snapshot file is unsafe'
    [[ -f "$ca" && ! -L "$ca" && "$(stat -c '%U:%G:%a' "$ca")" == root:root:444 ]] ||
      fail 'database CA ownership/mode is not root:root 0444'
    cmp -s "$payload/database-ca" "$ca" || fail 'database CA differs from the installed release snapshot'
  else
    if [[ -e "$payload/database-ca.absent" || -L "$payload/database-ca.absent" ]]; then
      [[ -f "$payload/database-ca.absent" && ! -L "$payload/database-ca.absent" && ! -s "$payload/database-ca.absent" ]] ||
        fail 'database CA absence marker is invalid'
    fi
    [[ "$count" == 0 && ! -e "$ca" && ! -L "$ca" ]] || fail 'unexpected or missing managed database CA'
  fi
}

[[ "$(id -u)" == 0 ]] || fail 'run as root'
id wali-worker >/dev/null 2>&1 || fail 'dedicated identity missing'
if id -nG wali-worker | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker|adm)$'; then fail 'worker has a privileged group'; fi
[[ "$(stat -c '%U:%G:%a' "$ENV_FILE")" == root:wali-worker:640 ]] || fail 'environment ownership/mode is not root:wali-worker 0640'
verify_database_ca
[[ "$(stat -c '%U:%G:%a' /var/lib/wali-worker/attempts)" == wali-worker:wali-worker:700 ]] || fail 'scratch ownership/mode is incorrect'
systemctl is-active --quiet "$UNIT" || fail 'worker service is not active'

for property in 'User=wali-worker' 'Group=wali-worker' 'ProtectSystem=strict' 'PrivateDevices=yes' 'Delegate=yes' 'MemoryMax=6442450944' 'TasksMax=256'; do
  [[ "$(systemctl show "$UNIT" --property="${property%%=*}" --value)" == "${property#*=}" ]] || fail "unit property ${property} is not active"
done
pid="$(systemctl show -p MainPID --value "$UNIT")"
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'worker MainPID is invalid'
if ss -ltnup | grep -q "pid=$pid,"; then fail 'worker opened a TCP or UDP listener'; fi

health_socket="$(read_env_value WALI_HEALTH_SOCKET)" || fail 'health socket setting missing'
[[ "$health_socket" == /run/wali-media-worker/health.sock ]] || fail 'health Unix socket path is invalid'
readiness_deadline=$((SECONDS + 30))
while [[ ! -S "$health_socket" ]] || [[ "$(curl --silent --fail --max-time 2 --unix-socket "$health_socket" http://localhost/healthz 2>/dev/null || true)" != '{"status":"ok"}' ]]; do
  ((SECONDS < readiness_deadline)) || fail 'database role/queue readiness timed out'
  systemctl is-active --quiet "$UNIT" || fail 'worker stopped during readiness verification'
  sleep 1
done
metrics="$(curl --silent --show-error --fail --unix-socket "$health_socket" http://localhost/metrics)"
grep -q '^wali_worker_jobs_total ' <<<"$metrics" || fail 'aggregate metrics missing'
while IFS= read -r metric; do
  [[ "$metric" =~ ^\#\ TYPE\ wali_worker_(jobs_total|job_duration_seconds_total|jobs_by_safe_code_total)\ counter$ ||
     "$metric" =~ ^wali_worker_jobs_total\ [0-9]+$ ||
     "$metric" =~ ^wali_worker_job_duration_seconds_total\ [0-9]+\.[0-9]{6}$ ||
     "$metric" =~ ^wali_worker_jobs_by_safe_code_total\{safe_code=\"[a-z][a-z0-9_]{0,63}\"\}\ [0-9]+$ ]] || fail 'metrics violate the aggregate-only schema'
done <<<"$metrics"

# Standalone, idempotent and recovery verification may start in a private cwd.
cd /var/lib/wali-worker
runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman info --format '{{.Host.Security.Rootless}}' | grep -qx true || fail 'Podman is not rootless'
for key in WALI_MEDIA_IMAGE WALI_VERIFIER_IMAGE; do
  image="$(read_env_value "$key")" || fail "$key missing"
  [[ "$image" =~ $IMAGE_PATTERN ]] || fail "$key is mutable"
  runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman image inspect "$image" >/dev/null || fail "$key is not present"
done
classifier_image="$(read_optional_env_value WALI_CLASSIFIER_IMAGE)" || fail 'WALI_CLASSIFIER_IMAGE missing'
if [[ -n "$classifier_image" ]]; then
  [[ "$classifier_image" =~ $IMAGE_PATTERN ]] || fail 'WALI_CLASSIFIER_IMAGE is mutable'
  runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman image inspect "$classifier_image" >/dev/null || fail 'WALI_CLASSIFIER_IMAGE is not present'
  classifier_label() {
    runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf \
      podman image inspect --format "{{ index .Labels \"$1\" }}" "$classifier_image"
  }
  [[ "$(classifier_label com.wali.classifier.production)" == true ]] || fail 'classifier image is not a verified production build'
  [[ "$(classifier_label com.wali.classifier.model-id)" == google/siglip-base-patch16-224 ]] || fail 'classifier model ID differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.model-revision)" == 7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed ]] || fail 'classifier model revision differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.model-digest)" == 2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877 ]] || fail 'classifier model digest differs from the reviewed contract'
  [[ "$(classifier_label com.wali.classifier.taxonomy-revision)" == wali-taxonomy-v1 ]] || fail 'classifier taxonomy differs from the reviewed contract'
fi

if runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman ps -a --filter status=exited --format '{{.Names}}' | grep -q '^wali-'; then
  fail 'a stopped WALI sandbox remains'
fi
if find /var/lib/wali-worker/attempts -mindepth 1 -maxdepth 1 -mmin +30 -print -quit | grep -q .; then fail 'stale scratch directory exists'; fi

$quick && { echo 'WALI worker quick verification passed'; exit; }

media_image="$(read_env_value WALI_MEDIA_IMAGE)"
policy_digest="$(read_env_value WALI_MEDIA_POLICY_DIGEST)" || fail 'media policy digest missing'
[[ "$policy_digest" =~ ^[a-f0-9]{64}$ ]] || fail 'media policy digest invalid'
probe_root="$(mktemp -d /var/lib/wali-worker/attempts/verify.XXXXXX)"
classifier_root=
probe_name=
probe_log="$(mktemp /var/log/wali-worker-verification.XXXXXX)"
chmod 0600 "$probe_log"
cleanup_probes() {
  if [[ -n "$probe_name" ]]; then
    systemctl stop "$probe_name.service" >/dev/null 2>&1 || true
    runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman rm -f "$probe_name" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$probe_root"
  [[ -z "$classifier_root" ]] || rm -rf -- "$classifier_root"
  rm -f -- "$probe_log"
}
trap cleanup_probes EXIT

# Use the worker's delegated, hardened execution context. An SSH runuser shell
# has different cgroup and device permissions. No worker secrets enter this unit.
probe_properties=()
for property in User Group Delegate ProtectSystem ProtectHome PrivateTmp PrivateDevices PrivateMounts NoNewPrivileges RestrictSUIDSGID ProtectClock ProtectKernelLogs ProtectKernelModules ProtectKernelTunables ProtectProc ProcSubset LockPersonality SystemCallArchitectures MemoryDenyWriteExecute RemoveIPC RestrictRealtime RestrictAddressFamilies CapabilityBoundingSet AmbientCapabilities ReadWritePaths MemoryHigh MemoryMax TasksMax LimitNOFILE LimitNPROC; do
  probe_properties+=(--property="$property=$(systemctl show "$UNIT" --property="$property" --value)")
done
run_probe() {
  local root=$1 image=$2 expected=$3 command=${4:-} status safe_code failure
  probe_name="wali-verification-$(cat /proc/sys/kernel/random/uuid)"
  local args=(/usr/bin/podman run --rm --pull=never --network=none --read-only --cap-drop=ALL
    --security-opt=no-new-privileges --userns=keep-id
    --user="$(id -u wali-worker):$(id -g wali-worker)"
    --pids-limit=64 --cpus=2 --memory=4g --memory-swap=4g --name="$probe_name"
    --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=1073741824
    --mount="type=bind,src=$root/input,dst=/work/input,ro=true"
    --mount="type=bind,src=$root/output,dst=/work/output,rw=true"
    --env=WALI_POLICY_DIGEST="$policy_digest" --env=WALI_ATTEMPT_ID=verification
    --env=WALI_SUBMISSION_ID=verification --env=WALI_GENERATION=1
    --env=WALI_INPUT_DIGEST=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    --env=HOME=/nonexistent --env=TMPDIR=/tmp --env=HF_HUB_OFFLINE=1
    --env=TRANSFORMERS_OFFLINE=1 --env=HF_HUB_DISABLE_TELEMETRY=1 --env=DO_NOT_TRACK=1 "$image")
  [[ -z "$command" ]] || args+=("$command")
  set +e
  systemd-run --quiet --wait --pipe --collect --unit="$probe_name" "${probe_properties[@]}" \
    --property=Requires=wali-podman-namespace.service --property=After=wali-podman-namespace.service \
    --property=BindPaths=/dev/fuse --property='DeviceAllow=/dev/fuse rw' \
    --property=WorkingDirectory=/ --property=RuntimeMaxSec=45 --property=TimeoutStopSec=10 \
    --property=CPUQuota=250% --property=UMask=0077 \
    --setenv=HOME=/var/lib/wali-worker --setenv=XDG_RUNTIME_DIR=/run/wali-media-worker \
    --setenv=CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf "${args[@]}" 2>&1 | head -c 16384 > "$probe_log"
  status=${PIPESTATUS[0]}
  set -e
  failure="$root/output/failure.json"
  safe_code=missing
  if [[ -f "$failure" && ! -L "$failure" && "$(stat -c %s "$failure")" -le 4096 ]]; then
    safe_code="$(jq -er '.safe_code | select(type == "string" and test("^[a-z][a-z0-9_]{0,63}$"))' "$failure" 2>/dev/null || printf invalid)"
  fi
  printf 'sandbox rejection probe: exit=%s safe_code=%s input=%s output=%s\n' "$status" "$safe_code" "$(stat -c '%u:%g:%a' "$root/input")" "$(stat -c '%u:%g:%a' "$root/output")"
  if [[ "$status" != 64 || "$safe_code" != "$expected" ]]; then
    install -o root -g root -m 0600 "$probe_log" /var/log/wali-worker-verification-last.log
    fail 'sandbox startup or expected rejection failed; bounded root-only log: /var/log/wali-worker-verification-last.log'
  fi
  probe_name=
}
chown wali-worker:wali-worker "$probe_root"
install -d -o wali-worker -g wali-worker -m 0700 "$probe_root/input" "$probe_root/output"
install -o wali-worker -g wali-worker -m 0600 /dev/null "$probe_root/input/source.bin"
run_probe "$probe_root" "$media_image" input_too_large /opt/wali/bin/process-media
unlink "$probe_root/output/failure.json"
unlink "$probe_root/input/source.bin"
rmdir "$probe_root/output" "$probe_root/input" "$probe_root"

if [[ -n "$classifier_image" ]]; then
  classifier_root="$(mktemp -d /var/lib/wali-worker/attempts/classifier-verify.XXXXXX)"
  chown wali-worker:wali-worker "$classifier_root"
  install -d -o wali-worker -g wali-worker -m 0700 "$classifier_root/input" "$classifier_root/output"
  run_probe "$classifier_root" "$classifier_image" invalid_request
  unlink "$classifier_root/output/failure.json"
  rmdir "$classifier_root/output" "$classifier_root/input" "$classifier_root"
fi
echo 'WALI worker full verification passed'
