#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/xcode/DerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP_PATH="${1:-${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/WALI.app}"
LOGIN_ITEMS_DIR="${APP_PATH}/Contents/Library/LoginItems"
MAIN_XPC_SERVICES_DIR="${APP_PATH}/Contents/XPCServices"
CONFIG_FILE="${ROOT_DIR}/Config/${CONFIGURATION}.xcconfig"
SIGNATURE_INSPECTOR="${ROOT_DIR}/scripts/inspect-signature-metadata.rb"
SIGNATURE_VALIDATOR="${ROOT_DIR}/scripts/validate-signature-metadata.rb"

fail() {
    printf 'Bundle verification failed: %s\n' "$1" >&2
    exit 1
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1"
}

xcconfig_value() {
    local key="$1"
    local value

    value="$(/usr/bin/ruby -e '
        key, path = ARGV
        value = nil
        File.foreach(path) do |line|
          assignment = line.sub(%r{//.*$}, "").strip
          next if assignment.empty? || assignment.start_with?("#")

          name, candidate = assignment.split("=", 2)
          value = candidate.strip if candidate && name.strip == key
        end
        exit 3 if value.nil?
        print value
    ' "${key}" "${CONFIG_FILE}")" ||
        fail "${CONFIGURATION} is missing ${key} in Config/${CONFIGURATION}.xcconfig"
    printf '%s' "${value}"
}

canonical_path() {
    /usr/bin/ruby -e 'print File.realpath(ARGV.fetch(0))' "$1" ||
        fail "could not canonicalize $2"
}

assert_not_symlink() {
    /usr/bin/ruby -e '
        path = File.expand_path(ARGV.fetch(0))
        exit(File.symlink?(path) ? 1 : 0)
    ' "$1" || fail "$2 must not be a symbolic link"
}

assert_strict_descendant() {
    local child="$1"
    local parent="$2"
    local label="$3"

    /usr/bin/ruby -e '
        child = File.realpath(ARGV.fetch(0))
        parent = File.realpath(ARGV.fetch(1))
        prefix = "#{parent.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
        exit(child.start_with?(prefix) && child != parent ? 0 : 1)
    ' "${child}" "${parent}" ||
        fail "${label} must be a strict descendant of its expected parent"
}

verify_development_bundle() {
    local bundle_path="$1"
    local expected_group="$2"
    local label="$3"
    local expected_identifier="$4"
    local expected_team="$5"
    local metadata
    local validation_output

    metadata="$("${SIGNATURE_INSPECTOR}" "${bundle_path}")" ||
        fail "could not inspect ${label} signature"
    validation_output="$(
        printf '%s\n' "${metadata}" |
            "${SIGNATURE_VALIDATOR}" \
                --configuration Development \
                --label "${label}" \
                --bundle-identifier "${expected_identifier}" \
                --team "${expected_team}" \
                --app-group "${expected_group}" \
                2>&1
    )" || fail "${validation_output}"
}

case "${CONFIGURATION}" in
    Debug|Development|Release) ;;
    *) fail "unsupported configuration ${CONFIGURATION}" ;;
esac

assert_not_symlink "${APP_PATH}" "WALI.app root"
[[ -d "${APP_PATH}" ]] || fail "missing WALI.app at ${APP_PATH}"
assert_not_symlink "${APP_PATH}/Contents" "WALI.app/Contents"
assert_not_symlink "${APP_PATH}/Contents/Library" "WALI.app/Contents/Library"
assert_not_symlink "${LOGIN_ITEMS_DIR}" "Contents/Library/LoginItems"
[[ -d "${LOGIN_ITEMS_DIR}" ]] || fail "missing Contents/Library/LoginItems"
APP_CANONICAL_PATH="$(canonical_path "${APP_PATH}" "WALI.app")"
assert_not_symlink \
    "${MAIN_XPC_SERVICES_DIR}" \
    "main app Contents/XPCServices"

