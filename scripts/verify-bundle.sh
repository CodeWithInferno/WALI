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

verify_signed_bundle() {
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
                --configuration "${CONFIGURATION}" \
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
[[ ${#login_item_entries[@]} -eq 2 ]] || fail "expected exactly two embedded login items"

AGENT_PATH="${LOGIN_ITEMS_DIR}/WALIAgent.app"
HELPER_PATH="${LOGIN_ITEMS_DIR}/WALILockScreenHelper.app"

for entry in "${login_item_entries[@]}"; do
    name="$(/usr/bin/basename "${entry}")"
    [[ "${name}" == "WALIAgent.app" || "${name}" == "WALILockScreenHelper.app" ]] ||
        fail "unexpected login item name"
done
assert_not_symlink "${AGENT_PATH}" "WALIAgent.app root"
[[ -d "${AGENT_PATH}" ]] || fail "embedded WALIAgent.app is not a directory"
assert_not_symlink "${AGENT_PATH}/Contents" "WALIAgent.app/Contents"
AGENT_CANONICAL_PATH="$(canonical_path "${AGENT_PATH}" "WALIAgent.app")"
assert_strict_descendant \
    "${AGENT_CANONICAL_PATH}" \
    "${APP_CANONICAL_PATH}" \
    "WALIAgent.app"
assert_not_symlink "${HELPER_PATH}" "WALILockScreenHelper.app root"
[[ -d "${HELPER_PATH}" ]] || fail "embedded WALILockScreenHelper.app is not a directory"
assert_not_symlink "${HELPER_PATH}/Contents" "WALILockScreenHelper.app/Contents"
HELPER_CANONICAL_PATH="$(canonical_path "${HELPER_PATH}" "WALILockScreenHelper.app")"
assert_strict_descendant \
    "${HELPER_CANONICAL_PATH}" \
    "${APP_CANONICAL_PATH}" \
    "WALILockScreenHelper.app"

HELPER_XPC_SERVICES_DIR="${HELPER_PATH}/Contents/XPCServices"
assert_not_symlink \
    "${HELPER_XPC_SERVICES_DIR}" \
    "WALILockScreenHelper.app/Contents/XPCServices"
shopt -s nullglob
shopt -s dotglob
helper_xpc_entries=()
if [[ -d "${HELPER_XPC_SERVICES_DIR}" ]]; then
    helper_xpc_entries=("${HELPER_XPC_SERVICES_DIR}"/*)
fi
shopt -u nullglob
shopt -u dotglob
[[ ${#helper_xpc_entries[@]} -eq 0 ]] ||
    fail "WALILockScreenHelper.app must not embed XPC services"

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
expected_helper_identifier="$(xcconfig_value WALI_LOCK_SCREEN_HELPER_BUNDLE_IDENTIFIER)"
expected_app_group="$(xcconfig_value WALI_APP_GROUP_IDENTIFIER)"
expected_control_service="$(xcconfig_value WALI_AGENT_CONTROL_SERVICE_NAME)"
expected_helper_service="$(xcconfig_value WALI_LOCK_SCREEN_HELPER_SERVICE_NAME)"
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
[[ "$(plist_value "${HELPER_PATH}/Contents/Info.plist" CFBundleIdentifier)" == "${expected_helper_identifier}" ]] ||
    fail "incorrect ${CONFIGURATION} lock screen helper bundle identifier"

# Developer ID cannot support native Apple authentication (ADR0021).
# Parse the plist value without coercion or shell newline trimming.
if [[ "${CONFIGURATION}" == "Release" ]]; then
    app_info_json="$(/usr/bin/plutil -convert json -o - "${APP_PATH}/Contents/Info.plist")" ||
        fail "could not read Release foreground Info.plist"
    printf '%s' "${app_info_json}" | /usr/bin/ruby -rjson -e '
        info = JSON.parse(STDIN.read)
        exit(info.is_a?(Hash) && info["WALIMarketplaceEnabled"] == "NO" ? 0 : 1)
    ' || fail "Release WALIMarketplaceEnabled must be the exact string NO"
fi

# Generated lookup metadata must name the same peers as the signed wrappers.
for spec in \
    "${APP_PATH}|WALIControlServiceName|${expected_control_service}" \
    "${APP_PATH}|WALIAgentLaunchAgentPlistName|${expected_agent_identifier}.plist" \
    "${APP_PATH}|WALILockScreenHelperLaunchAgentPlistName|${expected_helper_identifier}.plist" \
    "${AGENT_PATH}|WALIControlServiceName|${expected_control_service}" \
    "${AGENT_PATH}|WALITranscoderServiceName|${expected_transcoder_identifier}" \
    "${AGENT_PATH}|WALILockScreenHelperServiceName|${expected_helper_service}" \
    "${AGENT_PATH}|WALILockScreenHelperBundleIdentifier|${expected_helper_identifier}" \
    "${HELPER_PATH}|WALILockScreenHelperServiceName|${expected_helper_service}" \
    "${HELPER_PATH}|WALIExpectedAgentBundleIdentifier|${expected_agent_identifier}" \
    "${XPC_PATH}|WALIExpectedClientBundleIdentifier|${expected_agent_identifier}"; do
    IFS='|' read -r metadata_bundle metadata_key metadata_expected <<< "${spec}"
    metadata_actual="$(plist_value "${metadata_bundle}/Contents/Info.plist" "${metadata_key}" 2>/dev/null)" ||
        fail "missing ${metadata_key} runtime identity metadata"
    [[ "${metadata_actual}" == "${metadata_expected}" ]] ||
        fail "incorrect ${metadata_key} runtime identity metadata"
done

launch_agents_dir="${APP_PATH}/Contents/Library/LaunchAgents"
assert_not_symlink "${launch_agents_dir}" "Contents/Library/LaunchAgents"
for role in WALIAgent WALILockScreenHelper; do
    if [[ "${role}" == "WALIAgent" ]]; then
        identifier="${expected_agent_identifier}"
        service="${expected_control_service}"
    else
        identifier="${expected_helper_identifier}"
        service="${expected_helper_service}"
    fi
    launch_plist="${launch_agents_dir}/${identifier}.plist"
    assert_not_symlink "${launch_plist}" "${role} launch plist"
    [[ -f "${launch_plist}" ]] || fail "missing ${role} selected launch plist"
    launch_json="$(/usr/bin/plutil -convert json -o - "${launch_plist}")" || fail "invalid ${role} launch plist"
    printf '%s' "${launch_json}" | /usr/bin/ruby -rjson -e '
        role, identifier, service = ARGV
        expected = {
          "Label" => identifier,
          "BundleProgram" => "Contents/Library/LoginItems/#{role}.app/Contents/MacOS/#{role}",
          "MachServices" => {service => true}, "ProcessType" => "Interactive",
          "RunAtLoad" => true, "KeepAlive" => {"Crashed" => true}
        }
        exit(JSON.parse(STDIN.read) == expected ? 0 : 1)
    ' "${role}" "${identifier}" "${service}" || fail "incorrect ${role} launch identity or lifecycle metadata"
done

agent_ui_element="$(plist_value "${AGENT_PATH}/Contents/Info.plist" LSUIElement)"
[[ "${agent_ui_element}" == "true" || "${agent_ui_element}" == "1" ]] ||
    fail "WALIAgent is not configured as an LSUIElement"
helper_ui_element="$(plist_value "${HELPER_PATH}/Contents/Info.plist" LSUIElement)"
[[ "${helper_ui_element}" == "true" || "${helper_ui_element}" == "1" ]] ||
    fail "WALILockScreenHelper is not configured as an LSUIElement"

[[ "$(plist_value "${XPC_PATH}/Contents/Info.plist" XPCService.ServiceType)" == "Application" ]] ||
    fail "WALITranscoder has an invalid XPC service type"

[[ -x "${APP_PATH}/Contents/MacOS/WALI" ]] || fail "missing main app executable"
[[ -x "${AGENT_PATH}/Contents/MacOS/WALIAgent" ]] || fail "missing agent executable"
[[ -x "${XPC_PATH}/Contents/MacOS/WALITranscoder" ]] || fail "missing transcoder executable"
[[ -x "${HELPER_PATH}/Contents/MacOS/WALILockScreenHelper" ]] || fail "missing lock screen helper executable"

bundle_paths=("${APP_PATH}" "${AGENT_PATH}" "${XPC_PATH}" "${HELPER_PATH}")

expected_version="$(plist_value "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)"
expected_build="$(plist_value "${APP_PATH}/Contents/Info.plist" CFBundleVersion)"
[[ "${expected_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid application version"
[[ "${expected_build}" =~ ^[1-9][0-9]*$ ]] || fail "invalid application build number"
for bundle_path in "${bundle_paths[@]}"; do
    info_plist="${bundle_path}/Contents/Info.plist"
    [[ "$(plist_value "${info_plist}" CFBundleShortVersionString)" == "${expected_version}" ]] ||
        fail "$(/usr/bin/basename "${bundle_path}") version differs from the app"
    [[ "$(plist_value "${info_plist}" CFBundleVersion)" == "${expected_build}" ]] ||
        fail "$(/usr/bin/basename "${bundle_path}") build number differs from the app"
done


executables=(
    "${APP_PATH}/Contents/MacOS/WALI"
    "${AGENT_PATH}/Contents/MacOS/WALIAgent"
    "${XPC_PATH}/Contents/MacOS/WALITranscoder"
    "${HELPER_PATH}/Contents/MacOS/WALILockScreenHelper"
)
for bundle_path in "${bundle_paths[@]}"; do
    for debug_dylib in "${bundle_path}/Contents/MacOS/"*.debug.dylib; do
        [[ -e "${debug_dylib}" ]] || continue
        executables+=("${debug_dylib}")
    done
done

app_runtime_executables=("${APP_PATH}/Contents/MacOS/WALI")
for debug_dylib in "${APP_PATH}/Contents/MacOS/"*.debug.dylib; do
    [[ -e "${debug_dylib}" ]] || continue
    app_runtime_executables+=("${debug_dylib}")
done

app_links_avkit=false
for executable in "${app_runtime_executables[@]}"; do
    linkage="$(/usr/bin/otool -L "${executable}")" ||
        fail "otool could not inspect ${executable}"
    if [[ "${linkage}" == *"/System/Library/Frameworks/AVKit.framework/"* ]]; then
        app_links_avkit=true
        break
    fi
done
[[ "${app_links_avkit}" == true ]] ||
    fail "WALI app runtime does not link AVKit.framework"

internal_link_markers=(
    "WALIModel"
    "WALIWire"
    "WALIEngine"
    "WALIUI"
    "WALIAppRuntime"
    "WALIAgentRuntime"
    "WALITranscoderRuntime"
    "WALILockScreenHelperRuntime"
)

for executable in "${executables[@]}"; do
    linkage="$(/usr/bin/otool -L "${executable}")" ||
        fail "otool could not inspect ${executable}"
    for marker in "${internal_link_markers[@]}"; do
        [[ "${linkage}" != *"${marker}"* ]] ||
            fail "internal module is dynamically linked by ${executable}: ${marker}"
    done
done

helper_linkage="$(/usr/bin/otool -L "${HELPER_PATH}/Contents/MacOS/WALILockScreenHelper")" ||
    fail "otool could not inspect WALILockScreenHelper"
for forbidden in AVFoundation VideoToolbox WebKit JavaScriptCore Network SQLite3; do
    [[ "${helper_linkage}" != *"/${forbidden}.framework/"* &&
       "${helper_linkage}" != *"/lib${forbidden}."* ]] ||
        fail "WALILockScreenHelper links forbidden runtime ${forbidden}"
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

sealed_bundle_count=0
for bundle_path in "${bundle_paths[@]}"; do
    seal_path="${bundle_path}/Contents/_CodeSignature/CodeResources"
    if [[ -e "${seal_path}" || -L "${seal_path}" ]]; then
        sealed_bundle_count=$((sealed_bundle_count + 1))
    fi
done

if [[ "${CONFIGURATION}" == "Debug" ]]; then
    [[ ${sealed_bundle_count} -eq 0 || ${sealed_bundle_count} -eq 4 ]] ||
        fail "Debug bundles must be consistently unsealed or signed"
    if [[ ${sealed_bundle_count} -eq 4 ]]; then
        for bundle_path in "${bundle_paths[@]}"; do
            /usr/bin/codesign --verify --strict "${bundle_path}" || fail "invalid Debug seal"
        done
    fi
else
    [[ ${sealed_bundle_count} -eq 4 ]] ||
        fail "${CONFIGURATION} verification requires sealed signatures on all runtime bundles"
fi

if [[ "${CONFIGURATION}" == "Release" ]]; then
    expected_development_team="$(/usr/bin/codesign -dvv "${APP_PATH}" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}')"
    [[ -n "${expected_development_team}" && "${expected_development_team}" != "not set" ]] || fail "Release requires a Team ID"
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        [[ "${expected_development_team}" == "${DEVELOPMENT_TEAM}" ]] || fail "Release Team ID does not match DEVELOPMENT_TEAM"
    fi
fi
if [[ "${CONFIGURATION}" != "Debug" ]]; then
    verify_signed_bundle \
        "${APP_PATH}" \
        "${expected_app_group}" \
        "WALI.app" \
        "${expected_app_identifier}" \
        "${expected_development_team}"
    verify_signed_bundle \
        "${AGENT_PATH}" \
        "${expected_app_group}" \
        "WALIAgent.app" \
        "${expected_agent_identifier}" \
        "${expected_development_team}"
    verify_signed_bundle \
        "${XPC_PATH}" \
        "" \
        "WALITranscoder.xpc" \
        "${expected_transcoder_identifier}" \
        "${expected_development_team}"
    verify_signed_bundle \
        "${HELPER_PATH}" \
        "${expected_app_group}" \
        "WALILockScreenHelper.app" \
        "${expected_helper_identifier}" \
        "${expected_development_team}"
fi


ruby "${ROOT_DIR}/scripts/verify-third-party-licenses.rb" "${APP_PATH}"

if [[ "${CONFIGURATION}" == "Development" ]]; then
    signing_summary="strict Apple Development signatures"
elif [[ "${CONFIGURATION}" == "Release" ]]; then
    signing_summary="strict Developer ID signatures with secure timestamps"
else
    signing_summary="credential-free wrappers"
fi
printf 'Verified %s WALI.app identities, nested topology, %s, versions, and static internal linkage\n' \
    "${CONFIGURATION}" "${signing_summary}"
