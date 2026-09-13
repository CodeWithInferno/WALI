#!/usr/bin/env bash
# Sourced by deploy.sh after target and dedicated-host validation.
# Only these WALI-owned files participate; database and host networking do not.
readonly RELEASE_BASE=/opt/wali-worker
readonly TRANSACTION=/opt/wali-worker/.transaction
readonly DATABASE_CA_PATH=/etc/wali-worker/database-ca.crt
release_keys=(environment worker-unit namespace-unit storage verifier cosign media-runbook compromise-runbook cosign-trust-root cosign-trust-receipt cosign-trust-receipt-digest database-ca)
release_paths=(/etc/wali-worker/worker.env /etc/systemd/system/wali-media-worker.service /etc/systemd/system/wali-podman-namespace.service /etc/wali-worker/storage.conf /usr/local/sbin/wali-worker-verify /etc/wali-worker/cosign.pub /usr/share/doc/wali-worker/media-worker.md /usr/share/doc/wali-worker/worker-compromise.md /etc/wali-worker/cosign-trusted-root.json /etc/wali-worker/cosign-trust-receipt.json /etc/wali-worker/cosign-trust-receipt.sha256 "$DATABASE_CA_PATH")
release_modes=(0640 0644 0644 0644 0555 0444 0444 0444 0444 0444 0444 0444)
readonly SBOM_DIRECTORY=/usr/share/doc/wali-worker/sbom

release_fail() { echo "release transaction: $1" >&2; exit 65; }

# Opt-in repair deployment only: preserve the already active namespace. This
# never makes a cold host runnable and never changes namespace-unit privileges.
warm_namespace_mode=false
warm_namespace_identity=

warm_namespace_fingerprint() {
  local started unit_digest dropins
  [[ "$(systemctl show wali-podman-namespace.service -p ActiveState --value)" == active ]] || release_fail 'warm namespace is not active'
  [[ "$(systemctl show wali-podman-namespace.service -p SubState --value)" == exited ]] || release_fail 'warm namespace is not ready'
  dropins="$(systemctl show wali-podman-namespace.service -p DropInPaths --value)" || release_fail 'cannot inspect namespace drop-ins'
  [[ -z "$dropins" ]] || release_fail 'unexpected namespace drop-in'
  [[ "$(systemctl show wali-podman-namespace.service -p FragmentPath --value)" == /etc/systemd/system/wali-podman-namespace.service ]] || release_fail 'unexpected namespace unit path'
  [[ "$(systemctl show wali-podman-namespace.service -p PartOf --value)" == wali-media-worker.service ]] || release_fail 'unexpected namespace ownership'
  started="$(systemctl show wali-podman-namespace.service -p ExecMainStartTimestampMonotonic --value)"
  [[ "$started" =~ ^[1-9][0-9]*$ ]] || release_fail 'namespace start identity is missing'
  unit_digest="$(file_digest /etc/systemd/system/wali-podman-namespace.service)" || release_fail 'cannot hash namespace unit'
  [[ "$unit_digest" =~ ^[a-f0-9]{64}$ ]] || release_fail 'invalid namespace hash'
  printf '%s:%s\n' "$unit_digest" "$started"
}
assert_warm_namespace() {
  $warm_namespace_mode || return 0
  [[ -n "$warm_namespace_identity" && "$(warm_namespace_fingerprint)" == "$warm_namespace_identity" ]] || release_fail 'warm namespace identity changed; cold recovery is not authorized here'
}
validate_warm_release() {
  local target=$1 baseline=$2 names jobs dropins
  $warm_namespace_mode || return 0
  # Reuse the complete snapshot contract, with byte-identical namespace/storage.
  cmp -s "$RELEASE_BASE/$target/payload/namespace-unit" "$RELEASE_BASE/$baseline/payload/namespace-unit" || release_fail 'warm deployment cannot change namespace unit'
  cmp -s "$RELEASE_BASE/$target/payload/storage" "$RELEASE_BASE/$baseline/payload/storage" || release_fail 'warm deployment cannot change Podman storage'
  [[ "$(systemctl show wali-media-worker.service -p ActiveState --value)" == active ]] || release_fail 'warm deployment requires the existing active worker'
  dropins="$(systemctl show wali-media-worker.service -p DropInPaths --value)" || release_fail 'cannot inspect worker drop-ins'
  [[ -z "$dropins" ]] || release_fail 'unexpected worker drop-in'
  jobs="$(systemctl list-jobs --no-legend --no-pager)" || release_fail 'cannot inspect pending systemd jobs'
  [[ -z "$(awk '$2=="wali-media-worker.service" || $2=="wali-podman-namespace.service" {print $1}' <<<"$jobs")" ]] || release_fail 'WALI unit operation already pending'
  warm_namespace_identity="$(warm_namespace_fingerprint)"
  names="$(runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman ps --format '{{.Names}}')" || release_fail 'cannot inspect active sandbox state'
  if grep -q '^wali-' <<<"$names"; then release_fail 'active WALI sandbox prevents deployment'; fi
}
start_wali_worker() {
  if $warm_namespace_mode; then
    assert_warm_namespace
    systemctl --job-mode=ignore-requirements start wali-media-worker.service
    assert_warm_namespace
  else
    systemctl start wali-media-worker.service
  fi
}

