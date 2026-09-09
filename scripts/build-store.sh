#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-StoreDevelopment}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/store/DerivedData}"
STRUCTURAL_ONLY="${STRUCTURAL_ONLY:-YES}"
case "${CONFIGURATION}" in StoreDevelopment|AppStore) ;; *) printf 'Unsupported Store configuration: %s\n' "${CONFIGURATION}" >&2; exit 2;; esac
SIGNING_ARGS=()
if [[ "${STRUCTURAL_ONLY}" == YES ]]; then
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)
    printf 'Building a structural Store artifact; it is not signed or installable release evidence.\n'
elif [[ "${STRUCTURAL_ONLY}" != NO ]]; then
    printf 'STRUCTURAL_ONLY must be YES or NO\n' >&2; exit 2
elif [[ "${CONFIGURATION}" == StoreDevelopment ]]; then
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM for the signed Store feasibility build}"
    SIGNING_ARGS=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
    if [[ "${ALLOW_PROVISIONING_UPDATES:-NO}" == YES ]]; then
        SIGNING_ARGS+=(-allowProvisioningUpdates)
    fi
else
    printf 'Use the Fastlane store_archive lane for App Store distribution signing.\n' >&2; exit 2
fi
"${ROOT_DIR}/scripts/generate-store.sh"
/usr/bin/ruby "${ROOT_DIR}/scripts/check-store-graph.rb" "${ROOT_DIR}"
# The shared scheme records test coverage; build artifacts must not include it.
xcodebuild -project "${ROOT_DIR}/WALIStore.xcodeproj" -scheme WALI \
    -configuration "${CONFIGURATION}" -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -clonedSourcePackagesDirPath "${ROOT_DIR}/.build/store/DerivedData/SourcePackages" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile "${SIGNING_ARGS[@]}" \
    ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO build
