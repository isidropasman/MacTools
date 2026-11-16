# Notch: comportamiento e implementación

Estado documentado: 12 de noviembre de 2026. Describe los cambios del workspace; todavía no se creó un commit ni se publicó una versión con ellos.

## Alcance y estado

| Mejora | Implementación | Validación disponible |
| --- | --- | --- |
| Batería compacta y sus estados | Implementada | Geometría, render del componente, transiciones simuladas y lectura de la batería real |
| Avisos de otras apps | Implementados mediante Accesibilidad | Compilación; pendiente verificar una notificación real y su acción |
| Estante de archivos | Retiro visual inmediato, arrastre nativo y borrado en segundo plano | Compilación; pendiente completar un arrastre real hacia otra app |
| Rendimiento y animaciones | AppleScript y borrados fuera del hilo principal; menos actualizaciones redundantes | Compilación; sin medición de CPU, memoria o fluidez antes/después |
| Música persistente | Spotify y Music | Compilación; pendiente una sesión completa de reproducción real |
| Organización de ventanas | Cuadrícula, Columnas y Filas, por pantalla | Compilación; pendiente comprobarla en vivo con varias apps y pantallas |
| YouTube en el panel de medios | Miniatura, título, canal y controles de la pestaña existente | Fixtures de extensión, selección nativa y WebSocket real; pendiente prueba en Chrome real |

## Batería: diseño aprobado

El icono aparece a la izquierda de la cámara. El estado y el porcentaje aparecen a la derecha, en una línea. El aviso conserva la altura real del notch y los laterales se extienden horizontalmente. No lleva pastilla alrededor del icono, brillo de la portada musical ni sombra debajo del aviso compacto.

| Elemento | Medida |
| --- | --- |
| Notch medido en la pantalla integrada usada durante el trabajo | 185 × 32 pt |
| Escala de esa pantalla | 2; el notch equivale a 370 × 64 píxeles del framebuffer |
| Icono completo, incluido el terminal | 24 × 12 pt |
| Contorno del cuerpo de la batería | 1 pt |
| Lateral izquierdo reservado | 48 pt: 12 de margen, 24 de icono y 12 hacia la cámara |
| Separación entre cámara y texto | 12 pt |
| Separación entre estado y porcentaje | 6 pt |
| Margen después del porcentaje | 16 pt |
| Texto del estado | 11 pt, semibold |
| Porcentaje | 10 pt, medium, dígitos monoespaciados |
| Radio superior/inferior del aviso compacto | 6 / 8 pt |

Las medidas están expresadas en puntos de AppKit. Los 185 × 32 pt son una medición de esta Mac, no una constante para todas las pantallas. El ancho derecho se calcula con la tipografía real y el contenido. En las vistas previas en español, los avisos midieron 343 pt de ancho para «Cargando 67%», 355 para «Batería baja 20%» y 383 para «Carga completa 100%».

### Geometría y causa del defecto anterior

`NotchGeometry.rect(on:)` obtiene los bordes del recorte a partir de `auxiliaryTopLeftArea`, `auxiliaryTopRightArea` y `safeAreaInsets.top`. La pantalla medida reportó el recorte entre x=665 y x=850, con y=950 y altura de 32 pt.

Antes se centraba el bloque completo aunque el lateral del texto era más ancho que el del icono. El espacio transparente reservado para la cámara quedaba desplazado y parte del texto terminaba detrás del recorte físico. Reducir padding no corregía ese desplazamiento.

`NotchPeekLayout` conserva fijo el espacio de la cámara:

```text
inicio del aviso = inicio de la cámara − ancho izquierdo
ancho del aviso = ancho izquierdo + ancho de cámara + ancho derecho
desplazamiento respecto del centro = (ancho derecho − ancho izquierdo) / 2
```

Cada lateral se limita al espacio disponible dentro del contenedor. El dibujo y la región interactiva usan el mismo cálculo. `NSHostingView.safeAreaRegions = []` y `ignoresSafeArea()` permiten que la app gestione explícitamente la franja de la cámara.

En pantallas sin notch se utiliza un anclaje sintético de 185 × 32 pt en el borde superior. El panel desplegado conserva su contenedor de 520 × 190 pt y su contenido de 178 pt de alto.

## Batería: estados y disparadores

