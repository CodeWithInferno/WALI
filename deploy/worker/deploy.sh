#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly IMAGE_PATTERN='^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$'
readonly PROJECT_REF_PATTERN='^[a-z]{20}$'
readonly HOST_BINDING_FILE=/etc/wali-worker/HOST_IS_DEDICATED

usage() {
  echo 'usage: deploy.sh [--dry-run] --environment staging|production --supabase-project-ref REF --worker-binary PATH --environment-file PATH --media-sbom PATH --verifier-sbom PATH [--classifier-sbom PATH] --cosign-key PATH [--database-ca PATH] [--offline-trust-root PATH --offline-trust-receipt PATH --offline-trust-receipt-sha256 HEX]' >&2
  echo '       deploy.sh --rollback --environment staging|production --supabase-project-ref REF' >&2
}

read_optional_env_value() {
  local key=$1 file=$2 count value
  count="$(grep -c -E "^${key}=" "$file" || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n -E "s/^${key}=//p" "$file")"
  [[ ! "$value" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$value"
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

validate_target_binding() {
  local configured_environment=$1 configured_project_ref=$2 database_url=$3 storage_url=$4
  local database_authority database_hostport
  [[ "$configured_environment" == "$deployment_environment" ]] || { echo 'environment file does not match --environment' >&2; exit 65; }
  [[ "$configured_project_ref" == "$supabase_project_ref" ]] || { echo 'environment file does not match --supabase-project-ref' >&2; exit 65; }

  case "$database_url" in
    postgres://*|postgresql://*) ;;
    *) echo 'WALI_DATABASE_URL is not a PostgreSQL URL' >&2; exit 65 ;;
  esac
  database_authority="${database_url#*://}"
  database_authority="${database_authority%%/*}"
  [[ "$database_authority" == *@* ]] || { echo 'WALI_DATABASE_URL is missing its dedicated login identity' >&2; exit 65; }
  database_hostport="${database_authority##*@}"
  [[ "$database_hostport" == "db.$supabase_project_ref.supabase.co" || "$database_hostport" == "db.$supabase_project_ref.supabase.co:5432" ]] || {
    echo 'WALI_DATABASE_URL host does not match the explicit Supabase project' >&2
    exit 65
  }
  [[ "$storage_url" == "https://$supabase_project_ref.supabase.co" ]] || {
    echo 'WALI_STORAGE_URL origin does not match the explicit Supabase project' >&2
    exit 65
  }
}

validate_host_binding() {
  [[ -f "$HOST_BINDING_FILE" && ! -L "$HOST_BINDING_FILE" ]] || { echo 'dedicated-host binding marker is absent or unsafe; refusing mutation' >&2; exit 77; }
  [[ "$(stat -c '%U:%G:%a' "$HOST_BINDING_FILE")" == root:root:444 ]] || { echo 'dedicated-host binding marker must be root:root 0444' >&2; exit 77; }
  [[ "$(wc -l < "$HOST_BINDING_FILE" | tr -d ' ')" == 2 ]] || { echo 'dedicated-host binding marker has an unexpected shape' >&2; exit 65; }
  local marker_environment marker_project_ref
  marker_environment="$(read_env_value WALI_DEPLOY_ENVIRONMENT "$HOST_BINDING_FILE")" || { echo 'dedicated-host marker environment is missing or duplicated' >&2; exit 65; }
  marker_project_ref="$(read_env_value WALI_SUPABASE_PROJECT_REF "$HOST_BINDING_FILE")" || { echo 'dedicated-host marker project is missing or duplicated' >&2; exit 65; }
  [[ "$marker_environment" == "$deployment_environment" && "$marker_project_ref" == "$supabase_project_ref" ]] || {
    echo 'dedicated-host marker does not match the requested environment and Supabase project' >&2
    exit 77
  }
}

# A freshly provisioned dedicated HOME may be root-owned. Prepare only Podman's
# per-user configuration, preserving HOME ownership and existing configuration.
prepare_rootless_configuration() {
  python3 - "$(id -u wali-worker)" "$(id -g wali-worker)" <<'PYCONFIG'
import os
import stat
import sys

uid, gid = map(int, sys.argv[1:])
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
descriptors = []
try:
    parent = os.open('/var/lib/wali-worker', flags)
    descriptors.append(parent)
    home = os.fstat(parent)
    if home.st_uid not in (0, uid) or home.st_mode & 0o022:
        raise ValueError('unsafe worker home')
    for name in ('.config', 'containers'):
        created = False
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            created = True
        except FileExistsError:
            pass
        child = os.open(name, flags, dir_fd=parent)
        descriptors.append(child)
        if created:
            os.fchown(child, uid, gid)
            os.fchmod(child, 0o700)
        metadata = os.fstat(child)
        if (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) != (uid, gid, 0o700):
            raise ValueError('unsafe worker configuration directory')
        parent = child
except (OSError, ValueError):
    sys.exit('worker configuration directory is absent or unsafe; refusing deployment')
finally:
    for descriptor in reversed(descriptors):
        os.close(descriptor)
PYCONFIG
}

# Full deployment snapshots and crash-recoverable activation.
source "$SCRIPT_ROOT/image-verification.sh"
source "$SCRIPT_ROOT/releases.sh"

dry_run=false
rollback_requested=false
deployment_environment= supabase_project_ref= worker_binary= environment_file= media_sbom= verifier_sbom= classifier_sbom= cosign_key=
offline_trust_root= offline_trust_receipt= offline_trust_receipt_sha256=
database_ca=
while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --rollback) rollback_requested=true; shift ;;
    --environment)
      (($# >= 2)) || { usage; exit 64; }
      deployment_environment=$2; shift 2 ;;
    --offline-trust-root|--offline-trust-receipt|--offline-trust-receipt-sha256|--database-ca)
      (($# >= 2)) && [[ -n "$2" ]] || { usage; exit 64; }
      key="${1#--}"; key="${key//-/_}"
      [[ -z "${!key}" ]] || { echo 'duplicate trust option' >&2; exit 64; }
      printf -v "$key" '%s' "$2"; shift 2 ;;
    --supabase-project-ref|--worker-binary|--environment-file|--media-sbom|--verifier-sbom|--classifier-sbom|--cosign-key)
      (($# >= 2)) || { usage; exit 64; }
      key="${1#--}"; key="${key//-/_}"; printf -v "$key" '%s' "$2"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done

[[ "$deployment_environment" == staging || "$deployment_environment" == production ]] || { echo 'an explicit staging or production environment is required' >&2; exit 64; }
[[ "$supabase_project_ref" =~ $PROJECT_REF_PATTERN ]] || { echo 'an exact 20-letter Supabase project ref is required' >&2; exit 64; }

if [[ -n "$offline_trust_root" || -n "$offline_trust_receipt" || -n "$offline_trust_receipt_sha256" ]]; then
  $rollback_requested && { echo 'rollback uses only the selected snapshot trust inputs' >&2; exit 64; }
  validate_offline_trust "$offline_trust_root" "$offline_trust_receipt" "$offline_trust_receipt_sha256"
fi

if $rollback_requested; then
  [[ -z "$database_ca" ]] || { echo 'rollback uses only the selected snapshot database CA' >&2; exit 64; }
  validate_host_binding
  [[ "$(id -u)" == 0 ]] || { echo 'rollback inspection must run as root' >&2; exit 77; }
  if $dry_run; then
    [[ ! -e "$TRANSACTION" ]] || release_fail 'pending transaction requires recovery before rollback'
    target="$(release_link previous)"
    validate_release "$target"
    snapshot_offline_trust "$RELEASE_BASE/$target/payload" current
    printf 'would restore complete WALI snapshot %s and verify it; no mutation performed\n' "$target"
    exit
  fi
  lock_releases
  target="$(release_link previous)"
  validate_release "$target"
  verify_rollback_offline_images "$RELEASE_BASE/$target/payload"
  capture_baseline
  baseline="$staged_release"
  activate_release "$target" "$baseline"
  exit
fi
for value in worker_binary environment_file media_sbom verifier_sbom cosign_key; do
  [[ -n "${!value}" ]] || { usage; exit 64; }
  validate_file "${!value}"
done
validate_database_ca "$environment_file" "$database_ca"

media_image="$(read_env_value WALI_MEDIA_IMAGE "$environment_file")" || { echo 'WALI_MEDIA_IMAGE is missing or duplicated' >&2; exit 65; }
verifier_image="$(read_env_value WALI_VERIFIER_IMAGE "$environment_file")" || { echo 'WALI_VERIFIER_IMAGE is missing or duplicated' >&2; exit 65; }
classifier_image="$(read_optional_env_value WALI_CLASSIFIER_IMAGE "$environment_file")" || { echo 'WALI_CLASSIFIER_IMAGE is missing or duplicated' >&2; exit 65; }
configured_environment="$(read_env_value WALI_DEPLOY_ENVIRONMENT "$environment_file")" || { echo 'WALI_DEPLOY_ENVIRONMENT is missing or duplicated' >&2; exit 65; }
configured_project_ref="$(read_env_value WALI_SUPABASE_PROJECT_REF "$environment_file")" || { echo 'WALI_SUPABASE_PROJECT_REF is missing or duplicated' >&2; exit 65; }
database_url="$(read_env_value WALI_DATABASE_URL "$environment_file")" || { echo 'WALI_DATABASE_URL is missing or duplicated' >&2; exit 65; }
storage_url="$(read_env_value WALI_STORAGE_URL "$environment_file")" || { echo 'WALI_STORAGE_URL is missing or duplicated' >&2; exit 65; }
validate_target_binding "$configured_environment" "$configured_project_ref" "$database_url" "$storage_url"
for image in "$media_image" "$verifier_image"; do
  [[ "$image" =~ $IMAGE_PATTERN ]] || { echo 'all images must be immutable named sha256 references' >&2; exit 65; }
done
validate_sbom "$media_image" "$media_sbom"
validate_sbom "$verifier_image" "$verifier_sbom"
if [[ -n "$classifier_image" ]]; then
  [[ "$classifier_image" =~ $IMAGE_PATTERN ]] || { echo 'the classifier image must be an immutable named sha256 reference' >&2; exit 65; }
  [[ -n "$classifier_sbom" ]] || { echo 'a classifier SBOM is required when classification is enabled' >&2; exit 65; }
  validate_file "$classifier_sbom"
  validate_sbom "$classifier_image" "$classifier_sbom"
elif [[ -n "$classifier_sbom" ]]; then
  echo 'a classifier SBOM was provided while classification is disabled' >&2
  exit 65
fi

release_root="/opt/wali-worker/releases/<complete-snapshot-sha256>"
if $dry_run; then
  printf 'would bind deployment to %s/%s\n' "$deployment_environment" "$supabase_project_ref"
  printf 'would install worker at %s/wali-media-worker\n' "$release_root"
  printf 'would install protected environment at /etc/wali-worker/worker.env\n'
  if [[ -n "$database_ca" ]]; then
    printf 'would install snapshot-bound database CA at /etc/wali-worker/database-ca.crt as root:root 0444\n'
  fi
  if [[ -n "$classifier_image" ]]; then
    printf 'would verify three immutable images and SBOMs with cosign\n'
  else
    printf 'would verify two immutable images and SBOMs with cosign\n'
  fi
  if [[ -n "$offline_trust_root" ]]; then
    printf 'would use hash-bound, fresh offline trust inputs; dry-run does not verify image signatures\n'
  fi
  printf 'would run systemctl restart wali-media-worker.service with its WALI namespace dependency\n'
  exit
fi

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
validate_host_binding
id wali-worker >/dev/null 2>&1 || { echo 'pre-provisioned wali-worker identity is missing' >&2; exit 69; }
[[ "$(id -un wali-worker)" == wali-worker && "$(id -gn wali-worker)" == wali-worker ]] || { echo 'wali-worker identity is not dedicated' >&2; exit 65; }
if id -nG wali-worker | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker|adm)$'; then
  echo 'wali-worker belongs to a privileged group' >&2
  exit 65
fi
grep -q '^wali-worker:' /etc/subuid && grep -q '^wali-worker:' /etc/subgid || { echo 'rootless subordinate UID/GID ranges are missing' >&2; exit 69; }
for command in cosign install podman runuser systemctl flock sha256sum sync; do command -v "$command" >/dev/null || { echo "required host command is missing: $command" >&2; exit 69; }; done
if systemctl cat wali-media-worker.service >/dev/null 2>&1 && ! systemctl cat wali-media-worker.service | grep -q '^X-WALI-Managed=true$'; then
  echo 'service name is already occupied by a non-WALI unit' >&2
  exit 65
fi
if systemctl cat wali-podman-namespace.service >/dev/null 2>&1 && ! systemctl cat wali-podman-namespace.service | grep -q '^X-WALI-Managed=true$'; then
  echo 'namespace service name is already occupied by a non-WALI unit' >&2
  exit 65
fi

lock_releases
capture_baseline
baseline="$staged_release"
stage_release
target="$staged_release"
validate_release "$target"
validate_release "$baseline"
snapshot_offline_trust "$RELEASE_BASE/$target/payload" current
if [[ "$target" == "$baseline" ]]; then
  /usr/local/sbin/wali-worker-verify --quick
  echo 'identical WALI deployment already installed; rollback target preserved'
  exit
fi

# Changing an initialized storage layout is a separate migration, never a deploy.
snapshot_root="$RELEASE_BASE/$target/payload"
environment_file="$snapshot_root/environment"
cosign_key="$snapshot_root/cosign"
offline_trust_root= offline_trust_receipt= offline_trust_receipt_sha256=
if [[ -f "$snapshot_root/cosign-trust-root" ]]; then
  offline_trust_root="$snapshot_root/cosign-trust-root"
  offline_trust_receipt="$snapshot_root/cosign-trust-receipt"
  offline_trust_receipt_sha256="$(cat "$snapshot_root/cosign-trust-receipt-digest")"
fi
media_image="$(read_env_value WALI_MEDIA_IMAGE "$environment_file")"
verifier_image="$(read_env_value WALI_VERIFIER_IMAGE "$environment_file")"
classifier_image="$(read_optional_env_value WALI_CLASSIFIER_IMAGE "$environment_file")"
for image in "$media_image" "$verifier_image"; do
  [[ "$image" =~ $IMAGE_PATTERN ]] || release_fail 'snapshot image is not immutable'
  validate_sbom "$image" "$snapshot_root/sbom/${image##*@sha256:}.spdx.json"
done
if [[ -n "$classifier_image" ]]; then
  [[ "$classifier_image" =~ $IMAGE_PATTERN ]] || release_fail 'snapshot image is not immutable'
  validate_sbom "$classifier_image" "$snapshot_root/sbom/${classifier_image##*@sha256:}.spdx.json"
fi
if [[ -f /etc/wali-worker/storage.conf ]] && ! cmp -s "$snapshot_root/storage" /etc/wali-worker/storage.conf; then
  echo 'Podman storage configuration differs; migrate it explicitly before deployment' >&2
  exit 65
fi
prepare_rootless_configuration
# Inputs above now refer to the sealed, absolute snapshot paths. Podman drops
# privileges and re-executes; it must not inherit an operator-only transfer cwd.
cd /var/lib/wali-worker
install -d -o wali-worker -g wali-worker -m 0700 /var/lib/wali-worker/attempts /var/lib/wali-worker/containers /var/lib/wali-worker/volumes /run/wali-media-worker
preflight_storage="$(mktemp /run/wali-storage-preflight.XXXXXX)"
install -o root -g root -m 0644 "$snapshot_root/storage" "$preflight_storage"
trap 'rm -f -- "$preflight_storage"' EXIT

images=("$media_image" "$verifier_image")
[[ -z "$classifier_image" ]] || images+=("$classifier_image")
verify_worker_images "$cosign_key" "$offline_trust_root" "$offline_trust_receipt" "$offline_trust_receipt_sha256" "${images[@]}"
for image in "${images[@]}"; do
  if ! runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF="$preflight_storage" podman image exists "$image"; then
    runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF="$preflight_storage" podman pull "$image" >/dev/null
  fi
  runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF="$preflight_storage" podman image inspect "$image" >/dev/null
done
if [[ -n "$classifier_image" ]]; then
  classifier_label() {
    runuser -u wali-worker -- env -u DOCKER_CONFIG HOME=/var/lib/wali-worker XDG_RUNTIME_DIR=/run/wali-media-worker CONTAINERS_STORAGE_CONF="$preflight_storage" \
      podman image inspect --format "{{ index .Labels \"$1\" }}" "$classifier_image"
  }
  [[ "$(classifier_label com.wali.classifier.production)" == true ]] || { echo 'classifier image is not a verified production build' >&2; exit 65; }
  [[ "$(classifier_label com.wali.classifier.model-id)" == google/siglip-base-patch16-224 ]] || { echo 'classifier model ID differs from the reviewed contract' >&2; exit 65; }
  [[ "$(classifier_label com.wali.classifier.model-revision)" == 7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed ]] || { echo 'classifier model revision differs from the reviewed contract' >&2; exit 65; }
  [[ "$(classifier_label com.wali.classifier.model-digest)" == 2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877 ]] || { echo 'classifier model digest differs from the reviewed contract' >&2; exit 65; }
  [[ "$(classifier_label com.wali.classifier.taxonomy-revision)" == wali-taxonomy-v1 ]] || { echo 'classifier taxonomy differs from the reviewed contract' >&2; exit 65; }
fi

rm -f -- "$preflight_storage"
trap - EXIT
activate_release "$target" "$baseline"
