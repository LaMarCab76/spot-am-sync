# Música local sin membresía Developer: investigación

Fecha: 23 de octubre de 2026. Entorno comprobado: macOS 27.0.1, Música 1.7, Apple Silicon.

## Decisión

Hay una vía concreta para **comparar una exportación local de Música sin MusicKit ni membresía Apple Developer**. También existe una interfaz de automatización candidata para gestionar playlists con pistas que Música ya conoce. No se encontró un contrato local oficial equivalente a agregar cualquier canción o álbum nuevo del catálogo por su ID.

La recomendación es un modo local explícito: análisis mediante XML como primera etapa, transferencia aditiva hacia Spotify y gestión de playlists Apple sobre pistas existentes sólo después de un ensayo controlado. Los faltantes del catálogo se presentarían como pendientes con incorporación asistida. Un espejo automático general queda fuera del alcance demostrado.

Esta investigación no habilita escrituras en la app actual. No se agregó, eliminó, reordenó ni reprodujo contenido durante las pruebas.

## Evidencia obtenida en este Mac

### iTunesLibrary: inicialización correcta, inventario no fiable en el ensayo

Se compiló un programa Swift mínimo con el framework público `iTunesLibrary`, firmado ad hoc y sin TeamIdentifier. `ITLibrary(apiVersion: "1.1", options: .lazyLoadData)` inicializó correctamente. Una segunda prueba solicitó `reloadData`, `allMediaItems` y `allPlaylists`, imprimiendo únicamente recuentos.

Resultado: API 1.1, `reloadData == true`, **0 pistas y 0 playlists**, tanto antes como después de inspeccionar Música. Sin embargo, la interfaz de Música mostraba contenido y la exportación nativa confirmó un inventario no vacío.

Esto prueba que la inicialización con esa firma es posible; **no prueba que ad hoc permita leer correctamente el inventario**. No se aisló la causa de la discrepancia —autorización, contexto del ejecutable, aislamiento del proceso o biblioteca predeterminada—. No corresponde atribuirla a una biblioteca vacía ni usar esa lectura para sincronizar o borrar.