| Situación | Aviso | Icono | Regla |
| --- | --- | --- | --- |
| Se conecta alimentación y la batería está cargando | Cargando + porcentaje | Relleno verde, contorno fino neutro | Se detecta el cambio a alimentación externa |
| Se conecta alimentación con la carga pausada | Conectado + porcentaje | Relleno verde, contorno fino neutro | El cargador se reconoce aunque `isCharging` sea falso |
| La batería llega al 20% o menos sin alimentación externa | Batería baja + porcentaje | Relleno naranja, contorno fino neutro | Una advertencia hasta volver a conectar alimentación |
| Llega al 100% con alimentación externa | Carga completa + porcentaje | Relleno verde, contorno fino neutro | Una advertencia durante esa conexión |
| Se desconecta con más del 20% | Sin cargador + porcentaje | Relleno blanco | Conserva el aviso de desconexión |
| Se desconecta con el 20% o menos | Batería baja + porcentaje | Relleno naranja | Tiene prioridad sobre «Sin cargador» |

- Los avisos de batería duran 5 segundos.
- Al iniciar la app con batería baja se advierte una vez. Iniciar con el cargador conectado o con el 100% no genera un aviso por sí solo.
- Las oscilaciones del porcentaje cerca del 20% no repiten la advertencia. Volver a conectar alimentación la habilita de nuevo.
- Las oscilaciones entre 99% y 100% durante la misma conexión tampoco repiten «Carga completa».
- Si se conecta el cargador al 100%, se muestra «Carga completa».
- Los textos se localizan; el ancho se mide después de elegir el texto localizado.
- Si la notch está desplegada, se conserva el último aviso de batería pendiente y aparece al cerrarla. No hay una cola de todos los eventos intermedios.
- Al terminar un aviso temporal vuelve a mostrarse la música si sigue reproduciéndose.

### Lectura del sistema

`BatteryMonitor` lee exclusivamente fuentes del tipo `InternalBattery`. Distingue alimentación externa mediante `kIOPSPowerSourceStateKey == kIOPSACPowerValue`.

`IOPSNotificationCreateRunLoopSource` entrega los cambios del sistema en el run loop principal. El sondeo de 20 segundos queda como respaldo si no se puede crear esa fuente de eventos. `start()` evita registrar observadores duplicados y `stop()` invalida la fuente y cancela el temporizador.

`isCharging` y `isCharged` no son equivalentes a «cargador conectado» y «100%». El SDK de Apple documenta que una batería enchufada, sin cargar y con al menos el 95% puede reportarse como cargada. Por eso el aviso de carga completa exige alimentación externa y un porcentaje de al menos 100.

`BatteryMonitor.EventTracker` conserva el estado anterior y las advertencias ya emitidas durante el ciclo. El porcentaje de la barra y el tooltip de batería del panel desplegado usan las mismas distinciones de carga, conexión y batería baja.

## Avisos de otras apps

La opción está en **Ajustes → Notch → Mostrar avisos de otras apps** y está activada por defecto. Requiere el permiso de Accesibilidad de macOS.

`NotificationMonitor` consulta el árbol accesible de Notification Center aproximadamente cada 450 ms. Busca avisos con identificador UUID y los campos `title` y `body`. La primera lectura establece la referencia para no volver a presentar avisos ya existentes; después detecta identificadores nuevos.

La tarjeta muestra el icono, el título y el mensaje, y dura 5 segundos. Al tocarla intenta ejecutar `AXPress` sobre el aviso original. Si no puede, intenta abrir la app emisora.

Límites actuales:

- Es un espejo de avisos visibles. No suprime el banner de macOS ni lee un historial privado de notificaciones.
- La estructura accesible de Notification Center puede cambiar entre versiones de macOS.
- La acción nativa depende de que el aviso siga accesible; abrir la app no garantiza abrir la conversación o elemento exacto.
- El respaldo que busca una app por nombre todavía usa `fullPath(forApplication:)`, obsoleto en macOS.
- La validación con una notificación real y su acción sigue pendiente.

## Estante de archivos

Al ingresar un archivo se copia al directorio del estante. Sacarlo del estante elimina esa copia; el archivo original permanece en su ubicación.

