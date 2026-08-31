#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

XCODEGEN="$("${ROOT_DIR}/scripts/resolve-xcodegen.sh")"
"${XCODEGEN}" generate

