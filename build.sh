#!/bin/bash
# Builds MacTools.app without Xcode: SPM binary + hand-assembled bundle + ad-hoc signature.
# No Accessibility permission is needed (the hotkey uses Carbon RegisterEventHotKey), so the
# ad-hoc cdhash changing on every rebuild costs nothing.

set -euo pipefail

cd "$(dirname "$0")"
APP="MacTools.app"
VERSION="0.1.0"

swift build -c release

if [ ! -f MacTools.icns ]; then
    rm -rf MacTools.iconset
    swift Tools/make-icon.swift MacTools.iconset
    iconutil -c icns MacTools.iconset -o MacTools.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacTools "$APP/Contents/MacOS/MacTools"
cp MacTools.icns "$APP/Contents/Resources/MacTools.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MacTools</string>
	<!-- El identificador se queda: cambiarlo huerfana los permisos de TCC y las preferencias
	     guardadas, que es exactamente lo que costo semanas arreglar. -->
	<key>CFBundleIdentifier</key><string>dev.isidropasman.pila</string>
	<key>CFBundleName</key><string>MacTools</string>
	<key>CFBundleDisplayName</key><string>MacTools</string>
	<key>CFBundleIconFile</key><string>MacTools</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSAppleEventsUsageDescription</key><string>MacTools lee y controla la reproduccion de Spotify y Music para mostrarla en la notch.</string>
	<key>NSCalendarsUsageDescription</key><string>MacTools muestra tus proximos eventos del dia en la notch.</string>
	<key>NSCalendarsFullAccessUsageDescription</key><string>MacTools muestra tus proximos eventos del dia en la notch.</string>
	<key>NSHumanReadableCopyright</key><string>Isidro Pasman</string>
</dict>
</plist>
PLIST

# A stable self-signed identity keeps the designated requirement tied to the certificate instead
# of the cdhash, so macOS permissions (Accessibility, Calendar) survive a rebuild. Falls back to
# ad-hoc if the keychain is missing, which just means granting permissions again after each build.
KEYCHAIN="$HOME/Library/Keychains/pila.keychain-db"
# El nombre de la identidad se queda: el requisito designado de la firma la referencia, y
# regenerarla reseteria todos los permisos.
IDENTITY="Pila Local Signing"
if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p pila "$KEYCHAIN" >/dev/null 2>&1 || true
    codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier dev.isidropasman.pila "$APP"
else
    echo "AVISO: firmando ad-hoc; los permisos se van a resetear en cada build"
    codesign --force --sign - --identifier dev.isidropasman.pila "$APP"
fi

echo "Listo: $(pwd)/$APP"

# Install without re-signing: a second codesign pass would change the cdhash and
# silently invalidate the Accessibility grant macOS recorded for the previous one.
if [ "${1:-}" = "install" ]; then
    pkill -f "MacTools.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Pila.app /Applications/MacTools.app
    cp -R "$APP" /Applications/MacTools.app
    open -a /Applications/MacTools.app
    echo "Instalado en /Applications/MacTools.app (firma intacta)"
fi
