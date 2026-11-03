#!/bin/zsh
# Builds Keno.app (release, optimized for this Mac) and installs it to /Applications,
# replacing the previous version. Use --no-install to only build into ./build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Keno"

# Staging folder ends in .noindex so Spotlight/Launchpad never list a second copy.
STAGE="build.noindex"
APP="$STAGE/Keno.app"
rm -rf "$APP" build/Keno.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keno"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
cp Resources/ThirdPartyLicenses.txt "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/Keno"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--no-install" ]]; then exit 0; fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf /Applications/Keno.app            # remove the previous version
ditto "$APP" /Applications/Keno.app
"$LSREGISTER" -f /Applications/Keno.app
rm -rf "$APP"                            # keep exactly one copy on the system
echo "Installed /Applications/Keno.app"
if pgrep -xq Keno; then echo "Keno is running: quit and reopen it to use the new version."; fi
