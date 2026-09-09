#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/store/DerivedData}"
"${ROOT_DIR}/scripts/generate-store.sh"
/usr/bin/ruby "${ROOT_DIR}/Tests/Architecture/store-graph-tests.rb"
python3 -B "${ROOT_DIR}/Tests/Bundle/store-signing-tests.py"
xcodebuild -project "${ROOT_DIR}/WALIStore.xcodeproj" -scheme WALI \
    -configuration StoreDevelopment -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
PROFILE_OUTPUT_DIR="${DERIVED_DATA_PATH}/Logs/Test/StoreProfiles"
mkdir -p "${PROFILE_OUTPUT_DIR}"
for name in WALIAppTests WALIAgentTests WALICatalogRuntimeTests WALITranscoderTests WALIUITests; do
    bundle="${DERIVED_DATA_PATH}/Build/Products/StoreDevelopment/${name}.xctest"
    [[ -d "${bundle}" ]] || { printf 'Missing test bundle: %s\n' "${bundle}" >&2; exit 1; }
    LLVM_PROFILE_FILE="${PROFILE_OUTPUT_DIR}/${name}-%p.profraw" xcrun xctest "${bundle}"
done