Apple documenta que este framework es de lectura, exige firma y contempla autorización de acceso. Carga la base local predeterminada y ofrece recarga; no sustituye una consulta completa al servidor. [iTunes Library](https://developer.apple.com/documentation/ituneslibrary), [ITLibrary](https://developer.apple.com/documentation/ituneslibrary/itlibrary).

### XML: inventario real obtenido y contrastado

Desde la interfaz de Música se utilizó **File → Library → Export Library**. El archivo se guardó en `/private/tmp/spotam-local-feasibility/Library.xml`, dentro de una carpeta privada con permisos 0700; el XML tiene permisos 0600. No se incorporó al repositorio ni se subió a ningún servicio.

Se validó como plist XML y se obtuvieron estos agregados:

| Comprobación | Resultado |
| --- | ---: |
| Pistas exportadas | 3.543 |
| Entradas de playlists, incluidas carpetas y listas del sistema | 75 |
| Carpetas | 12 |
| Listas inteligentes | 1 |
| Listas marcadas como sistema o principal | 2 |
| Ocurrencias de pistas, incluidas listas del sistema | 18.513 |
| Referencias de playlists sin pista correspondiente | 0 |
| Listas con IDs de pista repetidos | 7 |
| Pistas con identificador persistente | 3.543 |
| Entradas de playlist con identificador persistente | 75 |
| Pistas con tipo `Remote` | 3.543 |
| Pistas con bandera `Apple Music` | 3.540 |
| Pistas con bandera `Playlist Only` | 1.311 |

La playlist visible en Música mostraba 18 canciones; su entrada XML también contenía 18 referencias. No se verificó manualmente cada posición ni toda la biblioteca. Los datos remotos presentes descartan tratar el XML como inventario exclusivamente de archivos descargados; **no demuestran cobertura completa ni actualización de toda la nube**.

Se observaron identificadores persistentes de biblioteca/pistas/playlists, duración, artista, álbum, indicadores explícito/clean y relaciones ordenadas por referencias. No se observaron campos ISRC ni catalog ID en esta exportación. `Playlist Only` debe conservarse: no se puede convertir automáticamente toda pista exportada en una canción guardada individualmente.

Herramienta reproducible, que sólo emite agregados y no modifica el archivo:

```sh
python3 scripts/research/inspect-music-xml.py /ruta/Library.xml
```

El XML contiene metadatos, no audio. Apple documenta además que **importar una playlist sólo incorpora elementos ya presentes en la biblioteca**, omitiendo los que faltan. No permite prometer altas de canciones nuevas del catálogo. [Exportación e importación de Música](https://support.apple.com/es-es/guide/music/-mus27cd5060f/mac).

## Qué permitiría cada vía

| Necesidad | Vía local | Estado |
| --- | --- | --- |
| Leer pistas y playlists, incluidos elementos remotos | Exportación XML | Comprobado en este Mac, como instantánea local |
| Leer automáticamente desde la app | iTunesLibrary o Apple Events | Contratos disponibles; cobertura y permisos pendientes de validar |
| Reconstruir playlists en Spotify | XML + conector Spotify actual | Implementación propuesta; falta normalización y resolución de coincidencias |
| Crear playlists Apple con canciones existentes | Apple Events/ScriptingBridge | Candidata a ensayo; no se hicieron escrituras |
| Ordenar, preservar repeticiones y quitar una sola ocurrencia | Automatización de Música | Necesita pruebas por operación y tipo de contenido |
| Agregar cualquier canción/álbum nuevo de Apple Music | Ningún contrato local encontrado | Incorporación manual/asistida; automatización visual experimental |
| Probar que la nube quedó igualada | Lectura local por sí sola | Insuficiente; requiere verificación desde otro cliente o servicio |

El diccionario instalado declara `make`, `duplicate` y `delete`. Sin embargo, `add` recibe archivos, `search` busca dentro de una playlist, `download` opera sobre objetos existentes y `open location` abre enlaces. `move` mueve playlists; no documenta mover tracks. Esas diferencias impiden interpretar comandos genéricos como una API de catálogo o una garantía de eliminación por ocurrencia.

Evidencia local: `/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`, líneas 21–41, 77–97, 140–145, 339–350, 362–376, 405–409, 431, 486–499 y 604–605. ScriptingBridge utiliza la misma interfaz de automatización; no amplía sus capacidades. [Guía oficial, archivada](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptingBridgeConcepts/Introduction/Introduction.html).

Los enlaces a Apple Music sirven para abrir el contenido y facilitar la incorporación por la persona. El iTunes Search API público puede aportar candidatos y enlaces sin developer token, pero consulta iTunes Store, no acredita disponibilidad en la suscripción ni permite escribir en la biblioteca. No se verificó su funcionamiento de red durante esta investigación. [Search API oficial](https://performance-partners.apple.com/search-api).

Una automatización visual podría intentar las acciones normales de Música para añadir contenido. Sería una vía distinta y experimental: depende del idioma, la versión de Música, la vista actual, los diálogos y la intervención del usuario. Requiere permiso de Accesibilidad y una verificación posterior, además de Automation si usa Apple Events. No se habilitaron esos permisos para SpotAM Sync ni se ensayaron altas por interfaz. [Accesibilidad](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac), [agregar contenido desde Música](https://support.apple.com/guide/music/add-and-download-music-mus02acedfe/mac).

## Firma, permisos y distribución

La automatización local no solicita un developer token de MusicKit. Para Apple Events, la app declara `NSAppleEventsUsageDescription` y obtiene consentimiento del usuario. Con Hardened Runtime necesita `com.apple.security.automation.apple-events`; ese entitlement no concede por sí solo el permiso. Si se adopta App Sandbox, hay que evaluar los grupos de scripting que Música expone para lectura y escritura.

Usar una app construida localmente con firma ad hoc es distinto de distribuir una app firmada con Developer ID y notarizada. La primera vía no requiere una identidad Developer ID, pero su identidad puede cambiar al recompilar y afectar los permisos persistidos. El grupo podría compilar localmente durante las pruebas; no se propone desactivar Gatekeeper ni otros controles del sistema. La suscripción Apple Music/iTunes Match necesaria para las funciones cloud es un requisito separado de la membresía Developer.

Fuentes: [firma ad hoc](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc), [entitlements sin provisión en macOS](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), [Apple Events](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [identidad de firma](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Sync Library](https://support.apple.com/en-ie/118285).

## Integración necesaria en SpotAM Sync

1. **Origen explícito.** Mostrar “Música local · exportación del …”, separado de la conexión MusicKit. Un ID persistente de biblioteca identifica esa biblioteca, no una Apple Account. Los IDs locales no se deben enviar a endpoints REST.
2. **Modelo de cobertura.** Conservar carpetas, listas inteligentes, listas del sistema, pistas sólo presentes en playlists y datos desconocidos. No afirmar que una agrupación por nombre de álbum equivale a un álbum guardado completo.
3. **Alcance por colección.** El ejecutor actual exige ambos inventarios completos. Una fuente XML con identidad cloud o estado de álbumes desconocidos no debe marcarse `complete=true` para pasar ese control. Primero hay que introducir un contrato de transferencia desde instantánea y alcance verificado por colección.
4. **Coincidencias.** Usar artista, título, versión, duración y explicitud; conservar ambigüedades y correspondencias manuales. No convertir un persistent ID a decimal y tratarlo como catalog ID.
5. **Frescura.** Una exportación es una instantánea. Para una transferencia aditiva puede ser una referencia aprobada; para reconciliar contra Música en vivo hacen falta una nueva exportación/lectura y comparación antes de escribir. El hash de un archivo sin cambios no prueba que Música no haya cambiado.
6. **Capacidades acotadas.** Empezar con comparación y transferencia aditiva hacia Spotify. Habilitar escrituras Apple por operación sólo después del ensayo; mantener visibles los faltantes que requieren incorporación manual.
7. **Verificación diferenciada.** Separar “comprobado en Música local” de “confirmado en nube”. Mantener el journal, la prohibición de reintentos ciegos y la revocación de aprobaciones actuales.

## Ensayo para habilitar escrituras locales

Preparar una biblioteca de prueba separada y dos pistas locales prescindibles. Para probar propagación cloud, usar una cuenta de prueba separada: otra biblioteca local conectada a la misma cuenta no garantiza aislamiento de la biblioteca personal.

El ensayo debe crear únicamente playlists identificadas como pruebas, insertar `A, B, A`, releer orden y multiplicidad, cerrar/reabrir Música y comprobar persistencia. La eliminación de una ocurrencia se prueba sólo dentro de esas listas y debe conservar las otras ocurrencias, las pistas originales y las listas de control. Antes de cualquier operación destructiva, mostrar y aprobar los objetos concretos del ensayo.

Después se valida la misma secuencia con pistas de suscripción, incluidas no descargadas, y se verifica desde un segundo cliente. También deben cubrirse timeout después de una escritura, cambio de biblioteca, rechazo/revocación de permisos, Música cerrada y cambios concurrentes. No borrar automáticamente el material del ensayo ni habilitar bajas generales por el mero éxito de crear una playlist.

## Alcance de esta entrega

Investigación, prueba diagnóstica de lectura, exportación local y herramienta de inspección. La app, sus proveedores y sus capacidades de escritura permanecen sin cambios. No se hicieron commits ni se enviaron datos de la biblioteca a servicios externos.
