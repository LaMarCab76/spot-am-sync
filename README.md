# SpotAM Sync

Aplicación nativa para macOS que compara bibliotecas de Spotify y Apple Music, prepara cambios revisables y ejecuta las operaciones compatibles con respaldo y comprobación posterior.

Requiere macOS 14 o posterior. La interfaz está en español. Los datos de análisis y el historial permanecen en el Mac.

## Empezar

Con Xcode instalado:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open "build/SpotAM Sync.app"
```

El script elige `/Applications/Xcode.app/Contents/Developer` sólo para ese proceso, sin cambiar `xcode-select`. También acepta `DEVELOPER_DIR` si Xcode está en otro lugar.

La app incluye **Probar demostración**, con dos bibliotecas ficticias y proveedores en memoria. Permite revisar coincidencias, confirmar cambios, ver progreso e inspeccionar el historial sin acceder a cuentas reales. Los resultados de demostración están identificados como tales.

```sh
open "build/SpotAM Sync.app" --args --demo
```

## Conectar Spotify

1. Registrá una app en el [panel de Spotify](https://developer.spotify.com/dashboard).
2. Registrá exactamente este redirect URI: `http://127.0.0.1:43821/callback`.
3. Agregá los usuarios autorizados en la configuración de esa app.
4. En **Conexiones**, ingresá su Client ID público y elegí **Conectar Spotify**.
5. Autorizá el acceso en el navegador del sistema.

Se usa Authorization Code con PKCE y verificación de `state`. No se solicita client secret ni contraseña. Los tokens se guardan en Keychain. Desconectar elimina el permiso almacenado por esta app; la revocación global puede hacerse desde Spotify.

Las apps nuevas en Development Mode admiten hasta cinco usuarios autorizados y necesitan que su propietario tenga Spotify Premium. El acceso a playlists ajenas puede estar restringido. Una playlist que no puede leerse queda marcada como incompleta; nunca se considera vacía. Ver [quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) y [cambios de API](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide).

## Lista manual para Apple Music, sin membresía Developer

La sección **Agregar a Apple Music** compara las canciones de Spotify con una exportación local de Música y prepara una lista que podés ir marcando. Sólo necesita la conexión de Spotify: no usa MusicKit ni solicita permiso para controlar Música.

1. En Música del Mac, elegí **Archivo → Biblioteca → Exportar biblioteca…** y guardá el XML.
2. En SpotAM Sync, abrí **Agregar a Apple Music** e importá ese archivo.
3. Conectá Spotify desde **Conexiones** y generá la lista. Se incluyen canciones de playlists, canciones guardadas y pistas de álbumes guardados, sin repetir una fila por cada aparición en una playlist.
4. Usá **Buscar en Apple Music** para localizar cada canción, agregala desde Música y marcala en la lista. Podés desmarcarla si necesitás revisarla otra vez.
5. Para comprobar incorporaciones, exportá de nuevo la biblioteca de Música, importá el XML actualizado y volvé a comparar.

Los filtros separan pendientes, coincidencias para revisar, marcas manuales y canciones presentes en la exportación. Las marcas y la última lista se guardan localmente para continuar después de cerrar la app; quedan separadas por cuenta de Spotify y biblioteca de Música. El ejemplo de esta pantalla usa datos ficticios y no reemplaza la lista real guardada.

**Una marca sólo registra tu avance:** no agrega canciones ni confirma cambios en Apple Music. “Presente” significa que se encontró una coincidencia compatible en el XML importado. La app muestra las fechas de los inventarios; una exportación anterior puede no reflejar cambios recientes ni todo el estado cloud. Las versiones ambiguas, los metadatos insuficientes y las lecturas parciales quedan para revisión. Los identificadores locales del XML nunca se convierten en identificadores del catálogo.

El XML se procesa en el Mac. La búsqueda se abre únicamente cuando pulsás el botón de una canción. No se habilitan eliminaciones ni otras escrituras en Música dentro de este flujo.

## Conectar Apple Music mediante la integración oficial

La integración oficial requiere que quien registra y distribuye la app tenga una membresía del **Apple Developer Program**, una app correctamente firmada y un App ID explícito con MusicKit habilitado. Los usuarios del grupo sólo necesitan autorizar sus bibliotecas; no necesitan ser desarrolladores. El build local ad hoc sirve para desarrollar, usar la demostración y conectar Spotify; **no habilita MusicKit por sí solo**.

1. Configurá el App ID en Apple Developer y habilitá MusicKit.
2. Prepará una identidad de firma de tu equipo de Apple Developer en Keychain.
3. Compilá con ese Bundle ID y la identidad que corresponda:

