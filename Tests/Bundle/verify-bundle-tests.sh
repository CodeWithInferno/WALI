#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="${ROOT_DIR}/scripts/verify-bundle.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

pass_count=0
failure_count=0

write_bundle_plists() {
    local app_path="$1"
    local app_identifier="$2"
    local agent_identifier="$3"
    local transcoder_identifier="$4"
    local helper_identifier="${app_identifier%WALI}WALILockScreenHelper"

    cat > "${app_path}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALI</string>
  <key>WALIControlServiceName</key><string>${agent_identifier}.control</string>
  <key>WALIAgentLaunchAgentPlistName</key><string>${agent_identifier}.plist</string>
  <key>WALILockScreenHelperLaunchAgentPlistName</key><string>${helper_identifier}.plist</string>
  <key>CFBundleIdentifier</key><string>${app_identifier}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
EOF

    cat > "${app_path}/Contents/Library/LoginItems/WALILockScreenHelper.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALILockScreenHelper</string>
  <key>WALILockScreenHelperServiceName</key><string>${helper_identifier}.control</string>
  <key>WALIExpectedAgentBundleIdentifier</key><string>${agent_identifier}</string>
  <key>CFBundleIdentifier</key><string>${helper_identifier}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

    cat > "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALIAgent</string>
  <key>WALIControlServiceName</key><string>${agent_identifier}.control</string>
  <key>WALITranscoderServiceName</key><string>${transcoder_identifier}</string>
  <key>WALILockScreenHelperServiceName</key><string>${helper_identifier}.control</string>
  <key>WALILockScreenHelperBundleIdentifier</key><string>${helper_identifier}</string>
  <key>CFBundleIdentifier</key><string>${agent_identifier}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

    cat > "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALITranscoder</string>
  <key>WALIExpectedClientBundleIdentifier</key><string>${agent_identifier}</string>
  <key>CFBundleIdentifier</key><string>${transcoder_identifier}</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>XPCService</key>
  <dict><key>ServiceType</key><string>Application</string></dict>
</dict>
</plist>
EOF
}

new_fixture() {
    local name="$1"
    local app_identifier="$2"
    local agent_identifier="$3"
    local transcoder_identifier="$4"
    local fixture_root="${TEMP_ROOT}/${name}"
    local app_path="${fixture_root}/WALI.app"

    mkdir -p \
        "${app_path}/Contents/MacOS" \
        "${app_path}/Contents/Resources" \
        "${app_path}/Contents/Library/LaunchAgents" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/MacOS" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/MacOS" \
        "${app_path}/Contents/Library/LoginItems/WALILockScreenHelper.app/Contents/MacOS"

    cp "${ROOT_DIR}/Config/LaunchAgents/"*.plist "${app_path}/Contents/Library/LaunchAgents/"
    cp -R "${ROOT_DIR}/Resources/ThirdPartyLicenses" "${app_path}/Contents/Resources/ThirdPartyLicenses"

    write_bundle_plists \
        "${app_path}" \
        "${app_identifier}" \
        "${agent_identifier}" \
        "${transcoder_identifier}"

    cat > "${fixture_root}/main.c" <<'EOF'
int main(void) { return 0; }
EOF
    xcrun clang \
        -mmacosx-version-min=15.0 \
        -framework AVKit \
        "${fixture_root}/main.c" \
        -o "${app_path}/Contents/MacOS/WALI"
    cp \
        "${app_path}/Contents/MacOS/WALI" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/MacOS/WALIAgent"
    cp \
        "${app_path}/Contents/MacOS/WALI" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/MacOS/WALITranscoder"
    cp \
        "${app_path}/Contents/MacOS/WALI" \
        "${app_path}/Contents/Library/LoginItems/WALILockScreenHelper.app/Contents/MacOS/WALILockScreenHelper"

    printf '%s\n' "${app_path}"
}

