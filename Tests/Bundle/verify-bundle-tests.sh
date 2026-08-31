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

    cat > "${app_path}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALI</string>
  <key>CFBundleIdentifier</key><string>${app_identifier}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
EOF

    cat > "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WALIAgent</string>
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
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/MacOS" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/MacOS"

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
        "${fixture_root}/main.c" \
        -o "${app_path}/Contents/MacOS/WALI"
    cp \
        "${app_path}/Contents/MacOS/WALI" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/MacOS/WALIAgent"
    cp \
        "${app_path}/Contents/MacOS/WALI" \
        "${app_path}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc/Contents/MacOS/WALITranscoder"

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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
CONFIGURATION=Release "${VERIFIER}" "${release_app}" >/dev/null
pass_count=$((pass_count + 1))

development_app="$(new_fixture \
    development-adhoc \
    com.wali.development.WALI \
    com.wali.development.WALIAgent \
    com.wali.development.WALITranscoder)"
development_root="${TEMP_ROOT}/development-adhoc"
agent_path="${development_app}/Contents/Library/LoginItems/WALIAgent.app"
worker_path="${agent_path}/Contents/XPCServices/WALITranscoder.xpc"

write_entitlements \
    "${development_root}/worker.entitlements" \
    TESTTEAM01.com.wali.development.WALITranscoder \
    no
write_entitlements \
    "${development_root}/agent.entitlements" \
    TESTTEAM01.com.wali.development.WALIAgent \
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
release_adhoc_root="${TEMP_ROOT}/release-adhoc"
release_adhoc_agent="${release_adhoc}/Contents/Library/LoginItems/WALIAgent.app"
release_adhoc_worker="${release_adhoc_agent}/Contents/XPCServices/WALITranscoder.xpc"
write_release_entitlements \
    "${release_adhoc_root}/worker.entitlements" \
    com.wali.WALITranscoder \
    no
write_release_entitlements \
    "${release_adhoc_root}/agent.entitlements" \
    com.wali.WALIAgent \
    yes
write_release_entitlements \
    "${release_adhoc_root}/app.entitlements" \
    com.wali.WALI \
    yes
/usr/bin/codesign \
    --force --sign - --timestamp=none --options runtime \
    --entitlements "${release_adhoc_root}/worker.entitlements" \
    "${release_adhoc_worker}"
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
    "Release verification requires unsealed credential-free bundles"

release_fake_seal="$(new_fixture \
    release-fake-seal \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
for bundle_path in \
    "${release_fake_seal}" \
    "${release_fake_seal}/Contents/Library/LoginItems/WALIAgent.app" \
    "${release_fake_seal}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc"; do
    mkdir -p "${bundle_path}/Contents/_CodeSignature"
    : > "${bundle_path}/Contents/_CodeSignature/CodeResources"
done
expect_verifier_failure \
    "release-sealed-wrappers" \
    Release \
    "${release_fake_seal}" \
    "Release verification requires unsealed credential-free bundles"

release_partial="$(new_fixture \
    release-partial-seal \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
mkdir -p \
    "${release_partial}/Contents/Library/LoginItems/WALIAgent.app/Contents/_CodeSignature"
: > \
    "${release_partial}/Contents/Library/LoginItems/WALIAgent.app/Contents/_CodeSignature/CodeResources"
expect_verifier_failure \
    "release-partial-seal" \
    Release \
    "${release_partial}" \
    "Release verification requires unsealed credential-free bundles"

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
    "Debug verification requires unsealed credential-free bundles"

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

main_xpc="$(new_fixture \
    main-xpc \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
mkdir -p "${main_xpc}/Contents/XPCServices"
: > "${main_xpc}/Contents/XPCServices/.unexpected"
expect_verifier_failure \
    "main-app-xpc-hidden-entry" \
    Release \
    "${main_xpc}" \
    "stale topology: main app Contents/XPCServices must be absent or empty"

duplicate_login="$(new_fixture \
    duplicate-login \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
mkdir -p "${duplicate_login}/Contents/Library/LoginItems/Other.app"
expect_verifier_failure \
    "duplicate-login-item" \
    Release \
    "${duplicate_login}" \
    "expected exactly one embedded login item"

hidden_login="$(new_fixture \
    hidden-login \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
: > "${hidden_login}/Contents/Library/LoginItems/.unexpected"
expect_verifier_failure \
    "hidden-login-item" \
    Release \
    "${hidden_login}" \
    "expected exactly one embedded login item"

wrong_login="$(new_fixture \
    wrong-login \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
mkdir -p \
    "${duplicate_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/Other.xpc"
expect_verifier_failure \
    "duplicate-xpc-service" \
    Release \
    "${duplicate_xpc}" \
    "expected exactly one agent-private XPC service"

hidden_xpc="$(new_fixture \
    hidden-xpc \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
: > \
    "${hidden_xpc}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/.unexpected"
expect_verifier_failure \
    "hidden-xpc-service" \
    Release \
    "${hidden_xpc}" \
    "expected exactly one agent-private XPC service"

wrong_xpc="$(new_fixture \
    wrong-xpc \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
rm -rf \
    "${partial_topology}/Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices"
expect_verifier_failure \
    "partial-topology" \
    Release \
    "${partial_topology}" \
    "missing WALIAgent.app/Contents/XPCServices"

root_target="$(new_fixture \
    root-symlink-target \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
mkdir -p "${TEMP_ROOT}/root-symlink"
ln -s "${root_target}" "${TEMP_ROOT}/root-symlink/WALI.app"
expect_verifier_failure \
    "app-root-symlink" \
    Release \
    "${TEMP_ROOT}/root-symlink/WALI.app/" \
    "WALI.app root must not be a symbolic link"

login_symlink="$(new_fixture \
    login-directory-symlink \
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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
    com.wali.WALI \
    com.wali.WALIAgent \
    com.wali.WALITranscoder)"
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

if (( failure_count > 0 )); then
    printf 'Bundle verifier fixture failures: %s; passes: %s\n' \
        "${failure_count}" "${pass_count}" >&2
    exit 1
fi

printf 'Bundle verifier regression tests passed: %s\n' "${pass_count}"