```sh
APP_BUNDLE_ID=com.tuorganizacion.spotamsync \
SIGNING_IDENTITY='Developer ID Application: Tu organización (TEAMID)' \
bash scripts/build-app.sh
```

MusicKit se habilita como **App Service** del App ID; no tiene un entitlement propio que deba inventarse o agregarse al paquete. El script firma la app; la solicitud autenticada comprueba su acceso efectivo al servicio. No se distribuye una clave privada `.p8` ni se necesita un servidor propio para custodiarla. Ver [aclaración oficial de Apple](https://developer.apple.com/forums/thread/784114).

Después de `MusicAuthorization`, la app obtiene el developer token y el Music User Token mediante las APIs públicas de `DefaultMusicTokenProvider`. Las solicitudes REST usan una sesión HTTP efímera con esos tokens fijados, exclusivamente contra `https://api.music.apple.com`, sin redirects. Los tokens Apple permanecen en memoria y no se incluyen en diagnósticos. Un HTTP 401 exige reconectar explícitamente.

La cuenta debe permitir acceso a su biblioteca cloud. La identidad local representa la autorización mediante SHA-256 del Music User Token; no identifica un Apple ID. Es estable mientras el SDK entregue el mismo token. Una rotación cambia la identidad, aunque pertenezca a la misma cuenta. Cada reconexión genera una revisión nueva para invalidar aprobaciones anteriores. Nunca se supone que una cuenta de Música y una autorización distinta representan la misma biblioteca.

Documentación: [autorización](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit), [generación automática de tokens](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api).

## Qué sincroniza

- **Fusionar:** agrega elementos faltantes sin quitar contenido existente.
- **Spotify como base:** propone los cambios en Apple Music.
- **Apple Music como base:** propone los cambios en Spotify.
- Playlists: nombre, descripción, secuencia y multiplicidad de canciones.
- Canciones guardadas y álbumes, manteniendo sus estados separados de las playlists.
- Coincidencias por identificadores y metadatos, con revisión manual para ambigüedades.
- Vínculos manuales entre playlists y protección de playlists seleccionadas.

Las búsquedas conservan los candidatos recibidos aunque falle una página posterior. La interfaz diferencia una búsqueda completa, limitada, fallida o parcialmente fallida de una ausencia de equivalencias. Apple completa las referencias adicionales de ISRC antes de confirmar una coincidencia única. Si el ISRC no resuelve la canción, ambos servicios prueban título, artista y álbum, y después título y artista. Los alias de biblioteca y catálogo con la misma identidad y metadatos compatibles se evalúan como un solo candidato; las contradicciones permanecen para revisión.

Cada búsqueda dispone de hasta 12 solicitudes de catálogo, contando reintentos, y dos páginas por consulta o relación. La búsqueda de álbumes expande hasta tres ediciones. Estos presupuestos no limitan la lectura de las bibliotecas ni el checklist XML. Si queda información pendiente, no se selecciona una coincidencia automáticamente; se puede elegir manualmente entre los candidatos disponibles sin ocultar que la búsqueda quedó incompleta.

En **Playlists**, **Desvincular** permite quitar una correspondencia obsoleta, incluso si una de las playlists ya no existe. La acción guarda la decisión, revoca la aprobación anterior y recalcula la vista previa. Las modificaciones remotas siguen requiriendo confirmación.

Los “Me gusta” de Spotify se tratan como canciones guardadas. Los favoritos de Apple no se modifican. Guardar parte de un álbum no equivale a guardar su edición completa.

Una canción “suelta” es una canción guardada que no se encontró en las playlists analizadas. El resumen incluye el detalle de esas canciones y de los álbumes completos sin pistas presentes en playlists. Los álbumes parciales aportan sólo sus pistas guardadas. Si faltan playlists, contenidos o identificadores, la clasificación queda por confirmar; no se presenta un total definitivo.

## Límites reales del espejo

Spotify permite las altas, bajas y actualizaciones contempladas, sujeto a acceso y propiedad. Quitar una playlist significa quitarla de la biblioteca del usuario, no destruirla para sus seguidores.

Apple Music documenta altas en biblioteca, creación de playlists y adición de canciones al final. Su API REST pública no documenta bajas generales de biblioteca, eliminación de playlists, edición de metadatos existentes ni reordenamiento/reemplazo de contenido. Esas operaciones se muestran en la vista previa **bloqueadas**, con explicación. No se sustituyen por endpoints privados o borrados no comprobados. Una ejecución con diferencias pendientes no se presenta como un espejo completo.

La automatización de Música en macOS requiere validación adicional de identidad, efectos sobre biblioteca y propagación cloud. La disponibilidad de un comando `delete` en su diccionario no demuestra que sea seguro aplicarlo a recursos cloud. No está habilitada para escrituras. Detalles en [capacidades de Apple](docs/APPLE_CAPABILITIES.md).

## Ejecución y recuperación

1. La app guarda el plan aprobado y los inventarios anteriores en SQLite antes de escribir.
2. Comprueba que las conexiones y el estado no cambiaron desde la vista previa.
3. Aplica primero altas y después operaciones destructivas autorizadas.
4. Cada lote tiene un registro durable de intención, respuesta y verificación.
5. Relee el servicio para comprobar el resultado, incluyendo orden y repeticiones.
6. Un timeout de escritura se considera incierto hasta reconciliarlo. No se repite ciegamente.
7. Cambios externos y efectos adicionales del servicio detienen la ejecución para un nuevo análisis.

Las operaciones compuestas se desglosan antes de ejecutarse: cada petición de playlist tiene su propio registro y cada canción o álbum de biblioteca conserva su resultado individual dentro del lote HTTP. La creación guarda y verifica el ID de la playlist antes de enviar sus canciones. Un rechazo explícito sin una escritura previa incierta queda registrado como rechazado y permite preparar un nuevo plan; un timeout conserva la incertidumbre. Por ejemplo, si Spotify guarda 40 canciones y rechaza la siguiente, el nuevo análisis propone sólo la faltante.

Los nuevos registros comparten las instantáneas de evidencia en `executionSnapshots` y las referencian desde cada ejecución para evitar repetir la biblioteca por cada canción. La app sigue leyendo registros anteriores, pero no reanuda sus escrituras compuestas: permite comprobarlos mediante lectura y exige un nuevo plan. Las escrituras antiguas que sigan inciertas continúan bloqueando operaciones que se solapen.

**Cancelar** detiene nuevas operaciones y reconcilia la que estaba en curso. **Comprobar pendientes** sólo lee el servicio para resolver resultados inciertos, incluso después de reiniciar y reconectar cuando puede verificarse la misma identidad. Para enviar nuevas operaciones hay que analizar y confirmar una nueva vista previa. Cambiar el modo, las protecciones o las correspondencias revoca las aprobaciones anteriores.

Una lectura sin cambios no prueba que una petición haya sido rechazada: Apple puede tardar en reflejar las altas. Las creaciones y adiciones inciertas no se reenvían automáticamente. Mientras haya una escritura sin resolver, se bloquean nuevas ejecuciones que puedan solaparse, también después de reiniciar la app. No se permite escribir con un inventario incompleto.

El historial permite exportar el resultado y el respaldo en JSON. El respaldo conserva metadatos y estructura; no contiene archivos de audio ni tokens. No existe una promesa de restauración automática perfecta: algunas operaciones inversas no están soportadas o perderían identificadores y enlaces.

Datos locales: `~/Library/Application Support/SpotAMSync/library-sync.sqlite`, con permisos privados. Para pruebas aisladas se puede definir `SPOTAM_DATA_DIR` antes de iniciar el ejecutable. Los tokens de Spotify se almacenan aparte, en Keychain.

## Distribuir al grupo

Antes de distribuir, verificá el número de usuarios autorizados en Spotify, habilitá MusicKit para el App ID, firmá con Developer ID y notarizá la app. Guardá las credenciales de notarización en Keychain mediante `notarytool`, fuera del repositorio:

```sh
NOTARY_PROFILE=tu-perfil-de-keychain bash scripts/notarize.sh
```

El script envía el paquete a Apple, espera el resultado y adjunta el ticket. No se ejecuta durante una compilación local normal. Las claves, certificados y perfiles privados no se incluyen en Git.

## Estructura

- `Sources/SyncCore`: modelos, coincidencias, planificación, verificación, journal SQLite y ejecutor.
- `Sources/MusicProviders`: OAuth, Keychain, transporte HTTP y adaptadores oficiales.
- `Sources/SpotAMSync`: estado de la app e interfaz SwiftUI.
- `Tests`: pruebas de contratos, coincidencias, fallos de red, paginación, recuperación y concurrencia.
- `scripts`: compilación del paquete, pruebas y notarización.

Las pruebas usan proveedores y transportes controlados; no modifican cuentas reales. La aceptación con cuentas reales requiere completar las autorizaciones y verificar primero contenido destinado a pruebas.