validate_database_ca() {
  local environment=$1 ca=$2 count=0 bytes
  if [[ -e "$environment" || -L "$environment" ]]; then
    [[ -f "$environment" && ! -L "$environment" ]] || release_fail 'unsafe database CA environment'
    count="$(grep -c -E '^[[:space:]]*PGSSLROOTCERT[[:space:]]*=' "$environment" || true)"
  fi
  if [[ -z "$ca" ]]; then
    [[ "$count" == 0 ]] || release_fail 'PGSSLROOTCERT requires a managed database CA'
    return
  fi
  [[ "$count" == 1 ]] && grep -qxF "PGSSLROOTCERT=$DATABASE_CA_PATH" "$environment" ||
    release_fail 'database CA requires the exact managed PGSSLROOTCERT setting'
  [[ -f "$ca" && ! -L "$ca" && -s "$ca" ]] || release_fail 'database CA must be a nonempty regular public file'
  bytes=$(wc -c < "$ca")
  ((bytes <= 65536)) || release_fail 'database CA exceeds its 64 KiB bound'
  # Only public PEM certificates are accepted, never keys or other PEM objects.
  awk '
    { sub(/\r$/, "") }
    /^-----BEGIN CERTIFICATE-----$/ { if (inside) exit 1; inside=1; count++; next }
    /^-----END CERTIFICATE-----$/ { if (!inside) exit 1; inside=0; next }
    inside { if ($0 !~ /^[A-Za-z0-9+\/=]+$/) exit 1; next }
    /[^[:space:]]/ { exit 1 }
    END { if (inside || !count) exit 1 }
  ' "$ca" || release_fail 'database CA must contain only PEM certificates'
  command -v openssl >/dev/null || release_fail 'openssl is required to validate a database CA'
  openssl crl2pkcs7 -nocrl -certfile "$ca" -outform DER >/dev/null 2>&1 ||
    release_fail 'database CA contains an invalid certificate'
}

snapshot_database_ca() {
  local payload=$1 ca=
  if [[ -e "$payload/database-ca" || -L "$payload/database-ca" ]]; then
    [[ ! -e "$payload/database-ca.absent" && ! -L "$payload/database-ca.absent" ]] ||
      release_fail 'ambiguous snapshot database CA'
    ca="$payload/database-ca"
  elif [[ -e "$payload/database-ca.absent" || -L "$payload/database-ca.absent" ]]; then
    [[ -f "$payload/database-ca.absent" && ! -L "$payload/database-ca.absent" && ! -s "$payload/database-ca.absent" ]] ||
      release_fail 'invalid snapshot database CA absence marker'
  fi
  # Legacy snapshots have neither field, and may not refer to an unmanaged CA.
  validate_database_ca "$payload/environment" "$ca"
}

