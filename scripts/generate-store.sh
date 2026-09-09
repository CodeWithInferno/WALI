#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
XCODEGEN="$("${ROOT_DIR}/scripts/resolve-xcodegen.sh")"
"${XCODEGEN}" generate --spec project-store.yml
RESOLVED_DIR="${ROOT_DIR}/WALIStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "${RESOLVED_DIR}"
cp "${ROOT_DIR}/Config/Package.resolved" "${RESOLVED_DIR}/Package.resolved"
