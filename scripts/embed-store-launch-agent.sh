#!/usr/bin/env bash
# Xcode build phase only: copy the selected Store launch plist before code signing.
set -euo pipefail
: "${SRCROOT:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${WALI_AGENT_BUNDLE_IDENTIFIER:?}"
case "${WALI_AGENT_BUNDLE_IDENTIFIER}" in
    com.wali.store.development.WALIAgent|com.wali.store.WALIAgent) ;;
    *) printf 'Unsupported Store agent identity\n' >&2; exit 1;;
esac
SOURCE="${SRCROOT}/Config/StoreLaunchAgents/${WALI_AGENT_BUNDLE_IDENTIFIER}.plist"
DESTINATION="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
[[ -f "${SOURCE}" && ! -L "${SOURCE}" && ! -L "${DESTINATION}" ]] || exit 1
mkdir -p "${DESTINATION}"
# Remove only the two known generated channel plists from this build product.
rm -f "${DESTINATION}/com.wali.store.development.WALIAgent.plist" \
    "${DESTINATION}/com.wali.store.WALIAgent.plist"
/bin/cp "${SOURCE}" "${DESTINATION}/${WALI_AGENT_BUNDLE_IDENTIFIER}.plist"
