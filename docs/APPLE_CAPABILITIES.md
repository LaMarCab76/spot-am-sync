# Apple Music: contrato y validación pendiente

Fuentes y SDK inspeccionados el 23 de octubre de 2026. No se ejecutaron cambios sobre bibliotecas personales para determinar estas capacidades.

## Operaciones habilitadas

Apple Music API documenta lectura paginada de biblioteca, relaciones y catálogo, `POST /v1/me/library`, `POST /v1/me/library/playlists` y `POST /v1/me/library/playlists/{id}/tracks`. La app implementa esas operaciones y confirma su efecto con una lectura posterior. El alta en biblioteca puede devolver `202` e ignorar elementos no agregables; ese código no es evidencia de convergencia.

- [Playlists API](https://developer.apple.com/documentation/applemusicapi/playlists-api)
- [Agregar recursos a biblioteca](https://developer.apple.com/documentation/applemusicapi/add-a-resource-to-a-library)
- [Paginación](https://developer.apple.com/documentation/applemusicapi/fetching-resources-by-page)

## Operaciones bloqueadas

No se encontró contrato REST público para quitar canciones o álbumes de la biblioteca, eliminar playlists, reemplazar/reordenar sus canciones o editar sus metadatos existentes. El atributo `canEdit` no habilita endpoints que no estén documentados.

La edición de playlists mediante `MusicLibrary.edit` sólo está documentada para playlists creadas por la propia app, y sus métodos de escritura aparecen como no disponibles en macOS/Mac Catalyst. El SDK local de Xcode lo confirma. Por eso no se usa MusicLibrary como vía indirecta de escritura en macOS.

- [MusicLibrary](https://developer.apple.com/documentation/musickit/musiclibrary)
- [Contrato de edit](https://developer.apple.com/documentation/musickit/musiclibrary/edit(_:name:description:authordisplayname:items:))
- [Favoritos: terceros no pueden quitarlos](https://support.apple.com/en-us/111118)

## Investigación de automatización local

Actualización: se completó una investigación adicional y una prueba real de exportación XML sin membresía Developer. El lector iTunesLibrary devolvió un inventario vacío contradictorio con Música; el XML sí pudo validarse. Ver [viabilidad del modo local](LOCAL_MUSIC_FEASIBILITY.md) para evidencia, límites e integración propuesta. Esto no habilita escrituras locales.

El diccionario instalado de Música (`/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`) declara `delete`, `duplicate`, `make`, playlists y tracks con persistent IDs. `move` documenta mover playlists, no un contrato de reordenamiento de canciones. La biblioteca combina tipos de contenido local y cloud y no ofrece un vínculo probado con todos los identificadores REST.

Habilitar un adaptador de escritura exige probar, con material destinado a validación:

1. Vínculo inequívoco entre la autorización, la biblioteca local y cada objeto cloud.
2. Eliminación de una ocurrencia sin borrar otras ocurrencias ni quitar la canción de biblioteca.
3. Eliminación de playlists sin efectos sobre otras listas, canciones o archivos locales.
4. Tratamiento explícito de álbumes parciales, compras, importaciones y archivos descargados.
5. Propagación y posterior lectura consistente en la biblioteca cloud.
6. Rechazo por permisos y revocaciones, aplicación cerrada, sincronización cloud desactivada y cambios concurrentes.
7. Registro de intención, respaldo, reconciliación y recuperación del resultado incierto.

Esta evidencia no está disponible sin cuentas configuradas y un escenario de pruebas. Ninguna escritura AppleScript está habilitada ni se solicita permiso de automatización de Música por anticipado. Las bajas necesarias siguen visibles como pendientes en la vista previa.
