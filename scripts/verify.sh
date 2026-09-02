#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

VERIFICATION_ROOT="${ROOT_DIR}/.build/verify"
DERIVED_DATA_PATH="${VERIFICATION_ROOT}/DerivedData"

rm -rf "${VERIFICATION_ROOT}"

"${ROOT_DIR}/Tests/Architecture/check-architecture-tests.sh"
"${ROOT_DIR}/scripts/check-architecture.sh"
"${ROOT_DIR}/scripts/check-licenses.sh"
"${ROOT_DIR}/scripts/verify-worker-isolation.sh"
"${ROOT_DIR}/Tests/Bundle/signature-metadata-tests.sh"
"${ROOT_DIR}/Tests/Bundle/verify-bundle-tests.sh"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    "${ROOT_DIR}/scripts/test.sh"
CONFIGURATION=Debug \
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    "${ROOT_DIR}/scripts/build.sh"
CONFIGURATION=Debug \
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    "${ROOT_DIR}/scripts/verify-bundle.sh"
