# Validación local

## Lectura progresiva de Spotify — 0.2.2

- El inventario se lee en este orden: canciones guardadas, álbumes guardados y sus canciones, listado completo de playlists y contenido de cada playlist. La paginación publica avances por página; las playlists pendientes no se presentan como vacías.
- Se eliminaron las consultas individuales automáticas para completar ISRC durante la lectura. Los códigos recibidos se reutilizan sólo entre observaciones compatibles dentro de la misma lectura. Se conservan conflictos, restricciones, procedencia, orden y repeticiones. Las búsquedas y consultas puntuales de catálogo siguen disponibles para resolver coincidencias.
- El checklist XML y el flujo automático reciben el mismo contrato de progreso. Los eventos de una carga cancelada o anterior se descartan. Una cancelación o un error de cuota conserva el checklist guardado, sus marcas y el XML.
- La espera de reintento es visible. Un 429 terminal detiene toda la lectura y bloquea nuevas solicitudes de ese proveedor hasta el plazo indicado. Las colecciones inaccesibles y los cambios de total conservan la cobertura parcial.
- `bash scripts/test.sh`: **300 pruebas aprobadas**, sin fallos: 180 de SyncCore, 95 de MusicProviders y 25 de SpotAMSync. Se ejecutó fuera del sandbox para permitir el callback local de las pruebas OAuth; no se usaron cuentas ni credenciales reales.
- Diez regresiones nuevas cubren orden y progreso por página, 1.000 canciones sin ISRC, cuota global y reintento inmediato bloqueado, cancelación antes de la página siguiente y reutilización del proveedor, cambios de total, conflictos de metadatos y posiciones duplicadas, progreso tardío entre cargas manuales, conservación del checklist ante cuota, progreso/cancelación del flujo automático y notificación de espera antes de un reintento HTTP.
- Caso sintético de 1.000 canciones sin ISRC: **22 consultas de inventario** (20 páginas de canciones, álbumes y playlists), más la consulta de perfil al conectar; **cero consultas individuales de canciones**. Esta medición es un conteo de solicitudes, no un tiempo de respuesta de Spotify.
- El componente SwiftUI real se compiló en una app temporal con datos ficticios. Se verificaron por accesibilidad y captura nativa las etapas, contadores, estados pendiente/leyendo/completa/parcial, nombres largos y espera de reintento. El harness temporal no accede a cuentas ni almacenamiento habitual.
- Build de producción **0.2.2 (4)** instalado en `/Applications/SpotAM Sync.app`, con copia del paquete anterior. Firma verificada y ejecutable idéntico al build (`d0592fa3456c61104c60d7c8416e8d40b6f55bdd349223b3afe83de680b629a0`). Apertura nativa comprobada; los seis archivos de datos habituales conservaron sus hashes SHA-256 tras la actualización y apertura. La nueva carga con la cuenta real queda pendiente de reconexión del usuario.

## Callback local de Spotify — 0.2.1

Se reprodujo en macOS el error de inicio del callback: configurar `127.0.0.1:43821` en `requiredLocalEndpoint` y pasar además `on: 43821` a `NWListener` arroja `POSIX EINVAL` durante el inicializador, antes de abrir el navegador. Usar únicamente el endpoint local permite crear el listener y alcanzar el estado `ready` en el mismo puerto.

- La app conserva el redirect URI `http://127.0.0.1:43821/callback` y la escucha restringida a loopback.
- Tres regresiones ejercitan el listener real con un navegador sustituido por una función de prueba: callback HTTP completo y segundo intento; cancelación y nuevo intento; fallo al abrir el navegador y nuevo intento. La respuesta HTTP no expone el código ni el estado OAuth.
- `bash scripts/test.sh`: **290 pruebas aprobadas**, sin fallos: 180 de SyncCore, 88 de MusicProviders y 22 de SpotAMSync. Las pruebas de red requieren poder abrir el puerto local `43821`.
- Los valores OAuth son ficticios. Estas pruebas no abren el navegador, no contactan Spotify, no acceden al Llavero y no acreditan la autorización de una cuenta real.
- Build de producción 0.2.1 correcto; copia instalada verificada mediante firma y SHA-256. Se reabrió la app habitual y se comprobó que conservó el Client ID guardado y mostró **Conectar Spotify** habilitado. La autorización real queda a cargo del usuario.

## Integración con main — 24 de octubre de 2026

Se integraron las correcciones locales con `44f38ac`, que contiene la interfaz SwiftUI, el comparador por etapas, la sincronización por playlist y las propuestas programadas con confirmación. Se conservan ambas líneas de trabajo mediante un merge normal.

