#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
cd "${ROOT_DIR}"
if [[ "$(git rev-parse --is-shallow-repository)" != false ]]; then
    printf 'Secret scanning requires complete fetched history; unshallow the checkout first.\n' >&2
    exit 2
fi
if [[ "$("${GITLEAKS_BIN}" version)" != 8.30.1 ]]; then
    printf 'Secret scanning requires the reviewed Gitleaks 8.30.1 binary.\n' >&2
    exit 2
fi

# Do not follow an existing report symlink or expose raw findings as artifacts.
if [[ -L .build || -L .build/security ]]; then
    printf 'Secret report directory cannot be a symlink.\n' >&2
    exit 2
fi
umask 077
mkdir -p .build/security
SCAN_TEMP="$(mktemp -d "${ROOT_DIR}/.build/security/scan.XXXXXX")"
trap 'rm -rf "${SCAN_TEMP}"' EXIT
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
set +e
"${GITLEAKS_BIN}" git "${ROOT_DIR}" \
    --log-opts='--all --full-history' \
    --config "${ROOT_DIR}/.gitleaks.toml" \
    --gitleaks-ignore-path "${ROOT_DIR}/.gitleaksignore" \
    --ignore-gitleaks-allow --redact=100 --no-banner --no-color \
    --report-format json --report-path "${SCAN_TEMP}/history.json" --exit-code 1
scan_exit=$?
set -e
if [[ -f "${SCAN_TEMP}/history.json" ]]; then
    mv -f "${SCAN_TEMP}/history.json" "${ROOT_DIR}/.build/security/gitleaks-history.json"
    printf 'Redacted history scan report: .build/security/gitleaks-history.json\n'
fi
exit "${scan_exit}"