write_entitlements() {
    local path="$1"
    local application_identifier="$2"
    local include_group="$3"

    cat > "${path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>${application_identifier}</string>
  <key>com.apple.developer.team-identifier</key>
  <string>TESTTEAM01</string>
EOF
    if [[ "${include_group}" == "yes" ]]; then
        cat >> "${path}" <<'EOF'
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.wali.development.shared</string></array>
EOF
    fi
    cat >> "${path}" <<'EOF'
</dict>
</plist>
EOF
}

write_release_entitlements() {
    local path="$1"
    local application_identifier="$2"
    local include_group="$3"

    cat > "${path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>TESTTEAM01.${application_identifier}</string>
  <key>com.apple.developer.team-identifier</key>
  <string>TESTTEAM01</string>
EOF
    if [[ "${include_group}" == "yes" ]]; then
        cat >> "${path}" <<'EOF'
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.wali.shared</string></array>
EOF
    fi
    cat >> "${path}" <<'EOF'
</dict>
</plist>
EOF
}

expect_verifier_failure() {
    local name="$1"
    local configuration="$2"
    local app_path="$3"
    local expected="$4"
    local development_team="${5:-}"
    local output="${TEMP_ROOT}/${name}.out"
    local -a environment=("CONFIGURATION=${configuration}")

    if [[ -n "${development_team}" ]]; then
        environment+=("DEVELOPMENT_TEAM=${development_team}")
    fi

    if /usr/bin/env "${environment[@]}" \
        "${VERIFIER}" "${app_path}" >"${output}" 2>&1; then
        printf 'RED GAP: %s expected verifier failure\n' "${name}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    if ! /usr/bin/ruby -e \
        'exit(File.read(ARGV.fetch(0)).include?(ARGV.fetch(1)) ? 0 : 1)' \
        "${output}" "${expected}"; then
        printf 'RED GAP: %s did not report: %s\n' "${name}" "${expected}" >&2
        /usr/bin/awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    pass_count=$((pass_count + 1))
}

debug_app="$(new_fixture \
    debug \
    com.wali.debug.WALI \
    com.wali.debug.WALIAgent \
    com.wali.debug.WALITranscoder)"
CONFIGURATION=Debug "${VERIFIER}" "${debug_app}" >/dev/null
pass_count=$((pass_count + 1))

release_app="$(new_fixture \
    release \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
expect_verifier_failure \
    "release-unsigned" \
    Release \
    "${release_app}" \
    "Release verification requires sealed signatures on all runtime bundles"

development_app="$(new_fixture \
    development-adhoc \
    com.wali.development.WALI \
    com.wali.development.WALIAgent \
    com.wali.development.WALITranscoder)"
development_root="${TEMP_ROOT}/development-adhoc"
agent_path="${development_app}/Contents/Library/LoginItems/WALIAgent.app"
worker_path="${agent_path}/Contents/XPCServices/WALITranscoder.xpc"
helper_path="${development_app}/Contents/Library/LoginItems/WALILockScreenHelper.app"

write_entitlements \
    "${development_root}/worker.entitlements" \
    TESTTEAM01.com.wali.development.WALITranscoder \
    no
write_entitlements \
    "${development_root}/agent.entitlements" \
    TESTTEAM01.com.wali.development.WALIAgent \
    yes
write_entitlements \
    "${development_root}/helper.entitlements" \
    TESTTEAM01.com.wali.development.WALILockScreenHelper \
    yes
write_entitlements \
    "${development_root}/app.entitlements" \
    TESTTEAM01.com.wali.development.WALI \
    yes

/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements "${development_root}/worker.entitlements" \
    "${worker_path}"
/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements "${development_root}/helper.entitlements" \
    "${helper_path}"
/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements "${development_root}/agent.entitlements" \
    "${agent_path}"
/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements "${development_root}/app.entitlements" \
    "${development_app}"