shopt -s nullglob
shopt -s dotglob
main_xpc_entries=()
if [[ -d "${MAIN_XPC_SERVICES_DIR}" ]]; then
    main_xpc_entries=("${MAIN_XPC_SERVICES_DIR}"/*)
fi
login_item_entries=("${LOGIN_ITEMS_DIR}"/*)
shopt -u nullglob
shopt -u dotglob

[[ ${#main_xpc_entries[@]} -eq 0 ]] ||
    fail "stale topology: main app Contents/XPCServices must be absent or empty"
[[ ${#login_item_entries[@]} -eq 1 ]] || fail "expected exactly one embedded login item"

AGENT_PATH="${login_item_entries[0]}"

[[ "$(/usr/bin/basename "${AGENT_PATH}")" == "WALIAgent.app" ]] ||
    fail "unexpected login item name"
assert_not_symlink "${AGENT_PATH}" "WALIAgent.app root"
[[ -d "${AGENT_PATH}" ]] || fail "embedded WALIAgent.app is not a directory"
assert_not_symlink "${AGENT_PATH}/Contents" "WALIAgent.app/Contents"
AGENT_CANONICAL_PATH="$(canonical_path "${AGENT_PATH}" "WALIAgent.app")"
assert_strict_descendant \
    "${AGENT_CANONICAL_PATH}" \
    "${APP_CANONICAL_PATH}" \
    "WALIAgent.app"

AGENT_XPC_SERVICES_DIR="${AGENT_PATH}/Contents/XPCServices"
assert_not_symlink \
    "${AGENT_XPC_SERVICES_DIR}" \
    "WALIAgent.app/Contents/XPCServices"
[[ -d "${AGENT_XPC_SERVICES_DIR}" ]] ||
    fail "missing WALIAgent.app/Contents/XPCServices"

shopt -s nullglob
shopt -s dotglob
agent_xpc_entries=("${AGENT_XPC_SERVICES_DIR}"/*)
shopt -u nullglob
shopt -u dotglob

[[ ${#agent_xpc_entries[@]} -eq 1 ]] ||
    fail "expected exactly one agent-private XPC service"

XPC_PATH="${agent_xpc_entries[0]}"
[[ "$(/usr/bin/basename "${XPC_PATH}")" == "WALITranscoder.xpc" ]] ||
    fail "unexpected XPC service name"
assert_not_symlink "${XPC_PATH}" "WALITranscoder.xpc root"
[[ -d "${XPC_PATH}" ]] || fail "embedded WALITranscoder.xpc is not a directory"
assert_not_symlink "${XPC_PATH}/Contents" "WALITranscoder.xpc/Contents"
XPC_CANONICAL_PATH="$(canonical_path "${XPC_PATH}" "WALITranscoder.xpc")"
assert_strict_descendant \
    "${XPC_CANONICAL_PATH}" \
    "${AGENT_CANONICAL_PATH}" \
    "WALITranscoder.xpc"

[[ -f "${CONFIG_FILE}" ]] ||
    fail "missing Config/${CONFIGURATION}.xcconfig"
expected_app_identifier="$(xcconfig_value WALI_APP_BUNDLE_IDENTIFIER)"
expected_agent_identifier="$(xcconfig_value WALI_AGENT_BUNDLE_IDENTIFIER)"
expected_transcoder_identifier="$(xcconfig_value WALI_TRANSCODER_BUNDLE_IDENTIFIER)"
expected_app_group="$(xcconfig_value WALI_APP_GROUP_IDENTIFIER)"
expected_control_service="$(xcconfig_value WALI_AGENT_CONTROL_SERVICE_NAME)"
expected_development_team="${DEVELOPMENT_TEAM:-}"

[[ -n "${expected_control_service}" ]] ||
    fail "${CONFIGURATION} planned control service identity is empty"
if [[ "${CONFIGURATION}" == "Debug" ]]; then
    [[ -z "${expected_app_group}" ]] ||
        fail "Debug must not configure a usable application group"
else
    [[ -n "${expected_app_group}" ]] ||
        fail "${CONFIGURATION} application group identity is empty"
fi
if [[ "${CONFIGURATION}" == "Development" ]]; then
    [[ -n "${expected_development_team}" ]] ||
        fail "Development verification requires DEVELOPMENT_TEAM to be set"
fi

[[ "$(plist_value "${APP_PATH}/Contents/Info.plist" CFBundleIdentifier)" == "${expected_app_identifier}" ]] ||
    fail "incorrect ${CONFIGURATION} main app bundle identifier"
[[ "$(plist_value "${AGENT_PATH}/Contents/Info.plist" CFBundleIdentifier)" == "${expected_agent_identifier}" ]] ||
    fail "incorrect ${CONFIGURATION} agent bundle identifier"
[[ "$(plist_value "${XPC_PATH}/Contents/Info.plist" CFBundleIdentifier)" == "${expected_transcoder_identifier}" ]] ||
    fail "incorrect ${CONFIGURATION} transcoder bundle identifier"

agent_ui_element="$(plist_value "${AGENT_PATH}/Contents/Info.plist" LSUIElement)"
[[ "${agent_ui_element}" == "true" || "${agent_ui_element}" == "1" ]] ||
    fail "WALIAgent is not configured as an LSUIElement"

[[ "$(plist_value "${XPC_PATH}/Contents/Info.plist" XPCService.ServiceType)" == "Application" ]] ||
    fail "WALITranscoder has an invalid XPC service type"

[[ -x "${APP_PATH}/Contents/MacOS/WALI" ]] || fail "missing main app executable"
[[ -x "${AGENT_PATH}/Contents/MacOS/WALIAgent" ]] || fail "missing agent executable"
[[ -x "${XPC_PATH}/Contents/MacOS/WALITranscoder" ]] || fail "missing transcoder executable"

bundle_paths=("${APP_PATH}" "${AGENT_PATH}" "${XPC_PATH}")

for bundle_path in "${bundle_paths[@]}"; do
    info_plist="${bundle_path}/Contents/Info.plist"
    [[ "$(plist_value "${info_plist}" CFBundleShortVersionString)" == "0.1.0" ]] ||
        fail "$(/usr/bin/basename "${bundle_path}") short version must be 0.1.0"
    [[ "$(plist_value "${info_plist}" CFBundleVersion)" == "1" ]] ||
        fail "$(/usr/bin/basename "${bundle_path}") build version must be 1"
done

sealed_bundle_count=0
for bundle_path in "${bundle_paths[@]}"; do
    seal_path="${bundle_path}/Contents/_CodeSignature/CodeResources"
    if [[ -e "${seal_path}" || -L "${seal_path}" ]]; then
        sealed_bundle_count=$((sealed_bundle_count + 1))
    fi
done

if [[ "${CONFIGURATION}" == "Debug" || "${CONFIGURATION}" == "Release" ]]; then
    [[ ${sealed_bundle_count} -eq 0 ]] ||
        fail "${CONFIGURATION} verification requires unsealed credential-free bundles"
else
    [[ ${sealed_bundle_count} -eq 3 ]] ||
        fail "Development verification requires sealed signatures on all runtime bundles"
fi

if [[ "${CONFIGURATION}" == "Development" ]]; then
    verify_development_bundle \
        "${APP_PATH}" \
        "${expected_app_group}" \
        "WALI.app" \
        "${expected_app_identifier}" \
        "${expected_development_team}"
    verify_development_bundle \
        "${AGENT_PATH}" \
        "${expected_app_group}" \
        "WALIAgent.app" \
        "${expected_agent_identifier}" \
        "${expected_development_team}"
    verify_development_bundle \
        "${XPC_PATH}" \
        "" \
        "WALITranscoder.xpc" \
        "${expected_transcoder_identifier}" \
        "${expected_development_team}"
fi

executables=(
    "${APP_PATH}/Contents/MacOS/WALI"
    "${AGENT_PATH}/Contents/MacOS/WALIAgent"
    "${XPC_PATH}/Contents/MacOS/WALITranscoder"
)
for bundle_path in "${bundle_paths[@]}"; do
    for debug_dylib in "${bundle_path}/Contents/MacOS/"*.debug.dylib; do
        [[ -e "${debug_dylib}" ]] || continue
        executables+=("${debug_dylib}")
    done
done
internal_link_markers=(
    "WALIModel"
    "WALIWire"
    "WALIEngine"
    "WALIUI"
    "WALIAppRuntime"
    "WALIAgentRuntime"
    "WALITranscoderRuntime"
)

for executable in "${executables[@]}"; do
    linkage="$(/usr/bin/otool -L "${executable}")" ||
        fail "otool could not inspect ${executable}"
    for marker in "${internal_link_markers[@]}"; do
        [[ "${linkage}" != *"${marker}"* ]] ||
            fail "internal module is dynamically linked by ${executable}: ${marker}"
    done
done

for bundle_path in "${bundle_paths[@]}"; do
    frameworks_dir="${bundle_path}/Contents/Frameworks"
    [[ -d "${frameworks_dir}" ]] || continue

    shopt -s nullglob
    internal_frameworks=("${frameworks_dir}"/WALI*.framework)
    shopt -u nullglob
    [[ ${#internal_frameworks[@]} -eq 0 ]] ||
        fail "internal frameworks were embedded in ${bundle_path}"
done

if [[ "${CONFIGURATION}" == "Development" ]]; then
    signing_summary="strict Apple Development signatures"
else
    signing_summary="unsealed credential-free wrappers"
fi
printf 'Verified %s WALI.app identities, nested topology, %s, versions, and static internal linkage\n' \
    "${CONFIGURATION}" "${signing_summary}"

