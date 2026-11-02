#!/bin/zsh
# Builds Keno.app (release, optimized for this Mac) into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Keno"

APP="build/Keno.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keno"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
strip -x "$APP/Contents/MacOS/Keno"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Install:  cp -R $APP /Applications/"
