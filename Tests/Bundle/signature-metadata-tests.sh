#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT_DIR}/scripts/validate-signature-metadata.rb"
RUBY_BIN="/usr/bin/ruby"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

pass_count=0
failure_count=0

new_metadata() {
    local name="$1"
    local identifier="$2"
    local include_group="$3"
    local path="${TEMP_ROOT}/${name}.json"

    "${RUBY_BIN}" -rjson -e '
        path, identifier, include_group = ARGV
        entitlements = {
          "com.apple.developer.team-identifier" => "TESTTEAM01",
          "com.apple.application-identifier" => "TESTTEAM01.#{identifier}"
        }
        if include_group == "yes"
          entitlements["com.apple.security.application-groups"] = [
            "group.com.wali.development.shared"
          ]
        end
        metadata = {
          "sealed" => true,
          "strict_valid" => true,
          "signature" => "cms",
          "authorities" => ["Apple Development: Fixture"],
          "team_identifier" => "TESTTEAM01",
          "runtime" => true,
          "entitlements" => entitlements
        }
        File.write(path, JSON.pretty_generate(metadata))
    ' "${path}" "${identifier}" "${include_group}"
    printf '%s\n' "${path}"
}

mutate_metadata() {
    local path="$1"
    local mutation="$2"

    "${RUBY_BIN}" -rjson -e '
        path, mutation = ARGV
        data = JSON.parse(File.read(path))
        eval(mutation, binding, path)
        File.write(path, JSON.pretty_generate(data))
    ' "${path}" "${mutation}"
}

validator_arguments() {
    local label="$1"
    local identifier="$2"
    local expected_group="$3"
    local configuration="${4:-Development}"

    printf '%s\0' \
        --configuration "${configuration}" \
        --label "${label}" \
        --bundle-identifier "${identifier}" \
        --team TESTTEAM01 \
        --app-group "${expected_group}"
}

run_validator() {
    local metadata="$1"
    local label="$2"
    local identifier="$3"
    local expected_group="$4"
    local configuration="${5:-Development}"
    local -a arguments=()

    while IFS= read -r -d '' argument; do
        arguments+=("${argument}")
    done < <(validator_arguments "${label}" "${identifier}" "${expected_group}" "${configuration}")

    "${VALIDATOR}" "${arguments[@]}" < "${metadata}"
}

expect_success() {
    local name="$1"
    local metadata="$2"
    local label="$3"
    local identifier="$4"
    local expected_group="$5"
    local configuration="${6:-Development}"
    local output="${TEMP_ROOT}/${name}.out"

    if run_validator \
        "${metadata}" "${label}" "${identifier}" "${expected_group}" "${configuration}" \
        >"${output}" 2>&1; then
        pass_count=$((pass_count + 1))
    else
        printf 'RED GAP: %s expected metadata success\n' "${name}" >&2
        /usr/bin/awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
    fi
}

expect_failure() {
    local name="$1"
    local metadata="$2"
    local label="$3"
    local identifier="$4"
    local expected_group="$5"
    local expected="$6"
    local configuration="${7:-Development}"
    local output="${TEMP_ROOT}/${name}.out"

    if run_validator \
        "${metadata}" "${label}" "${identifier}" "${expected_group}" "${configuration}" \
        >"${output}" 2>&1; then
        printf 'RED GAP: %s expected metadata failure\n' "${name}" >&2
        failure_count=$((failure_count + 1))
    elif ! "${RUBY_BIN}" -e \
        'exit(File.read(ARGV.fetch(0)).include?(ARGV.fetch(1)) ? 0 : 1)' \
        "${output}" "${expected}"; then
        printf 'RED GAP: %s did not report: %s\n' "${name}" "${expected}" >&2
        /usr/bin/awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
    else
        pass_count=$((pass_count + 1))
    fi
}

app_identifier="com.wali.development.WALI"
valid_app="$(new_metadata valid-app "${app_identifier}" yes)"
expect_success \
    "valid app metadata" \
    "${valid_app}" \
    "WALI.app" \
    "${app_identifier}" \
    "group.com.wali.development.shared"

declare -a app_failures=(
    'seal|data["sealed"] = false|bundle seal'
    'adhoc|data["signature"] = "adhoc"|ad-hoc signature'
    'strict|data["strict_valid"] = false|strict code-signature validation'
    'authority|data["authorities"] = ["Developer ID Application: Fixture"]|Apple Development: authority'
    'team|data["team_identifier"] = "WRONGTEAM1"|TeamIdentifier'
    'runtime|data["runtime"] = false|hardened runtime'
    'team-entitlement-missing|data["entitlements"].delete("com.apple.developer.team-identifier")|team entitlement is required'
    'team-entitlement-wrong|data["entitlements"]["com.apple.developer.team-identifier"] = "WRONGTEAM1"|team entitlement'
    'application-identifier-missing|data["entitlements"].delete("com.apple.application-identifier")|application identifier is required'
    'application-identifier-wrong|data["entitlements"]["com.apple.application-identifier"] = "TESTTEAM01.com.example.WALI"|application identifier'
    'group-missing|data["entitlements"].delete("com.apple.security.application-groups")|application group'
    'group-wrong|data["entitlements"]["com.apple.security.application-groups"] = ["group.example.shared"]|application group'
)