- `bash scripts/test.sh`: **287 pruebas aprobadas**, sin fallos: 180 de SyncCore, 85 de MusicProviders y 22 de SpotAMSync.
- Se mantienen las regresiones de ambas ramas. Los adaptadores de prueba declaran los límites HTTP cuando corresponde y generan una identidad nueva por instantánea, igual que los inventarios reales.
- Cuatro regresiones adicionales cubren: presupuesto compartido entre todas las etapas y expansiones de catálogo; conservación de candidatos ante HTTP 401 sin iniciar otras etapas; decisiones manuales del formato anterior con cobertura incompleta; reanudación de una adición con el campo histórico `createdByOperationID` sin duplicar la creación.
- La cobertura antigua `partial` sigue siendo legible. Las búsquedas nuevas distinguen límites y fallos parciales. Las dependencias de creación de ambos formatos y las instantáneas antiguas en línea siguen siendo legibles.
- `bash scripts/build-app.sh`: paquete de producción 0.2.0 generado e instalado en `/Applications/SpotAM Sync.app`. La firma ad hoc pasó `codesign --verify --deep --strict`; el SHA-256 del ejecutable instalado coincide con el del paquete compilado.
- Apertura de la copia instalada verificada con `SPOTAM_DATA_DIR` temporal y `--demo`: inicio SwiftUI visible, navegación a **Agregar a Apple Music** y carga del checklist de ejemplo. Se cerró la sesión después; los archivos habituales conservaron nombres, tamaños y fechas de modificación.
- `git diff --check`: correcto. No se conectaron cuentas reales durante esta verificación.

Las pruebas usan cuentas, transportes y almacenamiento temporales. No acreditan acceso real a MusicKit ni escrituras en bibliotecas personales.

## Correcciones de sincronización — 24 de octubre de 2026

Validación ejecutada en el checkout local después de corregir recuperación, descubrimiento de catálogo y vínculos de playlists.

- `bash scripts/test.sh`: **218 pruebas aprobadas**, sin fallos: 133 de SyncCore, 75 de MusicProviders y 10 de SpotAMSync. Son 24 regresiones nuevas respecto de las 194 pruebas presentes al iniciar esta corrección.
- `bash scripts/build-app.sh`: compilación de producción y empaquetado correctos. App generada: `build/SpotAM Sync.app`, firma local ad hoc.
- El script verificó la firma con `codesign --verify --deep --strict` antes de entregar el paquete.
- `git diff --check`: correcto.

Las nuevas pruebas verifican:

- Rechazos HTTP 400, 401, 403 y 429 sin efecto previo: quedan rechazados y permiten un nuevo plan. Un timeout sigue incierto y bloquea otra ejecución.
- El plan real de 41 canciones de Spotify se ejecuta como peticiones de 40 y 1. Si la segunda es rechazada, se conservan 40 resultados verificados; después de reabrir el almacenamiento y reconciliar, el nuevo plan envía sólo la canción faltante.
- La creación de una playlist guarda su ID antes de agregar canciones. Cancelar, recrear el ejecutor y reconciliar no duplica la playlist; el nuevo plan agrega 205 canciones en lotes de 100, 100 y 5, conservando el orden.
- Un rechazo de un reintento no borra la incertidumbre de un envío anterior. Los registros antiguos con escrituras compuestas no se reanudan con los adaptadores nuevos.
- Las instantáneas compartidas del journal se serializan una vez; la decodificación recupera la evidencia de cada elemento y sigue aceptando el formato anterior. Una referencia de evidencia ausente se rechaza.
- Las referencias adicionales de ISRC de Apple se completan antes de decidir. Referencias no resueltas y fallos de paginación conservan candidatos y cobertura incompleta.
- Spotify y Apple prueban metadatos después de un ISRC vacío. Los límites de páginas, expansión de álbumes y solicitudes —incluidos reintentos— no se presentan como búsquedas completas.
- Una autorización vencida durante una búsqueda conserva la evidencia ya recibida, sin reconectar silenciosamente. Los alias de biblioteca y catálogo compatibles se consolidan; los contradictorios quedan para revisión.
- Desvincular una playlist obsoleta persiste la decisión, revoca aprobaciones y recalcula el plan; la acción se bloquea durante una sincronización.
- El inventario para el checklist manual recorre más de dos páginas aunque la búsqueda de catálogo esté acotada. También pasaron todas las pruebas existentes de XML, marcas, cuentas, persistencia y cancelación.

Los transportes HTTP, proveedores y datos de estas pruebas son sintéticos. El almacenamiento de las regresiones está en directorios temporales. No se leyeron ni modificaron bibliotecas reales, no se inició MusicKit y no se validó visualmente la app nativa en esta ejecución. La firma ad hoc no acredita acceso real a MusicKit ni distribución notarizada.

## Registro previo — 23 de octubre de 2026

Los resultados siguientes corresponden a la validación anterior; la comprobación visual descrita allí no se repitió para estas correcciones.

Entorno: Mac Apple Silicon, macOS 27.0.1, Xcode 27.1, Swift 6.4 en modo de lenguaje Swift 5. Deployment target: macOS 14. El paquete generado es arm64.

### Pruebas y compilación