missing_team_output="${TEMP_ROOT}/development-missing-team.out"
if env -u DEVELOPMENT_TEAM CONFIGURATION=Development \
    "${VERIFIER}" "${development_app}" >"${missing_team_output}" 2>&1; then
    printf 'Development verifier accepted a bundle without expected DEVELOPMENT_TEAM\n' >&2
    exit 1
fi
if ! /usr/bin/ruby -e \
    'exit(File.read(ARGV.fetch(0)).include?(ARGV.fetch(1)) ? 0 : 1)' \
    "${missing_team_output}" \
    "Development verification requires DEVELOPMENT_TEAM to be set"; then
    printf 'Development missing-team rejection did not report the expected failure\n' >&2
    /usr/bin/awk '{ print }' "${missing_team_output}" >&2
    exit 1
fi
pass_count=$((pass_count + 1))

output="${TEMP_ROOT}/development-adhoc.out"
if CONFIGURATION=Development DEVELOPMENT_TEAM=TESTTEAM01 \
    "${VERIFIER}" "${development_app}" >"${output}" 2>&1; then
    printf 'RED GAP: Development verifier accepted ad-hoc-signed nested bundles\n' >&2
    exit 1
fi

if ! /usr/bin/ruby -e \
    'exit(File.read(ARGV.fetch(0)).include?(ARGV.fetch(1)) ? 0 : 1)' \
    "${output}" \
    "Development verification rejects ad-hoc signature for WALI.app"; then
    printf 'Development ad-hoc rejection did not report the expected failure\n' >&2
    /usr/bin/awk '{ print }' "${output}" >&2
    exit 1
fi
pass_count=$((pass_count + 1))

release_adhoc="$(new_fixture \
    release-adhoc \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
release_adhoc_root="${TEMP_ROOT}/release-adhoc"
release_adhoc_agent="${release_adhoc}/Contents/Library/LoginItems/WALIAgent.app"
release_adhoc_worker="${release_adhoc_agent}/Contents/XPCServices/WALITranscoder.xpc"
release_adhoc_helper="${release_adhoc}/Contents/Library/LoginItems/WALILockScreenHelper.app"
write_release_entitlements \
    "${release_adhoc_root}/worker.entitlements" \
    io.github.codewithinferno.wali.WALITranscoder \
    no
write_release_entitlements \
    "${release_adhoc_root}/agent.entitlements" \
    io.github.codewithinferno.wali.WALIAgent \
    yes
write_release_entitlements \
    "${release_adhoc_root}/helper.entitlements" \
    io.github.codewithinferno.wali.WALILockScreenHelper \
    yes
write_release_entitlements \
    "${release_adhoc_root}/app.entitlements" \
    io.github.codewithinferno.wali.WALI \
    yes
/usr/bin/codesign \
    --force --sign - --timestamp=none --options runtime \
    --entitlements "${release_adhoc_root}/worker.entitlements" \
    "${release_adhoc_worker}"
/usr/bin/codesign \
    --force --sign - --timestamp=none --options runtime \
    --entitlements "${release_adhoc_root}/helper.entitlements" \
    "${release_adhoc_helper}"
/usr/bin/codesign \
    --force --sign - --timestamp=none --options runtime \
    --entitlements "${release_adhoc_root}/agent.entitlements" \
    "${release_adhoc_agent}"
/usr/bin/codesign \
    --force --sign - --timestamp=none --options runtime \
    --entitlements "${release_adhoc_root}/app.entitlements" \
    "${release_adhoc}"
expect_verifier_failure \
    "release-adhoc-sealed" \
    Release \
    "${release_adhoc}" \
    "Release requires a Team ID"

release_fake_seal="$(new_fixture \
    release-fake-seal \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
for bundle_path in \
    "${release_fake_seal}" \
    "${release_fake_seal}/Contents/Library/LoginItems/WALIAgent.app" \
    "${release_fake_seal}/Contents/Library/LoginItems/WALILockScreenHelper.app" \
    "${release_fake_seal}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc"; do
    mkdir -p "${bundle_path}/Contents/_CodeSignature"
    : > "${bundle_path}/Contents/_CodeSignature/CodeResources"