for entry in "${app_failures[@]}"; do
    IFS='|' read -r name mutation expected <<< "${entry}"
    metadata="${TEMP_ROOT}/${name}.json"
    cp "${valid_app}" "${metadata}"
    mutate_metadata "${metadata}" "${mutation}"
    expect_failure \
        "${name}" \
        "${metadata}" \
        "WALI.app" \
        "${app_identifier}" \
        "group.com.wali.development.shared" \
        "${expected}"
done

worker_identifier="com.wali.development.WALITranscoder"
valid_worker="$(new_metadata valid-worker "${worker_identifier}" no)"
expect_success \
    "valid worker metadata" \
    "${valid_worker}" \
    "WALITranscoder.xpc" \
    "${worker_identifier}" \
    ""

worker_optional_identity="${TEMP_ROOT}/worker-optional-identity.json"
cp "${valid_worker}" "${worker_optional_identity}"
mutate_metadata "${worker_optional_identity}" '
    data["entitlements"].delete("com.apple.developer.team-identifier")
    data["entitlements"].delete("com.apple.application-identifier")
'
expect_success \
    "worker optional identity metadata" \
    "${worker_optional_identity}" \
    "WALITranscoder.xpc" \
    "${worker_identifier}" \
    ""

worker_group="${TEMP_ROOT}/worker-group.json"
cp "${valid_worker}" "${worker_group}"
mutate_metadata \
    "${worker_group}" \
    'data["entitlements"]["com.apple.security.application-groups"] = ["group.com.wali.development.shared"]'
expect_failure \
    "worker application group" \
    "${worker_group}" \
    "WALITranscoder.xpc" \
    "${worker_identifier}" \
    "" \
    "must not claim an application group"

worker_identity="${TEMP_ROOT}/worker-identity.json"
cp "${valid_worker}" "${worker_identity}"
mutate_metadata \
    "${worker_identity}" \
    'data["entitlements"]["com.apple.application-identifier"] = "TESTTEAM01.com.example.worker"'
expect_failure \
    "worker application identifier" \
    "${worker_identity}" \
    "WALITranscoder.xpc" \
    "${worker_identifier}" \
    "" \
    "application identifier"

worker_team="${TEMP_ROOT}/worker-team.json"
cp "${valid_worker}" "${worker_team}"
mutate_metadata \
    "${worker_team}" \
    'data["entitlements"]["com.apple.developer.team-identifier"] = "WRONGTEAM1"'
expect_failure \
    "worker team entitlement" \
    "${worker_team}" \
    "WALITranscoder.xpc" \
    "${worker_identifier}" \
    "" \
    "team entitlement"

# Development retains its existing native authentication capability.
development_siwa="${TEMP_ROOT}/development-siwa.json"
cp "${valid_app}" "${development_siwa}"
mutate_metadata "${development_siwa}" 'data["entitlements"]["com.apple.developer.applesignin"] = ["Default"]'
expect_success "Development native Apple authentication" "${development_siwa}" \
    "WALI.app" "${app_identifier}" "group.com.wali.development.shared"

release_identifier="io.github.codewithinferno.wali.WALI"
valid_release="$(new_metadata valid-release "${release_identifier}" yes)"
mutate_metadata "${valid_release}" '
    data["authorities"] = ["Developer ID Application: Fixture"]
    data["timestamp"] = "2026-09-10T00:00:00Z"
    data["entitlements"]["com.apple.security.application-groups"] = ["group.com.wali.shared"]
'
expect_success "valid local-only Release signature" "${valid_release}" \
    "WALI.app" "${release_identifier}" "group.com.wali.shared" Release

for value in '["Default"]' '[]' 'false' 'nil'; do
    metadata="${TEMP_ROOT}/release-siwa.json"
    cp "${valid_release}" "${metadata}"
    mutate_metadata "${metadata}" "data[\"entitlements\"][\"com.apple.developer.applesignin\"] = ${value}"
    expect_failure "Release native Apple authentication ${value}" "${metadata}" \
        "WALI.app" "${release_identifier}" "group.com.wali.shared" \
        "Release foreground must not claim native Sign in with Apple" Release
done

declare -a release_failures=(
    'release-timestamp|data.delete("timestamp")|secure timestamp'
    'release-debugger|data["entitlements"]["com.apple.security.get-task-allow"] = true|debugger attachment'
    'release-authority|data["authorities"] = ["Apple Development: Fixture"]|Developer ID Application: authority'
    'release-identity|data["entitlements"]["com.apple.application-identifier"] = "TESTTEAM01.com.wali.WALI"|application identifier'
    'release-group|data["entitlements"]["com.apple.security.application-groups"] = ["group.example.shared"]|application group'
)
for entry in "${release_failures[@]}"; do
    IFS='|' read -r name mutation expected <<< "${entry}"
    metadata="${TEMP_ROOT}/${name}.json"
    cp "${valid_release}" "${metadata}"
    mutate_metadata "${metadata}" "${mutation}"
    expect_failure "${name}" "${metadata}" "WALI.app" "${release_identifier}" \
        "group.com.wali.shared" "${expected}" Release
done

if (( failure_count > 0 )); then
    printf 'Signature metadata fixture failures: %s; passes: %s\n' \
        "${failure_count}" "${pass_count}" >&2
    exit 1
fi

printf 'Signature metadata tests passed: %s\n' "${pass_count}"