safe_tree() {
  [[ -d "$1" && ! -L "$1" && "$(stat -c %u "$1")" == 0 ]] || return 1
  [[ -z "$(find "$1" \( -type l -o ! -user root -o -perm /022 \) -print -quit)" ]] || return 1
  [[ -z "$(find "$1" ! -type d ! -type f -print -quit)" ]]
}
release_link() {
  local name=$1 value
  if [[ ! -e "$RELEASE_BASE/$name" && ! -L "$RELEASE_BASE/$name" ]]; then printf absent; return; fi
  [[ -L "$RELEASE_BASE/$name" ]] || release_fail "$name is not a release link"
  value="$(readlink "$RELEASE_BASE/$name")"
  [[ "$value" =~ ^releases/[a-f0-9]{64}$ ]] || release_fail "$name has an unsafe target"
  safe_tree "$RELEASE_BASE/$value" || release_fail "$name payload is not root-owned and immutable"
  printf '%s' "$value"
}
manifest() {
  (cd "$1" && find . -type f ! -path './manifest.sha256' -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}
validate_release() {
  local link=$1 root
  [[ "$link" =~ ^releases/[a-f0-9]{64}$ ]] || release_fail 'invalid snapshot target'
  root="$RELEASE_BASE/$link"
  safe_tree "$root" || release_fail 'unsafe snapshot ownership or file type'
  [[ -f "$root/manifest.sha256" && "$(file_digest "$root/manifest.sha256")" == "${link#releases/}" ]] || release_fail 'snapshot manifest identity mismatch'
  cmp -s <(manifest "$root") "$root/manifest.sha256" || release_fail 'snapshot contents changed'
  snapshot_offline_trust "$root/payload" historical || release_fail 'invalid snapshot trust inputs'
  snapshot_database_ca "$root/payload"
  if [[ -f "$root/payload/environment" ]]; then
    validate_target_binding "$(read_env_value WALI_DEPLOY_ENVIRONMENT "$root/payload/environment")" \
      "$(read_env_value WALI_SUPABASE_PROJECT_REF "$root/payload/environment")" \
      "$(read_env_value WALI_DATABASE_URL "$root/payload/environment")" \
      "$(read_env_value WALI_STORAGE_URL "$root/payload/environment")"
  fi
}
finish_snapshot() {
  local root=$1 identity target
  snapshot_offline_trust "$root/payload" historical || release_fail 'invalid snapshot trust inputs'
  snapshot_database_ca "$root/payload"
  find "$root" -type f -exec chmod 0400 {} +
  find "$root" -type d -exec chmod 0700 {} +
  [[ ! -f "$root/wali-media-worker" ]] || chmod 0555 "$root/wali-media-worker"
  chmod 0755 "$root"
  manifest "$root" > "$root/manifest.sha256"
  chmod 0400 "$root/manifest.sha256"
  identity="$(file_digest "$root/manifest.sha256")"
  target="releases/$identity"
  if [[ -e "$RELEASE_BASE/$target" ]]; then
    validate_release "$target"
    rm -rf -- "$root"
  else
    mv -T -- "$root" "$RELEASE_BASE/$target"
  fi
  staged_release="$target"
}
capture_baseline() {
  local root current index path key
  root="$(mktemp -d "$RELEASE_BASE/.snapshot.XXXXXX")"
  install -d -m 0700 "$root/payload"
  for index in "${!release_keys[@]}"; do
    path="${release_paths[$index]}"; key="${release_keys[$index]}"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" && ! -L "$path" && "$(stat -c %u "$path")" == 0 ]] || release_fail 'unsafe installed configuration'
      cp -- "$path" "$root/payload/$key"
    else
      touch "$root/payload/$key.absent"
    fi
  done
  if [[ -e "$SBOM_DIRECTORY" || -L "$SBOM_DIRECTORY" ]]; then
    safe_tree "$SBOM_DIRECTORY" || release_fail 'unsafe installed SBOM directory'
    cp -R -- "$SBOM_DIRECTORY" "$root/payload/sbom"
  else
    touch "$root/payload/sbom.absent"
  fi
  current="$(release_link current)"
  if [[ "$current" != absent ]]; then
    validate_file "$RELEASE_BASE/$current/wali-media-worker"
    cp -- "$RELEASE_BASE/$current/wali-media-worker" "$root/wali-media-worker"
  else
    touch "$root/binary.absent"
  fi
  finish_snapshot "$root"
}
stage_release() {
  local root
  root="$(mktemp -d "$RELEASE_BASE/.snapshot.XXXXXX")"
  install -d -m 0700 "$root/payload/sbom"
  cp -- "$worker_binary" "$root/wali-media-worker"
  cp -- "$environment_file" "$root/payload/environment"
  cp -- "$SCRIPT_ROOT/wali-media-worker.service" "$root/payload/worker-unit"
  cp -- "$SCRIPT_ROOT/wali-podman-namespace.service" "$root/payload/namespace-unit"
  cp -- "$SCRIPT_ROOT/storage.conf" "$root/payload/storage"
  cp -- "$SCRIPT_ROOT/verify.sh" "$root/payload/verifier"
  cp -- "$cosign_key" "$root/payload/cosign"
  if [[ -n "$database_ca" ]]; then
    cp -- "$database_ca" "$root/payload/database-ca"
  else
    touch "$root/payload/database-ca.absent"
  fi
  if [[ -n "$offline_trust_root" ]]; then
    cp -- "$offline_trust_root" "$root/payload/cosign-trust-root"
    cp -- "$offline_trust_receipt" "$root/payload/cosign-trust-receipt"
    printf '%s\n' "$offline_trust_receipt_sha256" > "$root/payload/cosign-trust-receipt-digest"
  else
    touch "$root/payload/cosign-trust-root.absent" "$root/payload/cosign-trust-receipt.absent" "$root/payload/cosign-trust-receipt-digest.absent"
  fi
  cp -- "$SCRIPT_ROOT/../../docs/runbooks/media-worker.md" "$root/payload/media-runbook"
  cp -- "$SCRIPT_ROOT/../../docs/runbooks/worker-compromise.md" "$root/payload/compromise-runbook"
  cp -- "$media_sbom" "$root/payload/sbom/${media_image##*@sha256:}.spdx.json"
  cp -- "$verifier_sbom" "$root/payload/sbom/${verifier_image##*@sha256:}.spdx.json"
  [[ -z "$classifier_image" ]] || cp -- "$classifier_sbom" "$root/payload/sbom/${classifier_image##*@sha256:}.spdx.json"
  finish_snapshot "$root"
}
set_release_link() {
  local name=$1 value=$2 temporary
  if [[ "$value" == absent ]]; then rm -f -- "$RELEASE_BASE/$name"; return; fi
  [[ "$value" =~ ^releases/[a-f0-9]{64}$ ]] || release_fail 'unsafe link replacement'
  temporary="$(mktemp -u "$RELEASE_BASE/.link.XXXXXXXX")"
  ln -s -- "$value" "$temporary"
  mv -Tf -- "$temporary" "$RELEASE_BASE/$name"
}
stop_wali_units() {
  if $warm_namespace_mode; then
    assert_warm_namespace
    systemctl --job-mode=ignore-requirements stop wali-media-worker.service
    assert_warm_namespace
    return
  fi
  local unit
  for unit in wali-media-worker.service wali-podman-namespace.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then systemctl stop "$unit"; fi
  done
}
validate_managed_units() {
  local unit
  for unit in wali-media-worker.service wali-podman-namespace.service; do
    if systemctl cat "$unit" >/dev/null 2>&1 && ! systemctl cat "$unit" | grep -q '^X-WALI-Managed=true$'; then
      release_fail 'service name is occupied by a non-WALI unit'
    fi
  done
}
install_snapshot() {
  local link=$1 root index path key temporary group
  validate_release "$link"
  root="$RELEASE_BASE/$link/payload"
  for index in "${!release_keys[@]}"; do
    path="${release_paths[$index]}"; key="${release_keys[$index]}"
    [[ ! -L "$path" ]] || release_fail 'installed configuration became a symlink'
    if [[ -f "$root/$key.absent" ]]; then rm -f -- "$path"; continue; fi
    # Optional trust files did not exist in legacy complete snapshots. Restoring
    # one must remove newer installed trust inputs, not retain stale policy.
    case "$key" in
      cosign-trust-root|cosign-trust-receipt|cosign-trust-receipt-digest|database-ca)
        if [[ ! -e "$root/$key" ]]; then rm -f -- "$path"; continue; fi ;;
    esac
    validate_file "$root/$key"
    install -d -o root -g root -m 0755 "$(dirname "$path")"
    group=root; [[ "$key" != environment ]] || group=wali-worker
    temporary="$(mktemp "$(dirname "$path")/.wali-install.XXXXXX")"
    install -o root -g "$group" -m "${release_modes[$index]}" "$root/$key" "$temporary"
    mv -Tf -- "$temporary" "$path"
  done
  # The dedicated SBOM directory is part of the snapshot, including absence.
  if [[ -e "$SBOM_DIRECTORY" || -L "$SBOM_DIRECTORY" ]]; then
    safe_tree "$SBOM_DIRECTORY" || release_fail 'unsafe installed SBOM directory'
    rm -rf -- "$SBOM_DIRECTORY"
  fi
  if [[ -d "$root/sbom" ]]; then
    cp -R -- "$root/sbom" "$SBOM_DIRECTORY"
    find "$SBOM_DIRECTORY" -type d -exec chmod 0755 {} +
    find "$SBOM_DIRECTORY" -type f -exec chmod 0444 {} +
  fi
  [[ ! -d /etc/wali-worker ]] || chown root:wali-worker /etc/wali-worker
  [[ ! -d /etc/wali-worker ]] || chmod 0750 /etc/wali-worker
}
begin_transaction() {
  local baseline=$1 root unit state
  [[ ! -e "$TRANSACTION" ]] || release_fail 'unfinished transaction requires recovery'
  root="$(mktemp -d "$RELEASE_BASE/.pending.XXXXXX")"
  printf '%s\n' "$baseline" > "$root/baseline"
  if $warm_namespace_mode; then
    printf '%s\n' "$warm_namespace_identity" > "$root/warm-namespace"
  fi
  release_link current > "$root/current"
  release_link previous > "$root/previous"
  for unit in wali-media-worker.service wali-podman-namespace.service; do
    state=inactive; systemctl is-active --quiet "$unit" && state=active
    printf '%s\n' "$state" > "$root/$unit.active"
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    case "$state" in enabled|disabled|static|not-found) ;; *) release_fail 'unsupported unit enablement state' ;; esac
    printf '%s\n' "$state" > "$root/$unit.enabled"
  done
  mv -T -- "$root" "$TRANSACTION"
  sync -f "$RELEASE_BASE"
}
finish_transaction() {
  local completed
  sync -f "$RELEASE_BASE"
  completed="$(mktemp -u "$RELEASE_BASE/.completed.XXXXXXXX")"
  mv -T -- "$TRANSACTION" "$completed"
  sync -f "$RELEASE_BASE"
  rm -rf -- "$completed" || echo 'committed transaction metadata retained for cleanup' >&2
}
restore_transaction() {
  local baseline unit state value
  safe_tree "$TRANSACTION" || release_fail 'unsafe pending transaction'
  baseline="$(cat "$TRANSACTION/baseline")"
  if [[ -f "$TRANSACTION/warm-namespace" ]]; then
    warm_namespace_mode=true
    warm_namespace_identity="$(cat "$TRANSACTION/warm-namespace")"
  fi
  validate_release "$baseline"
  stop_wali_units
  install_snapshot "$baseline"
  for name in current previous; do
    value="$(cat "$TRANSACTION/$name")"
    set_release_link "$name" "$value"
  done
  systemctl daemon-reload
  for unit in wali-podman-namespace.service wali-media-worker.service; do
    if $warm_namespace_mode && [[ "$unit" == wali-podman-namespace.service ]]; then assert_warm_namespace; continue; fi
    state="$(cat "$TRANSACTION/$unit.enabled")"
    if [[ "$state" == enabled ]]; then systemctl enable "$unit" >/dev/null; fi
    if [[ "$state" == disabled || "$state" == not-found ]]; then systemctl disable "$unit" >/dev/null 2>&1 || true; fi
    state="$(cat "$TRANSACTION/$unit.active")"
    if [[ "$state" == active ]]; then
      if [[ "$unit" == wali-media-worker.service ]]; then start_wali_worker; else systemctl start "$unit"; fi
    fi
  done
  if [[ "$(cat "$TRANSACTION/wali-media-worker.service.active")" == active ]]; then
    /usr/local/sbin/wali-worker-verify --quick || return 1
    assert_warm_namespace
  fi
  finish_transaction
}
transaction_failure() {
  local status=$?
  trap - EXIT ERR INT TERM
  echo 'activation failed; restoring the complete prior WALI deployment' >&2
  set +e
  (set -Eeuo pipefail; restore_transaction)
  local restored=$?
  set -e
  if ((restored != 0)); then
    if $warm_namespace_mode; then systemctl --job-mode=ignore-requirements stop wali-media-worker.service || true
    else systemctl stop wali-media-worker.service || true; fi
    echo 'recovery failed; worker stopped and pending transaction retained for operator recovery' >&2
  fi
  ((status != 0)) || status=1
  exit "$status"
}
activate_release() {
  local target=$1 baseline=$2
  validate_release "$target"
  validate_release "$baseline"
  validate_file "$RELEASE_BASE/$target/wali-media-worker"
  snapshot_offline_trust "$RELEASE_BASE/$target/payload" current || release_fail 'offline trust expired before activation'
  validate_warm_release "$target" "$baseline"
  begin_transaction "$baseline"
  trap transaction_failure EXIT ERR INT TERM
  stop_wali_units
  install_snapshot "$target"
  set_release_link current "$target"
  systemctl daemon-reload
  systemctl enable wali-media-worker.service >/dev/null
  start_wali_worker
  /usr/local/sbin/wali-worker-verify --quick
  assert_warm_namespace
  if [[ -f "$RELEASE_BASE/$baseline/wali-media-worker" ]]; then
    set_release_link previous "$baseline"
  else
    set_release_link previous absent
  fi
  sync -f "$RELEASE_BASE"
  finish_transaction
  trap - EXIT ERR INT TERM
  echo 'WALI deployment activated and verified'
}
lock_releases() {
  validate_managed_units
  [[ ! -L "$RELEASE_BASE" && ! -L "$RELEASE_BASE/releases" ]] || release_fail 'unsafe release root'
  install -d -o root -g root -m 0755 "$RELEASE_BASE" "$RELEASE_BASE/releases"
  exec 9>"$RELEASE_BASE/.deploy.lock"
  flock -n 9 || release_fail 'another deployment is running'
  if [[ -e "$TRANSACTION" ]]; then
    echo 'recovering the interrupted WALI deployment before continuing' >&2
    restore_transaction
  fi
}
