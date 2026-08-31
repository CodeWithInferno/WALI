#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/xcode/DerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"

if [[ "${CONFIGURATION}" == "Development" && -z "${DEVELOPMENT_TEAM:-}" ]]; then
    printf 'Development builds require DEVELOPMENT_TEAM to be set.\n' >&2
    exit 1
fi

"${ROOT_DIR}/scripts/generate.sh"

signing_arguments=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

if [[ "${CONFIGURATION}" == "Development" ]]; then
    signing_arguments=(
        -allowProvisioningUpdates
        CODE_SIGNING_ALLOWED=YES
        CODE_SIGNING_REQUIRED=YES
        "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    )
fi

xcodebuild \
    -project WALI.xcodeproj \
    -scheme WALI \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    "${signing_arguments[@]}" \
    build

