# MacTools

Portapapeles, tareas, agenda, estante y sesiones de agentes, colgados de la notch.
App de barra de menú para macOS 14+, en Swift, sin dependencias externas.

**Para instalarla, no compiles: `brew install --cask isidropasman/tap/mactools`.**
El README de usuario vive en [el tap](https://github.com/isidropasman/homebrew-tap).

## Compilar

No hace falta Xcode, solo Command Line Tools.

```sh
./build.sh            # compila y arma MacTools.app
./build.sh install    # además la copia a /Applications y la abre
```

`build.sh` firma con una identidad autofirmada del llavero `pila.keychain-db`. Eso
mantiene el *designated requirement* atado al certificado y no al cdhash, que es lo
único que evita que macOS resetee los permisos de Accesibilidad y Calendario en cada
build. Si el llavero no está, cae a ad-hoc y avisa.

## Publicar una versión

```sh
./release.sh          # compila y arma dist/MacTools-<version>.dmg
```

Sin cuenta de Apple firma **ad-hoc** —el certificado local no existe en otra Mac— y
mete en el DMG un LEEME con el paso a paso. Con cuenta:

```sh
export MACTOOLS_IDENTITY="Developer ID Application: … (TEAMID)"
export MACTOOLS_NOTARY_PROFILE="mactools"   # xcrun notarytool store-credentials
./release.sh
```

Después, en el tap: subir el DMG con `gh release create` y actualizar `version` y
`sha256` en `Casks/mactools.rb`.

El cask saca la cuarentena con un `postflight` porque la app no está notarizada. El
día que se notarice, ese bloque se borra.

## Cómo está armado

| | |
|---|---|
| `Store.swift` | SQLite con FTS5 para el historial. `secure_delete`, WAL, migraciones por `user_version` |
| `NotchController.swift` | Un `NSPanel` por pantalla. El panel nunca cambia de tamaño: crece el contenido |
| `NotchView.swift` | Las cinco pestañas de la notch |
| `TaskParser.swift` | Una línea entra, estructura sale: `#proyecto/sección @app !tipo p1 en 25m` |
| `LLM*.swift` | El motor de llmpet: Conductor, Claude Desktop, terminal y navegador |
| `Connectors.swift` | Detecta e instala las piezas que cada fuente necesita |
| `FluidVoice.swift` | Controla FluidVoice desde acá sin forkearlo |
| `Resources/en.lproj` | Las claves son el texto en español, que es el idioma en el que está escrita |

Los datos viven en `~/Library/Application Support/Pila` — el nombre viejo de la app;
renombrar la carpeta perdería el historial de quien ya la usa.
