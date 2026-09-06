#!/bin/bash
# Empaqueta MacTools.app en un DMG listo para mandar.
#
# Sin cuenta de Apple Developer el DMG funciona igual, pero macOS muestra una advertencia la
# primera vez y hay que abrir la app con clic derecho. Con una cuenta:
#
#   export MACTOOLS_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)"
#   export MACTOOLS_NOTARY_PROFILE="mactools"   # xcrun notarytool store-credentials
#   ./release.sh
#
# y sale firmado y notarizado: doble clic y abre, sin advertencias.

set -euo pipefail
cd "$(dirname "$0")"

APP="MacTools.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
OUT="dist"
DMG="$OUT/MacTools-$VERSION.dmg"

./build.sh

rm -rf "$OUT" && mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/$APP"
ln -s /Applications "$OUT/stage/Applications"

if [ -n "${MACTOOLS_IDENTITY:-}" ]; then
    echo "Firmando con $MACTOOLS_IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$MACTOOLS_IDENTITY" "$OUT/stage/$APP"
else
    cat > "$OUT/stage/LEEME - como abrirla.txt" <<'TXT'
MacTools no esta firmada con una cuenta de Apple Developer, asi que la primera vez
macOS avisa que "no se puede comprobar que no contiene malware".

Para abrirla:

  1. Arrastra MacTools a la carpeta Aplicaciones.
  2. En Aplicaciones, hace CLIC DERECHO sobre MacTools y elegi "Abrir".
  3. En el cartel, apreta "Abrir" de nuevo.

Solo hace falta la primera vez. Despues abre normal.

Requiere macOS 14 o mas nuevo.
TXT
fi

hdiutil create -volname "MacTools" -srcfolder "$OUT/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/stage"

if [ -n "${MACTOOLS_NOTARY_PROFILE:-}" ]; then
    echo "Notarizando…"
    xcrun notarytool submit "$DMG" --keychain-profile "$MACTOOLS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Notarizado: abre con doble clic en cualquier Mac."
else
    echo
    echo "Sin notarizar. Quien lo baje tiene que abrirlo con clic derecho la primera vez;"
    echo "el DMG ya lleva un LEEME con el paso a paso."
fi

echo
echo "Listo: $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
