#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
version="$(tr -d '\n' < VERSION)"
swift build -c release --scratch-path "$project_root/.build-release"
binary_dir="$(swift build -c release --scratch-path "$project_root/.build-release" --show-bin-path)"
app="$project_root/outputs/bgMon.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/bgMon" "$app/Contents/MacOS/bgMon"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>bgMon</string>
<key>CFBundleIdentifier</key><string>app.bgmon.bgMon</string>
<key>CFBundleName</key><string>bgMon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
staging="$(mktemp -d /tmp/bgMon-dmg.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/bgMon.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "bgMon $version" -srcfolder "$staging" -ov -format UDZO "$project_root/outputs/bgMon-$version-arm64.dmg"
hdiutil verify "$project_root/outputs/bgMon-$version-arm64.dmg"
