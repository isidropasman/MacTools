#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/LLMPet.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/llmpet "$APP/Contents/MacOS/LLMPet"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LLMPet</string>
  <key>CFBundleIdentifier</key><string>com.isidro.llmpet</string>
  <key>CFBundleExecutable</key><string>LLMPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>LLMPet usa Apple Events para traer al frente la pestaña de la sesión que clickeás.</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "→ $APP"
