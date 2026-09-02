#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/xcode/DerivedData}"
PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/Debug"
PROFILE_OUTPUT_DIR="${DERIVED_DATA_PATH}/Logs/Test/Profiles"
COVERAGE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wali-coverage.XXXXXX")"
trap 'rm -rf "${COVERAGE_TEMP_DIR}"' EXIT

shopt -s nullglob
profiles=("${PROFILE_OUTPUT_DIR}"/*.profraw)
if [[ ${#profiles[@]} -lt 6 ]]; then
    printf 'Coverage gate requires all six native unit-test profiles; found %s.\n' "${#profiles[@]}" >&2
    exit 1
fi

xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "${COVERAGE_TEMP_DIR}/all.profdata"

check_group() {
    local bundle="$1"
    local minimum="$2"
    shift 2
    local binary="${PRODUCTS_DIR}/${bundle}.xctest/Contents/MacOS/${bundle}"
    local report="${COVERAGE_TEMP_DIR}/${bundle}.txt"
    if [[ ! -x "${binary}" ]]; then
        printf 'Coverage binary is missing: %s\n' "${binary}" >&2
        exit 1
    fi
    xcrun llvm-cov report "${binary}" \
        -instr-profile="${COVERAGE_TEMP_DIR}/all.profdata" \
        "$@" >"${report}"
    local line_coverage
    line_coverage="$(awk '$1 == "TOTAL" { value=$10; sub(/%$/, "", value); print value }' "${report}")"
    if [[ ! "${line_coverage}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf 'Could not parse %s line coverage.\n' "${bundle}" >&2
        exit 1
    fi
    if ! awk -v actual="${line_coverage}" -v required="${minimum}" 'BEGIN { exit !(actual >= required) }'; then
        printf '%s trust-critical line coverage %s%% is below %s%%.\n' \
            "${bundle}" "${line_coverage}" "${minimum}" >&2
        cat "${report}" >&2
        exit 1
    fi
    printf '%s trust-critical line coverage: %s%% (minimum %s%%)\n' \
        "${bundle}" "${line_coverage}" "${minimum}"
}

cd "${ROOT_DIR}"
check_group WALICatalogRuntimeTests 60 \
    Sources/WALICatalogRuntime/CatalogPresentationMediaCache.swift \
    Sources/WALICatalogRuntime/CatalogDownloader.swift
check_group WALIAppTests 50 \
    Sources/WALIAppRuntime/Marketplace/MarketplaceCoordinator.swift \
    Sources/WALIAppRuntime/Marketplace/Creator/CreatorModerationModel.swift
check_group WALIAgentTests 42 \
    Sources/WALIAgentRuntime/Catalog/CatalogInstallCoordinator.swift \
    Sources/WALIAgentRuntime/Storage/ContentStorage.swift \
    Sources/WALIAgentRuntime/Storage/RuntimeStore.swift