`ShelfDragSource` usa un arrastre nativo de AppKit. Solo retira el item cuando la app de destino confirma una operación de copia. Cancelar el arrastre no lo retira. El doble clic abre el archivo y el menú contextual ofrece abrirlo, mostrarlo en Finder o quitarlo.

`ShelfStore.remove(_:)` retira el item de la colección visible inmediatamente y borra la copia en una tarea de utilidad. Si el borrado falla, recarga el directorio. La transición del chip combina escala y opacidad con un spring de respuesta 0,32 y amortiguación 0,78.

## Música y rendimiento

El panel admite **Spotify y Music**, mediante sus diccionarios AppleScript, y **YouTube**, mediante la extensión de Chrome. Ofrece portada o miniatura, título, artista o canal, progreso, reproducir/pausar, siguiente, anterior y apertura del reproductor o de la pestaña existente.

Los scripts de consulta y control se ejecutan en una cola serial fuera del hilo principal. El muestreo es cada 2 segundos y evita consultas simultáneas. La barra interpola la posición entre muestras. Entre los reproductores nativos se prioriza uno que esté reproduciendo frente a otro pausado; si ambos reproducen, Spotify se consulta primero. Entre el reproductor nativo y YouTube se prioriza la fuente cuya reproducción se detectó más recientemente; los reportes periódicos no cambian esa prioridad. Al desconectarse el navegador se recupera la fuente nativa disponible.

Mientras una pista está reproduciéndose, la notch compacta conserva su aviso. Los avisos temporales tienen prioridad y, al terminar, se restaura la pista. Al pausar deja de mostrarse el aviso persistente. La portada se consulta al dibujar para evitar capturar una imagen anterior mientras descarga la nueva.

El contenedor del panel mantiene su tamaño para que la animación no redimensione una ventana de AppKit en cada cuadro. Los borrados del estante y las lecturas accesibles de avisos también se realizan fuera del hilo principal. Estas son mejoras de implementación; no se hicieron benchmarks de rendimiento.

## Organización automática de ventanas

Se configura en **Ajustes → Notch → Ordenar ventanas automáticamente**. Está desactivada por defecto y requiere Accesibilidad. La distribución inicial es Cuadrícula; también hay Columnas y Filas.

`WindowArranger` organiza ventanas estándar visibles, agrupadas por pantalla y dentro de su área visible. No organiza pestañas internas del navegador ni ventanas minimizadas. Excluye las ventanas de la propia app.

Consulta cambios de apps y pantallas, además de un sondeo cada 2 segundos. Reorganiza cuando cambia el conjunto de ventanas; cambiar la distribución o las pantallas fuerza una nueva pasada. La exploración se ejecuta fuera del hilo principal.

