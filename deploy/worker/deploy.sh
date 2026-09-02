#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly IMAGE_PATTERN='^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$'

usage() {
  echo 'usage: deploy.sh [--dry-run] --worker-binary PATH --environment-file PATH --media-sbom PATH --verifier-sbom PATH --classifier-sbom PATH --cosign-key PATH' >&2
  echo '       deploy.sh --rollback' >&2
}

read_env_value() {
  local key=$1 file=$2 count value
  count="$(grep -c -E "^${key}=" "$file" || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n -E "s/^${key}=//p" "$file")"
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$value"
}

file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

validate_file() {
  [[ -f "$1" && ! -L "$1" && -s "$1" ]] || { echo "required regular file is missing: $1" >&2; exit 64; }
}

validate_sbom() {
  local image=$1 sbom=$2 digest
  digest="${image##*@sha256:}"
  grep -q "$digest" "$sbom" || { echo 'an SBOM does not attest its configured image digest' >&2; exit 65; }
}

rollback() {
  [[ "$(id -u)" == 0 ]] || { echo 'rollback must run as root on the worker host' >&2; exit 77; }
  [[ -L /opt/wali-worker/current && -L /opt/wali-worker/previous ]] || { echo 'both current and previous WALI releases are required' >&2; exit 69; }
  local current previous swap
  current="$(readlink /opt/wali-worker/current)"
  previous="$(readlink /opt/wali-worker/previous)"
  [[ "$current" == releases/* && "$previous" == releases/* ]] || { echo 'release links are outside the WALI release root' >&2; exit 65; }
  swap=/opt/wali-worker/.rollback-link
  ln -s -- "$previous" "$swap"
  mv -Tf -- "$swap" /opt/wali-worker/current
  ln -sfn -- "$current" /opt/wali-worker/previous
  systemctl restart wali-media-worker.service
  "$SCRIPT_ROOT/verify.sh" --quick
}

dry_run=false
rollback_requested=false
worker_binary= environment_file= media_sbom= verifier_sbom= classifier_sbom= cosign_key=
while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --rollback) rollback_requested=true; shift ;;
    --worker-binary|--environment-file|--media-sbom|--verifier-sbom|--classifier-sbom|--cosign-key)
      (($# >= 2)) || { usage; exit 64; }
      key="${1#--}"; key="${key//-/_}"; printf -v "$key" '%s' "$2"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done

if $rollback_requested; then
  rollback
  exit
fi
for value in worker_binary environment_file media_sbom verifier_sbom classifier_sbom cosign_key; do
  [[ -n "${!value}" ]] || { usage; exit 64; }
  validate_file "${!value}"
done

media_image="$(read_env_value WALI_MEDIA_IMAGE "$environment_file")" || { echo 'WALI_MEDIA_IMAGE is missing or duplicated' >&2; exit 65; }
verifier_image="$(read_env_value WALI_VERIFIER_IMAGE "$environment_file")" || { echo 'WALI_VERIFIER_IMAGE is missing or duplicated' >&2; exit 65; }
classifier_image="$(read_env_value WALI_CLASSIFIER_IMAGE "$environment_file")" || { echo 'WALI_CLASSIFIER_IMAGE is missing or duplicated' >&2; exit 65; }
for image in "$media_image" "$verifier_image" "$classifier_image"; do
  [[ "$image" =~ $IMAGE_PATTERN ]] || { echo 'all images must be immutable named sha256 references' >&2; exit 65; }
done
validate_sbom "$media_image" "$media_sbom"
validate_sbom "$verifier_image" "$verifier_sbom"
validate_sbom "$classifier_image" "$classifier_sbom"

release_id="$(file_digest "$worker_binary")"
release_root="/opt/wali-worker/releases/$release_id"
if $dry_run; then
  printf 'would install worker at %s/wali-media-worker\n' "$release_root"
  printf 'would install protected environment at /etc/wali-worker/worker.env\n'
  printf 'would verify three immutable images and SBOMs with cosign\n'
  printf 'would run systemctl restart wali-media-worker.service only\n'
  exit
fi

database_url="$(read_env_value WALI_DATABASE_URL "$environment_file")" || { echo 'WALI_DATABASE_URL is missing or duplicated' >&2; exit 65; }
storage_publishable_key="$(read_env_value WALI_STORAGE_PUBLISHABLE_KEY "$environment_file")" || { echo 'WALI_STORAGE_PUBLISHABLE_KEY is missing or duplicated' >&2; exit 65; }
storage_worker_token="$(read_env_value WALI_STORAGE_WORKER_TOKEN "$environment_file")" || { echo 'WALI_STORAGE_WORKER_TOKEN is missing or duplicated' >&2; exit 65; }
if [[ "$database_url" =~ ^postgres(ql)?://wali_worker(:|@) ]]; then
  echo 'WALI_DATABASE_URL must use a dedicated LOGIN identity, not the NOLOGIN wali_worker role' >&2
  exit 65
fi
if [[ "$database_url" == *REPLACE_* || "$storage_publishable_key" == *REPLACE_* || "$storage_worker_token" == *REPLACE_* ]]; then
  echo 'placeholder credentials cannot be deployed' >&2
  exit 65
fi

[[ "$(id -u)" == 0 ]] || { echo 'deployment must run as root on the worker host' >&2; exit 77; }
test -f /etc/wali-worker/HOST_IS_DEDICATED || { echo 'dedicated-host marker is absent; refusing shared-host mutation' >&2; exit 77; }
id wali-worker >/dev/null 2>&1 || { echo 'pre-provisioned wali-worker identity is missing' >&2; exit 69; }
[[ "$(id -un wali-worker)" == wali-worker && "$(id -gn wali-worker)" == wali-worker ]] || { echo 'wali-worker identity is not dedicated' >&2; exit 65; }
if id -nG wali-worker | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker|adm)$'; then
  echo 'wali-worker belongs to a privileged group' >&2
  exit 65
fi
grep -q '^wali-worker:' /etc/subuid && grep -q '^wali-worker:' /etc/subgid || { echo 'rootless subordinate UID/GID ranges are missing' >&2; exit 69; }
for command in cosign install podman runuser systemctl; do command -v "$command" >/dev/null || { echo "required host command is missing: $command" >&2; exit 69; }; done
if systemctl cat wali-media-worker.service >/dev/null 2>&1 && ! systemctl cat wali-media-worker.service | grep -q '^X-WALI-Managed=true$'; then
  echo 'service name is already occupied by a non-WALI unit' >&2
  exit 65
fi

install -d -o root -g wali-worker -m 0750 /etc/wali-worker
install -d -o wali-worker -g wali-worker -m 0700 /var/lib/wali-worker/attempts /var/lib/wali-worker/containers /var/lib/wali-worker/volumes /run/wali-media-worker
install -o root -g root -m 0644 "$SCRIPT_ROOT/storage.conf" /etc/wali-worker/storage.conf

for image in "$media_image" "$verifier_image" "$classifier_image"; do
  cosign verify --key "$cosign_key" "$image" >/dev/null
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman pull "$image" >/dev/null
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf podman image inspect "$image" >/dev/null
done
classifier_label() {
  runuser -u wali-worker -- env HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF=/etc/wali-worker/storage.conf \
    podman image inspect --format "{{ index .Labels \"$1\" }}" "$classifier_image"
}
[[ "$(classifier_label com.wali.classifier.production)" == true ]] || { echo 'classifier image is not a verified production build' >&2; exit 65; }
[[ "$(classifier_label com.wali.classifier.model-id)" == google/siglip-base-patch16-224 ]] || { echo 'classifier model ID differs from the reviewed contract' >&2; exit 65; }
[[ "$(classifier_label com.wali.classifier.model-revision)" == 7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed ]] || { echo 'classifier model revision differs from the reviewed contract' >&2; exit 65; }
[[ "$(classifier_label com.wali.classifier.model-digest)" == 2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877 ]] || { echo 'classifier model digest differs from the reviewed contract' >&2; exit 65; }
[[ "$(classifier_label com.wali.classifier.taxonomy-revision)" == wali-taxonomy-v1 ]] || { echo 'classifier taxonomy differs from the reviewed contract' >&2; exit 65; }

install -d -o root -g root -m 0755 /opt/wali-worker /opt/wali-worker/releases "$release_root" /usr/share/doc/wali-worker/sbom
install -o root -g root -m 0555 "$worker_binary" "$release_root/wali-media-worker"
install -o root -g wali-worker -m 0640 "$environment_file" /etc/wali-worker/worker.env
install -o root -g root -m 0644 "$SCRIPT_ROOT/wali-media-worker.service" /etc/systemd/system/wali-media-worker.service
install -o root -g root -m 0555 "$SCRIPT_ROOT/verify.sh" /usr/local/sbin/wali-worker-verify
install -o root -g root -m 0444 "$cosign_key" /etc/wali-worker/cosign.pub
install -o root -g root -m 0444 "$media_sbom" "/usr/share/doc/wali-worker/sbom/${media_image##*@sha256:}.spdx.json"
install -o root -g root -m 0444 "$verifier_sbom" "/usr/share/doc/wali-worker/sbom/${verifier_image##*@sha256:}.spdx.json"
install -o root -g root -m 0444 "$classifier_sbom" "/usr/share/doc/wali-worker/sbom/${classifier_image##*@sha256:}.spdx.json"
install -o root -g root -m 0444 "$SCRIPT_ROOT/../../docs/runbooks/media-worker.md" /usr/share/doc/wali-worker/media-worker.md
install -o root -g root -m 0444 "$SCRIPT_ROOT/../../docs/runbooks/worker-compromise.md" /usr/share/doc/wali-worker/worker-compromise.md

if [[ -L /opt/wali-worker/current ]]; then
  current="$(readlink /opt/wali-worker/current)"
  [[ "$current" == releases/* ]] || { echo 'current release link is outside the WALI root' >&2; exit 65; }
  ln -sfn -- "$current" /opt/wali-worker/previous
fi
ln -s -- "releases/$release_id" /opt/wali-worker/.current-link
mv -Tf -- /opt/wali-worker/.current-link /opt/wali-worker/current
systemctl daemon-reload
systemctl enable wali-media-worker.service >/dev/null
systemctl restart wali-media-worker.service
if ! /usr/local/sbin/wali-worker-verify --quick; then
  echo 'new WALI release failed verification' >&2
  if [[ -L /opt/wali-worker/previous ]]; then
    rollback
    echo 'previous WALI release restored; deployment remains failed' >&2
  else
    systemctl stop wali-media-worker.service
    echo 'no rollback release exists; WALI worker stopped' >&2
  fi
  exit 1
fi
