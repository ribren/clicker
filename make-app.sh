#!/bin/zsh
# Build Clicker.app at the repo root, signed for distribution when a
# Developer ID certificate is available (hardened runtime + timestamp),
# falling back to ad-hoc signing otherwise. Run ./notarize.sh after this
# to notarize and staple.
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="Clicker.app"

# Frozen pyatv engine (built once; rebuild with tools/make-bridge.sh).
[ -x vendor/atvbridge/atvbridge ] || ./tools/make-bridge.sh

swift build -c release

# Assemble and sign OUTSIDE the repo: this checkout may live in an
# iCloud-synced folder, and the file provider stamps FinderInfo xattrs on the
# bundle that make codesign reject it ("detritus not allowed").
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/clicker-build.XXXXXX")
trap 'rm -rf "${STAGE}"' EXIT
BUILD_APP="${STAGE}/${APP_DIR}"

mkdir -p "${BUILD_APP}/Contents/MacOS" "${BUILD_APP}/Contents/Resources"
cp -X .build/release/Clicker "${BUILD_APP}/Contents/MacOS/Clicker"
cp -X Info.plist "${BUILD_APP}/Contents/Info.plist"
cp -X AppIcon.icns "${BUILD_APP}/Contents/Resources/AppIcon.icns"
ditto vendor/atvbridge "${BUILD_APP}/Contents/Resources/atvbridge"
xattr -cr "${BUILD_APP}" 2>/dev/null || true

SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Signing with Developer ID (hardened runtime + timestamp):"
    echo "    ${SIGN_IDENTITY}"
    echo "==> Signing embedded pyatv engine (every Mach-O in the bridge)..."
    find "${BUILD_APP}/Contents/Resources/atvbridge" -type f \
        \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) | while read -r f; do
        codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$f" 2>/dev/null || true
    done
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${BUILD_APP}"
else
    echo "==> No Developer ID certificate found; ad-hoc signing (local use only)."
    codesign --force --sign - "${BUILD_APP}"
fi

codesign --verify --strict "${BUILD_APP}"

rm -rf "${APP_DIR}"
ditto "${BUILD_APP}" "${APP_DIR}"
echo "==> Built ${APP_DIR}"
