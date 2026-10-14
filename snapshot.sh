#!/bin/bash
# Gera as imagens do README com dados fictícios — não fala com o ar de verdade.
#   docs/*.png        → inglês
#   docs/pt-BR/*.png  → português
set -euo pipefail
cd "$(dirname "$0")"
APP=.build/Snapshot.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/snapshot" \
  Sources/ArCondicionado/{ACStore,ConnectLifeAPI,Views,Effects}.swift Snapshot/Snapshot.swift
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.local.ArCondicionado.snapshot</string>
  <key>CFBundleExecutable</key><string>snapshot</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
mkdir -p docs/pt-BR
"$APP/Contents/MacOS/snapshot" docs -AppleLanguages '(en)'
"$APP/Contents/MacOS/snapshot" docs/pt-BR -AppleLanguages '(pt-BR)'
