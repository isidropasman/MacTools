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
OUT="dist"

# Despues de compilar: leerla antes tomaba la version del build anterior.
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/MacTools-$VERSION.dmg"

rm -rf "$OUT" && mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/$APP"
ln -s /Applications "$OUT/stage/Applications"

if [ -n "${MACTOOLS_IDENTITY:-}" ]; then
    echo "Firmando con $MACTOOLS_IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$MACTOOLS_IDENTITY" "$OUT/stage/$APP"
else
    # Ad-hoc y no con el certificado local: ese certificado solo existe en la Mac que compila,
    # y en cualquier otra aparece como una autoridad desconocida.
    codesign --force --deep --sign - "$OUT/stage/$APP"

    cat > "$OUT/stage/LEEME - como abrirla.txt" <<'TXT'
MacTools no esta notarizada con una cuenta de Apple Developer, asi que macOS la
bloquea la primera vez: "Apple no ha podido verificar que no contenga software
malicioso".

LA FORMA FACIL (recomendada), con Homebrew:

    brew install --cask isidropasman/tap/mactools

Instala y abre sin ningun cartel.

DESDE ESTE DMG:

  1. Arrastra MacTools a la carpeta Aplicaciones.
  2. Abrila. Va a aparecer el cartel; apreta "Aceptar".
  3. Anda a Ajustes del Sistema > Privacidad y Seguridad, baja hasta
     "Seguridad" y apreta "Abrir igualmente" al lado de MacTools.
  4. Confirma con "Abrir".

Desde macOS 15 el viejo truco del clic derecho ya no alcanza; hay que pasar por
Ajustes del Sistema. Solo hace falta la primera vez.

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
