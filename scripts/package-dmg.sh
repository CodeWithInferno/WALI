#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DMG_KIND="${DMG_KIND:-local}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/xcode/DerivedData}"

fail() { printf 'DMG packaging failed: %s\n' "$1" >&2; exit 1; }
if [[ "${1:-}" == "--help" ]]; then
    printf 'Usage: CONFIGURATION=Debug %s [WALI.app] [output.dmg]\n' "$0"
    printf 'Packages an existing build for local use, preserving its signature. Release distribution is managed by fastlane.\n'
    exit 0
fi
[[ $# -le 2 ]] || fail "Expected at most an app path and output path."
case "${CONFIGURATION}" in Debug|Development|Release) ;; *) fail "Unsupported configuration." ;; esac
case "${DMG_KIND}" in local|distribution) ;; *) fail "DMG_KIND must be local or distribution." ;; esac
command -v "${PYTHON_BIN}" >/dev/null || fail "Python 3 is required for Finder metadata (standard library only)."
"${PYTHON_BIN}" -B "${ROOT_DIR}/Tests/Bundle/dmg-metadata-tests.py"
APP_PATH="${1:-${APP_PATH:-${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/WALI.app}}"
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "The existing app bundle was not found. Build it first."
APP_PATH="$(cd "$(dirname "${APP_PATH}")" && pwd -P)/$(basename "${APP_PATH}")"
[[ "$(basename "${APP_PATH}")" == "WALI.app" ]] || fail "The source bundle must be named WALI.app."
CONFIGURATION="${CONFIGURATION}" "${ROOT_DIR}/scripts/verify-bundle.sh" "${APP_PATH}"
/usr/bin/xcrun swift -module-cache-path "${ROOT_DIR}/.build/dmg-swift-cache" "${ROOT_DIR}/scripts/verify-branding.swift" "${APP_PATH}"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
[[ "${VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${BUILD}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid version or build identifier."
if [[ "${DMG_KIND}" == "distribution" ]]; then
    [[ "${CONFIGURATION}" == "Release" ]] || fail "Distribution packaging requires a signed Release candidate."
    /usr/bin/xcrun stapler validate "${APP_PATH}"
    VOLUME_NAME="WALI"
    PACKAGE_NAME="WALI-${VERSION}-${BUILD}-macOS.dmg"
else
    VOLUME_NAME="WALI Local ${CONFIGURATION}"
    PACKAGE_NAME="WALI-${VERSION}-${BUILD}-local-${CONFIGURATION}.dmg"
fi
OUTPUT_PATH="${2:-${DMG_OUTPUT:-${ROOT_DIR}/.build/packages/${PACKAGE_NAME}}}"
[[ "${OUTPUT_PATH}" == *.dmg ]] || fail "Output must have a .dmg extension."
[[ ! -d "${OUTPUT_PATH}" && ! -L "${OUTPUT_PATH}" ]] || fail "Output must be a regular file path."
[[ ! -d "${OUTPUT_PATH}.sha256" && ! -L "${OUTPUT_PATH}.sha256" ]] || fail "Checksum output must be a regular file path."
OUTPUT_PATH="$("${PYTHON_BIN}" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${OUTPUT_PATH}")"
case "${OUTPUT_PATH}" in "${APP_PATH}"/*) fail "Output cannot be inside the source app." ;; esac
mkdir -p "$(dirname "${OUTPUT_PATH}")"

BRANDING="${ROOT_DIR}/Resources/Branding"
for asset in WALI-Volume.icns dmg-background.png dmg-background@2x.png; do
    [[ -s "${BRANDING}/${asset}" ]] || fail "Missing branding asset: ${asset}"
done
"${PYTHON_BIN}" - "${BRANDING}" <<'PY'
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
for name, expected in [('dmg-background.png', (660, 440)), ('dmg-background@2x.png', (1320, 880))]:
    header = (root / name).read_bytes()[:24]
    if header[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', header[16:24]) != expected:
        sys.exit(f'DMG packaging failed: {name} must be a {expected[0]}x{expected[1]} PNG.')
PY
WORK_DIR="$(mktemp -d "$(dirname "${OUTPUT_PATH}")/.wali-dmg.XXXXXX")"
MOUNT_PATH="${WORK_DIR}/volume"
MOUNTED=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "${MOUNTED}" == 1 ]]; then
        if ! /usr/bin/hdiutil detach "${MOUNT_PATH}" -quiet; then
            /usr/bin/hdiutil detach "${MOUNT_PATH}" -force -quiet || {
                printf 'Could not detach temporary image; retained staging at %s\n' "${WORK_DIR}" >&2
                exit 1
            }
        fi
    fi
    rm -rf "${WORK_DIR}"
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${WORK_DIR}/content/.background" "${MOUNT_PATH}"
/usr/bin/ditto "${APP_PATH}" "${WORK_DIR}/content/WALI.app"
ln -s /Applications "${WORK_DIR}/content/Applications"
cp "${BRANDING}/WALI-Volume.icns" "${WORK_DIR}/content/.VolumeIcon.icns"
/usr/bin/sips -s format tiff -s dpiWidth 72 -s dpiHeight 72 "${BRANDING}/dmg-background.png" --out "${WORK_DIR}/background.tiff" >/dev/null
/usr/bin/sips -s format tiff -s dpiWidth 144 -s dpiHeight 144 "${BRANDING}/dmg-background@2x.png" --out "${WORK_DIR}/background@2x.tiff" >/dev/null
/usr/bin/tiffutil -cathidpicheck "${WORK_DIR}/background.tiff" "${WORK_DIR}/background@2x.tiff" -out "${WORK_DIR}/content/.background/background.tiff"
/usr/bin/hdiutil create -quiet -volname "${VOLUME_NAME}" -fs HFS+ -format UDRW -srcfolder "${WORK_DIR}/content" "${WORK_DIR}/writable.dmg"
/usr/bin/hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "${MOUNT_PATH}" "${WORK_DIR}/writable.dmg"
MOUNTED=1
/usr/bin/SetFile -a C "${MOUNT_PATH}"
"${PYTHON_BIN}" "${ROOT_DIR}/scripts/package-dmg-metadata.py" write "${MOUNT_PATH}"
"${PYTHON_BIN}" "${ROOT_DIR}/scripts/package-dmg-metadata.py" verify "${MOUNT_PATH}"
/usr/bin/hdiutil detach "${MOUNT_PATH}" -quiet
MOUNTED=0
/usr/bin/hdiutil convert -quiet "${WORK_DIR}/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "${WORK_DIR}/finished.dmg"
/usr/bin/hdiutil verify "${WORK_DIR}/finished.dmg"
# A different mount point proves the background alias survives relocation.
MOUNT_PATH="${WORK_DIR}/verification-volume"
mkdir "${MOUNT_PATH}"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "${MOUNT_PATH}" "${WORK_DIR}/finished.dmg"
MOUNTED=1
"${PYTHON_BIN}" "${ROOT_DIR}/scripts/package-dmg-metadata.py" verify "${MOUNT_PATH}"
CONFIGURATION="${CONFIGURATION}" "${ROOT_DIR}/scripts/verify-bundle.sh" "${MOUNT_PATH}/WALI.app"
/usr/bin/diff -qr "${APP_PATH}" "${MOUNT_PATH}/WALI.app" >/dev/null || fail "Packaged app bytes differ from the source bundle."
/usr/bin/hdiutil detach "${MOUNT_PATH}" -quiet
MOUNTED=0
"${PYTHON_BIN}" - "${WORK_DIR}/finished.dmg" "${OUTPUT_PATH}" <<'PY'
import hashlib
import os
from pathlib import Path
import sys
path, destination = map(Path, sys.argv[1:])
digest = hashlib.sha256()
with path.open('rb') as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(chunk)
checksum = path.with_suffix('.sha256')
with checksum.open('x') as output:
    output.write(f'{digest.hexdigest()}  {destination.name}\n')
    output.flush()
    os.fsync(output.fileno())
# Replace directory entries, never follow a pre-existing output symlink.
os.replace(path, destination)
os.replace(checksum, Path(str(destination) + '.sha256'))
PY
if [[ "${DMG_KIND}" == "local" ]]; then
    printf 'Local %s disk image; app signature preserved, image not signed or notarized: %s\n' "${CONFIGURATION}" "${OUTPUT_PATH}"
else
    printf 'Packaged notarized app; disk image still requires signing and notarization: %s\n' "${OUTPUT_PATH}"
fi