La referencia de producto fue [Shoji](https://shojimac.com/). El alcance implementado es el de los tres layouts mencionados, no una reproducción de todas sus funciones.

## Archivos principales

| Archivo | Responsabilidad |
| --- | --- |
| [BatteryMonitor.swift](../Sources/MacTools/BatteryMonitor.swift) | Lectura IOKit, fuente de eventos y reglas de transición |
| [BatteryPeekIcon.swift](../Sources/MacTools/BatteryPeekIcon.swift) | Icono de 24 × 12 pt y contorno de 1 pt |
| [NotchGeometry.swift](../Sources/MacTools/NotchGeometry.swift) | Recorte físico, anclaje sintético y geometría de laterales |
| [NotchState.swift](../Sources/MacTools/NotchState.swift) | Contenido, textos y medición de los avisos |
| [NotchController.swift](../Sources/MacTools/NotchController.swift) | Duraciones, prioridades y avisos pendientes |
| [NotchView.swift](../Sources/MacTools/NotchView.swift) | Panel, aviso compacto, música y estante |
| [NotificationMonitor.swift](../Sources/MacTools/NotificationMonitor.swift) | Lectura de Notification Center y acción del aviso |
| [MediaController.swift](../Sources/MacTools/MediaController.swift) | Selección de Spotify, Music o YouTube y despacho de controles |
| [BrowserMediaStore.swift](../Sources/MacTools/BrowserMediaStore.swift) | Metadatos validados, selección de pestaña, caducidad y destino exacto de comandos |
| [BrowserMediaServer.swift](../Sources/MacTools/BrowserMediaServer.swift) | WebSocket local para la extensión de Chrome |
| [ShelfDragSource.swift](../Sources/MacTools/ShelfDragSource.swift) | Arrastre nativo y menú de archivos |
| [ShelfStore.swift](../Sources/MacTools/ShelfStore.swift) | Copias del estante y borrado en segundo plano |
| [WindowArranger.swift](../Sources/MacTools/WindowArranger.swift) | Distribución de ventanas con Accesibilidad |
| [Settings.swift](../Sources/MacTools/Settings.swift) | Preferencias persistidas |
| [SettingsView.swift](../Sources/MacTools/SettingsView.swift) | Configuración y permisos |
| [main.swift](../Sources/MacTools/main.swift) | Inicio de monitores y controladores |

## Verificación y reproducción

La última implementación de estados pasó compilación debug y release y `git diff --check`. El bundle local se reconstruyó y se reinició. Esto no equivale a publicar ni a instalar otra copia en `/Applications`.

Las comprobaciones específicas realizadas fueron:

- 240 aserciones geométricas: 4 anchos de notch × 4 alturas × 3 estados × 5 invariantes. Se ejecutaron antes del último ajuste de 4 pt del margen derecho.
- Render del `NotchView` de producción con una máscara que representa la cámara física. Las últimas vistas incluyen el margen derecho de 16 pt y los colores de los tres estados.
- 26 escenarios de transición con `BatteryMonitor.EventTracker`: conexión, desconexión, umbral exacto del 20%, oscilaciones, arranque con batería baja, carga pausada y llegada al 100%.
- Lectura nativa de IOKit y registro/cancelación/reinicio del observador. En esa ejecución la Mac reportó 39%, sin alimentación externa.

Los scripts, renders y logs de esta sesión están en `.context/`, ignorado por Git. En esta máquina:

| Artefacto local | Contenido |
| --- | --- |
| `.context/BatteryPreview/main.swift` | Render del componente real y modo `--live` |
| `.context/BatteryStates/main.swift` | Los 26 escenarios de transición |
| `.context/BatteryStates/Probe/main.swift` | Lectura de la batería real y ciclo del observador |
| `.context/battery-states-preview.png` | Carga, batería baja y carga completa con datos simulados |
| `.context/battery-states-release.log` | Compilación release y armado del bundle |

Para compilar el estado actual:

```sh
swift build -c debug
bash build.sh
git diff --check
```

Para repetir los escenarios en el workspace que conserva los artefactos:

```sh
swiftc Sources/MacTools/BatteryMonitor.swift .context/BatteryStates/main.swift -o .context/BatteryStates/check
.context/BatteryStates/check
```

La prueba física de enchufar y desenchufar el cargador sigue pendiente. Las vistas previas usan porcentajes simulados; no demuestran una transición física. Tampoco se verificó una captura del escritorio: falló la herramienta de captura en esa sesión.

## YouTube en la pestaña existente

La extensión [llmpet/extension](../llmpet/extension) conecta el video ya abierto en una página `/watch` de YouTube con el panel multimedia existente. Muestra miniatura sin deformarla, título, canal, tiempo y controles. No incorpora un reproductor embebido ni modifica las dimensiones del panel. Hacer clic en la miniatura activa la pestaña y su ventana.

### Instalar o actualizar

1. Compilar el bundle local con `bash build.sh` y abrir esa copia de Notchbox.
2. En **Ajustes → Conectores → Chrome: IA y YouTube**, usar el botón de instalación para copiar la extensión del bundle a `~/.llmpet/chrome-extension` y abrir su carpeta.
3. En `chrome://extensions`, cargar esa carpeta con **Cargar descomprimida**, o recargar LLMPet si ya estaba cargada. Chrome puede pedir aceptar el acceso nuevo a YouTube. Requiere Chrome 116 o posterior.
4. Mantener abierto un video de YouTube. La extensión intenta inyectar el script también en pestañas que ya estaban abiertas; si Chrome no concedió acceso al sitio, revisar ese permiso y recargar la pestaña.

Los permisos nuevos se limitan a `www.youtube.com`, `youtube.com` y `m.youtube.com`. Se declaran los sitios completos para detectar navegación interna desde la página principal hacia un video; solo las páginas `/watch` con un identificador válido publican medios. Los permisos de host habilitan la reinyección mediante `scripting.executeScript` al actualizar la extensión. Las sesiones LLM mantienen su flujo anterior.

### Comunicación y comportamiento

- `youtube-content.js` observa el elemento HTML de video y los eventos de navegación; ejecuta los controles en esa misma pestaña. No usa una clave de la API de YouTube ni interfaces privadas de medios de macOS.
- `youtube-background.js` usa un WebSocket separado en `127.0.0.1:7718`, con subprotocolo `notchbox-media-v1`. El servidor escucha únicamente en loopback, exige un Origin con formato de extensión Chrome y limita cada mensaje a 64 KiB. Esto no es una autenticación criptográfica de una extensión concreta.
- Los comandos identifican conexión, pestaña y video. Si el video cambió, se cerró la pestaña o caducó el estado, el comando no se ejecuta sobre otro contenido.
- Se solicita un estado actual cada 5 segundos. Al reconectar se vuelve a consultar las pestañas; no se conserva una cola de comandos. Los estados sin actualización caducan a los 15 segundos.
- Entre varias pestañas que reproducen gana la que empezó más recientemente según los eventos recibidos. Una pestaña pausada o un reporte periódico no desplazan a otra que reproduce.
- El progreso respeta la velocidad de reproducción y se detiene durante buffering. Los directos muestran **EN VIVO** y deshabilitan seek. Durante anuncios no se permite seek, siguiente ni anterior; reproducir/pausar sigue disponible.
- Siguiente y anterior dependen de que YouTube exponga un botón visible y habilitado. No se simula un historial de navegación.
- Las miniaturas se descargan desde `i.ytimg.com` usando el identificador del video. Si falla la descarga, el cargador compartido puede conservar la imagen anterior: es una limitación preexistente.

### Verificación de esta integración

- Compilación debug y release; bundle local con los scripts nuevos incluidos.
- 30 comprobaciones del content script: metadatos, pausa/reproducción, seek, navegación, comandos viejos, anuncios, directos, buffering y velocidad 2×.
- 21 comprobaciones del background: rutas de comandos, foco de pestaña, filtrado de frames, reinyección con permisos, estado fresco tras reconexión y coexistencia con sesiones LLM.
- 22 comprobaciones nativas: validación, múltiples pestañas, caducidad, selección, comandos y validación del Origin.
- Ida y vuelta con un WebSocket real: estado → selección nativa → comando → cierre y retiro del estado. Rechazo real con HTTP 400 de Origin o subprotocolo inválidos, comprobado por socket directo.
- 13 comprobaciones de `MediaController`: arbitraje entre navegador y fuente nativa, interpolación 2×, buffering, comandos, directo y recuperación al desconectar. El fixture compila una copia del archivo de producción con una extensión de comprobación en el mismo archivo, sin cambiar la lógica.
- Comprobación de los permisos de reinyección de los tres hosts YouTube; detectó y permitió corregir su ausencia inicial.

Las compilaciones conservan warnings ajenos a esta integración en `SettingsView`, `QuickAddController` y `NotificationMonitor`. La revisión independiente encontró el permiso faltante de reinyección, ya corregido; dejó como defecto menor preexistente la portada anterior cuando falla su descarga.

Los fixtures están en `.context/YouTubeChecks/`. No se verificó Chrome real: la herramienta de navegador devolvió **The browser access host is unavailable**. Quedan pendientes los selectores y eventos del sitio real, permisos efectivos, suspensión del worker y apariencia final con una pestaña real. Las pruebas simuladas y el WebSocket real no demuestran esos puntos.

## Fuentes técnicas

- [Apple: NSScreen.safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets).
- [Apple: NSScreen.auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc).
- [Apple: IOPSNotificationCreateRunLoopSource](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou).
- [Apple: kIOPSPowerSourceStateKey](https://developer.apple.com/documentation/iokit/kiopspowersourcestatekey).
- [Apple: IOPSKeys.h](https://developer.apple.com/documentation/iokit/iopskeys_h); la definición de `kIOPSIsChargedKey` del SDK explica el estado cargado por debajo del 100%.
- [Chrome: content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts).
- [Chrome: scripting y permisos de host](https://developer.chrome.com/docs/extensions/reference/api/scripting#manifest).
- [Chrome: WebSockets en service workers](https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets).
- [YouTube: IFrame Player API](https://developers.google.com/youtube/iframe_api_reference).