done
expect_verifier_failure \
    "release-sealed-wrappers" \
    Release \
    "${release_fake_seal}" \
    "Release requires a Team ID"

release_partial="$(new_fixture \
    release-partial-seal \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mkdir -p \
    "${release_partial}/Contents/Library/LoginItems/WALIAgent.app/Contents/_CodeSignature"
: > \
    "${release_partial}/Contents/Library/LoginItems/WALIAgent.app/Contents/_CodeSignature/CodeResources"
expect_verifier_failure \
    "release-partial-seal" \
    Release \
    "${release_partial}" \
    "Release verification requires sealed signatures on all runtime bundles"

debug_sealed="$(new_fixture \
    debug-sealed \
    com.wali.debug.WALI \
    com.wali.debug.WALIAgent \
    com.wali.debug.WALITranscoder)"
mkdir -p "${debug_sealed}/Contents/_CodeSignature"
: > "${debug_sealed}/Contents/_CodeSignature/CodeResources"
expect_verifier_failure \
    "debug-sealed" \
    Debug \
    "${debug_sealed}" \
    "Debug bundles must be consistently unsealed or signed"

debug_dylib="$(new_fixture \
    debug-dylib-linkage \
    com.wali.debug.WALI \
    com.wali.debug.WALIAgent \
    com.wali.debug.WALITranscoder)"
xcrun clang \
    -dynamiclib \
    -mmacosx-version-min=15.0 \
    -Wl,-install_name,@rpath/WALIAppRuntime.framework/Versions/A/WALIAppRuntime \
    "${TEMP_ROOT}/debug-dylib-linkage/main.c" \
    -o "${debug_dylib}/Contents/MacOS/WALI.debug.dylib"
expect_verifier_failure \
    "debug-dylib-linkage" \
    Debug \
    "${debug_dylib}" \
    "internal module is dynamically linked"

missing_avkit="$(new_fixture \
    missing-avkit \
    com.wali.debug.WALI \
    com.wali.debug.WALIAgent \
    com.wali.debug.WALITranscoder)"
xcrun clang \
    -mmacosx-version-min=15.0 \
    "${TEMP_ROOT}/missing-avkit/main.c" \
    -o "${missing_avkit}/Contents/MacOS/WALI"
expect_verifier_failure \
    "missing-avkit" \
    Debug \
    "${missing_avkit}" \
    "WALI app runtime does not link AVKit.framework"

main_xpc="$(new_fixture \
    main-xpc \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mkdir -p "${main_xpc}/Contents/XPCServices"
: > "${main_xpc}/Contents/XPCServices/.unexpected"
expect_verifier_failure \
    "main-app-xpc-hidden-entry" \
    Release \
    "${main_xpc}" \
    "stale topology: main app Contents/XPCServices must be absent or empty"

duplicate_login="$(new_fixture \
    duplicate-login \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mkdir -p "${duplicate_login}/Contents/Library/LoginItems/Other.app"
expect_verifier_failure \
    "duplicate-login-item" \
    Release \
    "${duplicate_login}" \
    "expected exactly two embedded login items"

hidden_login="$(new_fixture \
    hidden-login \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
: > "${hidden_login}/Contents/Library/LoginItems/.unexpected"
expect_verifier_failure \
    "hidden-login-item" \
    Release \
    "${hidden_login}" \
    "expected exactly two embedded login items"

wrong_login="$(new_fixture \
    wrong-login \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mv \
    "${wrong_login}/Contents/Library/LoginItems/WALIAgent.app" \
    "${wrong_login}/Contents/Library/LoginItems/Other.app"
expect_verifier_failure \
    "wrong-login-item-name" \
    Release \
    "${wrong_login}" \
    "unexpected login item name"

