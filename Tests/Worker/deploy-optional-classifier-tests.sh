#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wali-worker-deploy-test.XXXXXX")"
trap 'find "$fixture_root" -type f -delete; find "$fixture_root" -depth -type d -delete' EXIT

media_digest="$(printf 'a%.0s' {1..64})"
verifier_digest="$(printf 'b%.0s' {1..64})"
project_ref=abcdefghijklmnopqrst
printf 'fixture\n' > "$fixture_root/worker"
printf 'fixture\n' > "$fixture_root/cosign.pub"
printf '%s\n' "$media_digest" > "$fixture_root/media.spdx.json"
printf '%s\n' "$verifier_digest" > "$fixture_root/verifier.spdx.json"

cat > "$fixture_root/worker.env" <<EOF
WALI_DEPLOY_ENVIRONMENT=staging
WALI_SUPABASE_PROJECT_REF=$project_ref
WALI_DATABASE_URL=postgresql://wali_worker_runtime:fixture@db.$project_ref.supabase.co:5432/postgres?sslmode=verify-full
WALI_STORAGE_URL=https://$project_ref.supabase.co
WALI_STORAGE_PUBLISHABLE_KEY=sb_publishable_fixture
WALI_STORAGE_WORKER_TOKEN=fixture.header.signature
WALI_MEDIA_IMAGE=us-east1-docker.pkg.dev/example/wali/media@sha256:$media_digest
WALI_VERIFIER_IMAGE=us-east1-docker.pkg.dev/example/wali/media@sha256:$verifier_digest
WALI_CLASSIFIER_IMAGE=
EOF

deploy_args=(
  --dry-run \
  --environment staging \
  --supabase-project-ref "$project_ref" \
  --worker-binary "$fixture_root/worker" \
  --environment-file "$fixture_root/worker.env" \
  --media-sbom "$fixture_root/media.spdx.json" \
  --verifier-sbom "$fixture_root/verifier.spdx.json" \
  --cosign-key "$fixture_root/cosign.pub"
)
output="$($repo_root/deploy/worker/deploy.sh "${deploy_args[@]}")"

grep -q 'verify two immutable images' <<<"$output"
grep -q "bind deployment to staging/$project_ref" <<<"$output"
! grep -q 'classifier' <<<"$output"

sed "s/db\.$project_ref\.supabase\.co/db.otherproject.supabase.co/" "$fixture_root/worker.env" > "$fixture_root/wrong-database.env"
if "$repo_root/deploy/worker/deploy.sh" "${deploy_args[@]/$fixture_root\/worker.env/$fixture_root\/wrong-database.env}" >/dev/null 2>&1; then
  echo 'deploy accepted a database host from another Supabase project' >&2
  exit 1
fi

sed "s|^WALI_STORAGE_URL=.*|WALI_STORAGE_URL=https://otherproject.supabase.co|" "$fixture_root/worker.env" > "$fixture_root/wrong-storage.env"
if "$repo_root/deploy/worker/deploy.sh" "${deploy_args[@]/$fixture_root\/worker.env/$fixture_root\/wrong-storage.env}" >/dev/null 2>&1; then
  echo 'deploy accepted a Storage host from another Supabase project' >&2
  exit 1
fi

if "$repo_root/deploy/worker/deploy.sh" "${deploy_args[@]/staging/production}" >/dev/null 2>&1; then
  echo 'deploy accepted a production environment for a staging-only fixture' >&2
  exit 1
fi

grep -q '^      WALI_DEPLOY_ENVIRONMENT=REPLACE_ENVIRONMENT$' "$repo_root/deploy/worker/cloud-init.yml"
grep -q '^      WALI_SUPABASE_PROJECT_REF=REPLACE_PROJECT_REF$' "$repo_root/deploy/worker/cloud-init.yml"
grep -q 'marker_environment.*deployment_environment' "$repo_root/deploy/worker/deploy.sh"
grep -q 'marker_project_ref.*supabase_project_ref' "$repo_root/deploy/worker/deploy.sh"

echo 'worker deploy optional-classifier tests passed'
