#!/usr/bin/env bash
set -euo pipefail

candidate="${XCODEGEN_BIN:-xcodegen}"
resolved="$(command -v "${candidate}" 2>/dev/null || true)"

if [[ -z "${resolved}" || ! -x "${resolved}" ]]; then
    if [[ -n "${XCODEGEN_BIN:-}" ]]; then
        printf 'XCODEGEN_BIN does not resolve to an executable: %s\n' "${candidate}" >&2
    else
        printf 'XcodeGen was not found on PATH; install it or set XCODEGEN_BIN.\n' >&2
    fi
    exit 1
fi

printf '%s\n' "${resolved}"