duplicate_xpc="$(new_fixture \
    duplicate-xpc \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mkdir -p \
    "${duplicate_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/Other.xpc"
expect_verifier_failure \
    "duplicate-xpc-service" \
    Release \
    "${duplicate_xpc}" \
    "expected exactly one agent-private XPC service"

hidden_xpc="$(new_fixture \
    hidden-xpc \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
: > \
    "${hidden_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/.unexpected"
expect_verifier_failure \
    "hidden-xpc-service" \
    Release \
    "${hidden_xpc}" \
    "expected exactly one agent-private XPC service"

wrong_xpc="$(new_fixture \
    wrong-xpc \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mv \
    "${wrong_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc" \
    "${wrong_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/Other.xpc"
expect_verifier_failure \
    "wrong-xpc-service-name" \
    Release \
    "${wrong_xpc}" \
    "unexpected XPC service name"

partial_topology="$(new_fixture \
    partial-topology \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
rm -rf \
    "${partial_topology}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices"
expect_verifier_failure \
    "partial-topology" \
    Release \
    "${partial_topology}" \
    "missing WALIAgent.app/Contents/XPCServices"

root_target="$(new_fixture \
    root-symlink-target \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mkdir -p "${TEMP_ROOT}/root-symlink"
ln -s "${root_target}" "${TEMP_ROOT}/root-symlink/WALI.app"
expect_verifier_failure \
    "app-root-symlink" \
    Release \
    "${TEMP_ROOT}/root-symlink/WALI.app/" \
    "WALI.app root must not be a symbolic link"

login_symlink="$(new_fixture \
    login-directory-symlink \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mv \
    "${login_symlink}/Contents/Library/LoginItems" \
    "${TEMP_ROOT}/escaped-login-items"
ln -s \
    "${TEMP_ROOT}/escaped-login-items" \
    "${login_symlink}/Contents/Library/LoginItems"
expect_verifier_failure \
    "login-items-directory-symlink" \
    Release \
    "${login_symlink}" \
    "Contents/Library/LoginItems must not be a symbolic link"

agent_symlink="$(new_fixture \
    agent-root-symlink \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
mv \
    "${agent_symlink}/Contents/Library/LoginItems/WALIAgent.app" \
    "${TEMP_ROOT}/escaped-agent.app"
ln -s \
    "${TEMP_ROOT}/escaped-agent.app" \
    "${agent_symlink}/Contents/Library/LoginItems/WALIAgent.app"
expect_verifier_failure \
    "agent-root-symlink" \
    Release \
    "${agent_symlink}" \
    "WALIAgent.app root must not be a symbolic link"

xpc_directory_symlink="$(new_fixture \
    xpc-directory-symlink \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
xpc_directory_agent="${xpc_directory_symlink}/Contents/Library/LoginItems/WALIAgent.app"
mv \
    "${xpc_directory_agent}/Contents/XPCServices" \
    "${TEMP_ROOT}/escaped-xpc-services"
ln -s \
    "${TEMP_ROOT}/escaped-xpc-services" \
    "${xpc_directory_agent}/Contents/XPCServices"
expect_verifier_failure \
    "xpc-services-directory-symlink" \
    Release \
    "${xpc_directory_symlink}" \
    "WALIAgent.app/Contents/XPCServices must not be a symbolic link"

worker_symlink="$(new_fixture \
    worker-root-symlink \
    io.github.codewithinferno.wali.WALI \
    io.github.codewithinferno.wali.WALIAgent \
    io.github.codewithinferno.wali.WALITranscoder)"
worker_symlink_directory="${worker_symlink}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices"
mv \
    "${worker_symlink_directory}/WALITranscoder.xpc" \
    "${TEMP_ROOT}/escaped-worker.xpc"
ln -s \
    "${TEMP_ROOT}/escaped-worker.xpc" \
    "${worker_symlink_directory}/WALITranscoder.xpc"
expect_verifier_failure \
    "worker-root-symlink" \
    Release \
    "${worker_symlink}" \
    "WALITranscoder.xpc root must not be a symbolic link"

# A renamed Release must reject each legacy peer independently before signing.
for role in WALI WALIAgent WALITranscoder WALILockScreenHelper; do
    app="$(new_fixture "legacy-${role}" io.github.codewithinferno.wali.WALI io.github.codewithinferno.wali.WALIAgent io.github.codewithinferno.wali.WALITranscoder)"
    case "${role}" in
        WALI) bundle="${app}"; label="main app" ;;
        WALIAgent) bundle="${app}/Contents/Library/LoginItems/WALIAgent.app"; label="agent" ;;
        WALITranscoder) bundle="${app}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc"; label="transcoder" ;;
        WALILockScreenHelper) bundle="${app}/Contents/Library/LoginItems/WALILockScreenHelper.app"; label="lock screen helper" ;;
    esac
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wali.${role}" "${bundle}/Contents/Info.plist"
    expect_verifier_failure "legacy ${role} identity" Release "${app}" "incorrect Release ${label} bundle identifier"
