#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/xcode/DerivedData}"
PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/Debug"
PROFILE_OUTPUT_DIR="${DERIVED_DATA_PATH}/Logs/Test/Profiles"

"${ROOT_DIR}/scripts/generate.sh"

swift test --package-path Packages/WALICore

xcodebuild \
    -project WALI.xcodeproj \
    -scheme WALI \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build-for-testing

# All unit bundles are hostless and execute directly. The UI-test bundle is
# compiled above but requires a trusted Apple Development signature to launch.
unit_test_bundles=(
    WALIAppTests
    WALIAgentTests
    WALICatalogRuntimeTests
    WALILockScreenHelperTests
    WALITranscoderTests
    WALIUITests
)

mkdir -p "${PROFILE_OUTPUT_DIR}"
find "${PROFILE_OUTPUT_DIR}" -maxdepth 1 -type f -name '*.profraw' -delete

for test_bundle in "${unit_test_bundles[@]}"; do
    bundle_path="${PRODUCTS_DIR}/${test_bundle}.xctest"
    if [[ ! -d "${bundle_path}" ]]; then
        printf 'Missing unit test bundle: %s\n' "${bundle_path}" >&2
        exit 1
    fi

    LLVM_PROFILE_FILE="${PROFILE_OUTPUT_DIR}/${test_bundle}.profraw" \
        xcrun xctest "${bundle_path}"
done

DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    "${ROOT_DIR}/scripts/check-swift-coverage.sh"
