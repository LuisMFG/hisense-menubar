#!/bin/bash
# Compila e empacota "Ar Condicionado.app" (só barra de menus, sem ícone no Dock).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Ar Condicionado.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ArCondicionado "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ar Condicionado</string>
  <key>CFBundleIdentifier</key><string>dev.local.ArCondicionado</string>
  <key>CFBundleExecutable</key><string>ArCondicionado</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Pronto: $APP"