done

for field in WALIControlServiceName WALIAgentLaunchAgentPlistName WALILockScreenHelperLaunchAgentPlistName; do
    app="$(new_fixture "stale-${field}" io.github.codewithinferno.wali.WALI io.github.codewithinferno.wali.WALIAgent io.github.codewithinferno.wali.WALITranscoder)"
    /usr/libexec/PlistBuddy -c "Set :${field} com.wali.stale" "${app}/Contents/Info.plist"
    expect_verifier_failure "stale ${field}" Release "${app}" "incorrect ${field} runtime identity metadata"
done

for field in WALITranscoderServiceName WALILockScreenHelperServiceName WALILockScreenHelperBundleIdentifier; do
    app="$(new_fixture "stale-${field}" io.github.codewithinferno.wali.WALI io.github.codewithinferno.wali.WALIAgent io.github.codewithinferno.wali.WALITranscoder)"
    /usr/libexec/PlistBuddy -c "Set :${field} com.wali.stale" "${app}/Contents/Library/LoginItems/WALIAgent.app/Contents/Info.plist"
    expect_verifier_failure "stale ${field}" Release "${app}" "incorrect ${field} runtime identity metadata"
done

for role in WALIAgent WALILockScreenHelper; do
    app="$(new_fixture "stale-launch-${role}" io.github.codewithinferno.wali.WALI io.github.codewithinferno.wali.WALIAgent io.github.codewithinferno.wali.WALITranscoder)"
    plist="${app}/Contents/Library/LaunchAgents/io.github.codewithinferno.wali.${role}.plist"
    /usr/libexec/PlistBuddy -c "Set :Label com.wali.${role}" "${plist}"
    expect_verifier_failure "legacy ${role} launch label" Release "${app}" "incorrect ${role} launch identity or lifecycle metadata"
    rm "${plist}"
    expect_verifier_failure "missing ${role} selected launch plist" Release "${app}" "missing ${role} selected launch plist"
done

worker_client_app="$(new_fixture stale-worker-client io.github.codewithinferno.wali.WALI io.github.codewithinferno.wali.WALIAgent io.github.codewithinferno.wali.WALITranscoder)"
/usr/libexec/PlistBuddy -c 'Set :WALIExpectedClientBundleIdentifier com.wali.WALIAgent' \
    "${worker_client_app}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/Info.plist"
expect_verifier_failure "legacy worker expected client" Release "${worker_client_app}" \
    "incorrect WALIExpectedClientBundleIdentifier runtime identity metadata"

if (( failure_count > 0 )); then
    printf 'Bundle verifier fixture failures: %s; passes: %s\n' \
        "${failure_count}" "${pass_count}" >&2
    exit 1
fi

printf 'Bundle verifier regression tests passed: %s\n' "${pass_count}"
