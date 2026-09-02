#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly UNIT="$ROOT/deploy/worker/wali-media-worker.service"
readonly RUNNER="$ROOT/Services/WALIMediaWorker/internal/sandbox/runner.go"

readonly DEPLOY_ROOT="$ROOT/deploy/worker"
for file in cloud-init.yml wali-media-worker.service worker.env.example storage.conf deploy.sh verify.sh; do
  test -f "$DEPLOY_ROOT/$file"
done
bash -n "$DEPLOY_ROOT/deploy.sh" "$DEPLOY_ROOT/verify.sh"
grep -q '^ssh_pwauth: false$' "$DEPLOY_ROOT/cloud-init.yml"
grep -q '^disable_root: true$' "$DEPLOY_ROOT/cloud-init.yml"
grep -q 'unattended-upgrades' "$DEPLOY_ROOT/cloud-init.yml"
grep -q 'AS production' "$ROOT/Services/WALIClassifier/Containerfile"
grep -q 'verify_model_directory' "$ROOT/Services/WALIClassifier/Containerfile"
grep -q 'com.wali.classifier.model-digest' "$DEPLOY_ROOT/deploy.sh"
grep -q 'com.wali.classifier.model-digest' "$DEPLOY_ROOT/verify.sh"

readonly CONTRACT_ROOT="$(mktemp -d)"
readonly TEST_PROJECT_REF=abcdefghijklmnopqrst
readonly TEST_CLASSIFIER_DIGEST="$(printf 'c%.0s' {1..64})"
trap 'chmod -R u+rwX -- "$CONTRACT_ROOT" 2>/dev/null || true' EXIT
printf '#!/bin/sh\nexit 0\n' >"$CONTRACT_ROOT/wali-media-worker"
chmod 0555 "$CONTRACT_ROOT/wali-media-worker"
cp "$DEPLOY_ROOT/worker.env.example" "$CONTRACT_ROOT/worker.env"
sed -i.bak \
  -e "s/REPLACE_PROJECT_REF/$TEST_PROJECT_REF/g" \
  -e 's/^WALI_DEPLOY_ENVIRONMENT=.*/WALI_DEPLOY_ENVIRONMENT=staging/' \
  -e "s|^WALI_CLASSIFIER_IMAGE=.*|WALI_CLASSIFIER_IMAGE=registry.example.invalid/wali/classifier@sha256:$TEST_CLASSIFIER_DIGEST|" \
  "$CONTRACT_ROOT/worker.env"
unlink "$CONTRACT_ROOT/worker.env.bak"
chmod 0600 "$CONTRACT_ROOT/worker.env"
for item in media:a verifier:b classifier:c; do
  name="${item%%:*}"; character="${item##*:}"
  printf '{"image_digest":"%s"}\n' "$(printf "$character%.0s" {1..64})" >"$CONTRACT_ROOT/$name.spdx.json"
done
printf 'test public key\n' >"$CONTRACT_ROOT/cosign.pub"
deploy_output="$($DEPLOY_ROOT/deploy.sh --dry-run \
  --environment staging --supabase-project-ref "$TEST_PROJECT_REF" \
  --worker-binary "$CONTRACT_ROOT/wali-media-worker" --environment-file "$CONTRACT_ROOT/worker.env" \
  --media-sbom "$CONTRACT_ROOT/media.spdx.json" --verifier-sbom "$CONTRACT_ROOT/verifier.spdx.json" \
  --classifier-sbom "$CONTRACT_ROOT/classifier.spdx.json" --cosign-key "$CONTRACT_ROOT/cosign.pub")"
grep -q '/opt/wali-worker/releases/' <<<"$deploy_output"
grep -q '/etc/wali-worker/worker.env' <<<"$deploy_output"
grep -q 'systemctl restart wali-media-worker.service' <<<"$deploy_output"
if grep -q 'REPLACE_WITH_' <<<"$deploy_output"; then
  echo 'worker dry-run leaked an environment-file value' >&2
  exit 1
fi
sed 's#@sha256:[a-f0-9]\{64\}#:latest#' "$CONTRACT_ROOT/worker.env" >"$CONTRACT_ROOT/mutable.env"
chmod 0600 "$CONTRACT_ROOT/mutable.env"
if "$DEPLOY_ROOT/deploy.sh" --dry-run --environment staging --supabase-project-ref "$TEST_PROJECT_REF" \
  --worker-binary "$CONTRACT_ROOT/wali-media-worker" \
  --environment-file "$CONTRACT_ROOT/mutable.env" --media-sbom "$CONTRACT_ROOT/media.spdx.json" \
  --verifier-sbom "$CONTRACT_ROOT/verifier.spdx.json" --classifier-sbom "$CONTRACT_ROOT/classifier.spdx.json" \
  --cosign-key "$CONTRACT_ROOT/cosign.pub" >/dev/null 2>&1; then
  echo 'worker deploy accepted a mutable image reference' >&2
  exit 1
fi

required_unit_settings=(
  'User=wali-worker'
  'Group=wali-worker'
  'ProtectSystem=strict'
  'ProtectHome=yes'
  'PrivateTmp=yes'
  'PrivateDevices=yes'
  'PrivateMounts=yes'
  'NoNewPrivileges=yes'
  'RestrictSUIDSGID=yes'
  'CapabilityBoundingSet='
  'AmbientCapabilities='
  'MemoryDenyWriteExecute=yes'
  'SystemCallArchitectures=native'
)
for setting in "${required_unit_settings[@]}"; do
  grep -Fqx -- "$setting" "$UNIT" || {
    echo "worker isolation is missing systemd setting: $setting" >&2
    exit 1
  }
done

required_sandbox_flags=(
  '"--network=none"'
  '"--read-only"'
  '"--cap-drop=ALL"'
  '"--security-opt=no-new-privileges"'
  '"--pids-limit="'
  '"--memory="'
  '"--memory-swap="'
  '"--tmpfs=/tmp:rw,noexec,nosuid,nodev,size="'
)
for flag in "${required_sandbox_flags[@]}"; do
  grep -Fq -- "$flag" "$RUNNER" || {
    echo "worker sandbox is missing fixed containment flag: $flag" >&2
    exit 1
  }
done

runtime_configuration=(
  "$ROOT/deploy/worker/cloud-init.yml"
  "$ROOT/deploy/worker/deploy.sh"
  "$ROOT/deploy/worker/storage.conf"
  "$ROOT/deploy/worker/verify.sh"
  "$ROOT/deploy/worker/wali-media-worker.service"
  "$ROOT/deploy/worker/worker.env.example"
  "$ROOT/Services/WALIMediaWorker/cmd/wali-media-worker/main.go"
  "$ROOT/Services/WALIMediaWorker/internal/config/config.go"
  "$ROOT/Services/WALIMediaWorker/internal/sandbox/runner.go"
)
if grep -n -E -- '--privileged|--network=(host|bridge)|/var/run/(docker|podman)\.sock|:[Ll]atest' \
  "${runtime_configuration[@]}"; then
  echo 'worker configuration contains a privileged, networked, socket-sharing, or mutable runtime setting' >&2
  exit 1
fi

echo 'worker isolation policy checks passed'
