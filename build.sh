#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

rm -rf dist/Clicker.app
mkdir -p dist/Clicker.app/Contents/MacOS dist/Clicker.app/Contents/Resources
cp -X .build/release/Clicker dist/Clicker.app/Contents/MacOS/Clicker
cp -X Info.plist dist/Clicker.app/Contents/Info.plist
cp -X AppIcon.icns dist/Clicker.app/Contents/Resources/AppIcon.icns
[ -x vendor/atvbridge/atvbridge ] && ditto vendor/atvbridge dist/Clicker.app/Contents/Resources/atvbridge
codesign --force --sign - dist/Clicker.app

echo "Built dist/Clicker.app"

# Install into /Applications (fall back to ~/Applications).
TARGET="/Applications/Clicker.app"
if ! { rm -rf "$TARGET" 2>/dev/null && cp -R dist/Clicker.app "$TARGET" 2>/dev/null; }; then
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/Clicker.app"
    rm -rf "$TARGET"
    cp -R dist/Clicker.app "$TARGET"
fi
echo "Installed $TARGET"
