#!/bin/bash
# 构建 Desktopia.app（release），输出到 build/Desktopia.app
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.1.0"
APP="build/Desktopia.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Desktopia"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Desktopia"
rsync -a --exclude serve.mjs prototype/ "$APP/Contents/Resources/prototype/"
rsync -a themes-mac/ "$APP/Contents/Resources/themes-mac/"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.fancyecho.desktopia</string>
  <key>CFBundleName</key><string>Desktopia</string>
  <key>CFBundleDisplayName</key><string>Desktopia</string>
  <key>CFBundleExecutable</key><string>Desktopia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Unofficial macOS version based on Deskland Preview; not affiliated with the Deskland authors.</string>
</dict>
</plist>
PLIST

# 本机自签名（ad-hoc）：辅助功能权限和登录项都认签名，重新构建后可能需要重新授权
codesign --force --deep --sign - "$APP"
echo "已生成 $APP"