- `bash scripts/test.sh`: **221 pruebas aprobadas**, sin fallos —143 de SyncCore, 66 de MusicProviders y 12 del modelo de la app—.
- `bash scripts/build-app.sh`: compilación de producción y empaquetado correctos.
- `codesign --verify --deep --strict 'build/SpotAM Sync.app'`: correcto.
- Firma local **ad hoc**, sin TeamIdentifier. No es una distribución notarizada ni habilita la integración de producción con MusicKit.
- Icono ICNS y ejecutable Mach-O arm64 presentes y reconocidos.

Las pruebas usan transportes y proveedores controlados. Cubren paginación, permisos, identidad, coincidencias ambiguas, orden y duplicados, álbumes parciales, inventarios incompletos, revocación de aprobaciones, cancelación antes del envío, errores después de escrituras, recuperación entre ejecuciones y continuidad de la autorización Apple.

La ampliación de búsqueda y recuperación agrega cobertura para:

- ISRC vacío y ampliación por artista/álbum/título; un mismo ISRC en otro álbum exige elección manual.
- Referencias adicionales en `meta.filters.isrc` de Apple y referencias que no se pueden completar.
- Filtros combinados y paginación acotada de Spotify, caché de resultados completos y espera tras HTTP 429 en ambos proveedores.
- Cobertura limitada sin candidatos, fallos de consulta y metadatos desconocidos sin convertirlos en coincidencia automática ni ausencia confirmada.
- Elecciones, pendientes, omitidas y descartes; revalidación de identidad y compatibilidad con estados anteriores.
- Referencias públicas con namespace `itunes:`, país obligatorio y ausencia de credenciales en esas solicitudes.
- Persistencia del checklist, separación de cuentas, cancelación que descarta respuestas tardías y demo sin red ni sobrescritura del estado real.
- Lotes grandes con éxito parcial seguido de 403, creación de playlist con ID durable, append incierto y reemplazos que conservan orden y repeticiones.

## Comprobación de la app nativa

Verificado mediante interacción con la app compilada:

- Apertura normal, navegación y contenido en español.
- Demo identificada en todas sus pantallas, sin cuentas reales.
- Resumen y detalle de canciones fuera de playlists, con explicación de álbumes parciales.
- Vista previa con operaciones disponibles y bloqueadas, y selección independiente.
- Cambio de plataforma base que limpia la selección anterior.
- Confirmación de una simulación y confirmación adicional obligatoria para reemplazos.
- Ejecución de cuatro operaciones aditivas en la demo y verificación de las cuatro mediante lectura del proveedor en memoria.
- Resultado parcial que conserva las diferencias incompatibles o pendientes; no declara un espejo completo.
- Nuevo análisis sin volver a proponer las altas ya verificadas.
- Reemplazo de playlist simulado y verificado en Spotify.
- Historial persistido y exportación JSON de un registro de demostración, con dos inventarios de respaldo y dos inventarios finales.

La simulación fue demasiado breve para capturar un estado intermedio estable del indicador de progreso con la herramienta de accesibilidad; se comprobaron sus conteos y resultado final. Los estados de avance y cancelación del motor están cubiertos por pruebas automatizadas.

### Comparadores de canciones

En esta ampliación se abrió el build de producción con `SPOTAM_DATA_DIR` temporal y se cargó la demostración desde la interfaz. Se verificó visualmente:

- Comparador oficial: apertura, búsqueda sin cerrar la ventana, descarte, restauración, elección y actualización de la etiqueta de elección manual.
- Comparador XML: edición de términos, búsqueda sólo por artista, opciones de distintos álbumes, comparación de metadatos, elección y referencia guardada en la fila.
- La elección XML no cambia el conteo de marcas ni la evidencia de presencia. Los dos flujos advierten que otra edición requiere elección y que elegir no escribe en el servicio.

La prueba visual detectó y permitió corregir una navegación que cerraba el comparador al iniciar una búsqueda. La suite completa y el build de producción se ejecutaron nuevamente después de la corrección. Las consultas autenticadas a los catálogos y las escrituras reales siguen pendientes de aceptación con cuentas de prueba; los contratos HTTP se validaron con transportes controlados.

## Pendiente con servicios reales

- Spotify: introducir el Client ID público de la app registrada, verificar el redirect URI, autorizar una cuenta habilitada y probar primero contenido destinado a pruebas.
- Apple Music: disponer de la firma y el App ID del Apple Developer Program con MusicKit habilitado; autorizar y verificar el acceso efectivo a la biblioteca.
- La revisión automática de acciones rechazó la prueba del botón «Conectar Apple Music» por el posible inicio de una solicitud de permisos. Se comprobó el requisito de firma mediante lectura del paquete y del código; no se autorizó una cuenta ni se leyó una biblioteca real.
- Distribución al grupo: firma Developer ID, notarización y prueba en otro Mac.
- Automatización local de Música sin MusicKit: no implementada; requiere demostrar identidad, operaciones permitidas y propagación a la biblioteca cloud antes de habilitar escrituras.

Las bajas y los reemplazos que Apple Music no documenta en su API pública permanecen bloqueados. No se realizaron commits, pushes ni modificaciones de bibliotecas reales.
