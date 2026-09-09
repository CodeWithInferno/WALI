#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

XCODEGEN="$("${ROOT_DIR}/scripts/resolve-xcodegen.sh")"
"${XCODEGEN}" generate

# Xcode's workspace is generated; the reviewed package graph survives clean.
RESOLVED_DIR="${ROOT_DIR}/WALI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "${RESOLVED_DIR}"
cp "${ROOT_DIR}/Config/Package.resolved" "${RESOLVED_DIR}/Package.resolved"
