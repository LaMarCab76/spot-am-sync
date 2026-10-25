# Comparación incremental y transferencia desde XML

## Fuentes, identidad y cobertura

`ManualMusicLibrary` conserva los campos anteriores y añade opcionalmente `XMLLibraryInventory` y SHA-256 del documento. El estado anterior sigue decodificando; un documento antiguo sin inventario requiere reimportación para comparar playlists. Un PID único identifica una canción entre exportaciones; identidades ausentes o duplicadas quedan limitadas al documento y con cobertura parcial. No se convierten PIDs ni números de entrada en IDs de catálogo.

Se conserva jerarquía y tipo de playlist, secuencias con repeticiones y listas vacías. Las carpetas/listas especiales no se transforman silenciosamente en listas editables. La cobertura del documento y la cobertura de cada colección describen la evidencia importada, nunca toda la biblioteca cloud.

La membresía guardada desconocida permanece desconocida. El opt-in `includeUncertainXMLSongs` expresa una selección de destino para guardar esas pistas en Spotify; no cambia las métricas de membresía conocida ni autoriza inferir bajas. Los grupos de álbum XML no se consideran álbumes completos guardados.

## Comparación y revisión

`LibraryComparison` es puro: recibe fuentes, configuración, decisiones y una referencia histórica opcional. Devuelve diferencias con identidad estable, unidad, categoría, destino, candidatos, métricas y propuestas aditivas concretas. La presencia se verifica exclusivamente en inventarios observados. El catálogo ofrece equivalencias, no membresías.

Los vínculos de playlists existentes deben figurar explícitamente en la configuración. Los nombres sólo generan sugerencias. El alcance de sincronización no cambia los totales del inventario ni la clasificación fuera de playlists. Las apariciones se comparan conservando orden y repeticiones; una adición al final sólo se propone cuando conserva la secuencia deseada. Insertar, reemplazar, reordenar o quitar requiere revisión separada.

`LibrarySyncCoordinator` publica resultados mientras busca equivalencias. Las búsquedas tienen identidad de petición para descartar resultados obsoletos; cambiar de candidato o de alcance revoca las aprobaciones afectadas. Una revalidación fallida elimina la selección ejecutable. Dejar pendiente y omitir son decisiones persistentes distintas.

La confirmación captura un conjunto finito de diferencias y operaciones. Antes de aceptar el diálogo se comprueba que siga siendo el mismo. Los resultados posteriores no se incorporan al lote. Las bajas y los cambios de contenido/metadatos se confirman individualmente fuera del lote masivo de altas.

## Escritura, cancelación y recuperación

Análisis, revisión y aplicación tienen estados separados. La revisión puede continuar durante el análisis. La aplicación mantiene exclusión con análisis y búsquedas, revalida la cuenta y vuelve a leer el destino antes de escribir.

La transferencia XML usa `RunRecord.snapshotSource`: conserva la exportación aprobada, su identidad/digest, los IDs de diferencias y la fecha de aprobación. Sólo Spotify actúa como proveedor de esa ejecución; no se fabrica un snapshot cloud Apple completo. Las modificaciones destructivas requieren el indicador explícito de aprobación separada y cobertura completa de la fuente.

Se reutilizan lotes por petición, respaldo previo, journal durable, comprobación de estado no relacionado y readback del ejecutor. El ID del run se persiste en la aprobación antes del envío. La colisión con un run existente se rechaza bajo el lease y antes de guardar, para conservar la evidencia de escrituras inciertas.

Cancelar revoca los lotes aún encolados y reconcilia la petición en curso. Un timeout no se considera rechazo. Un reinicio no reanuda escrituras XML: permite comprobar resultados y exige otro análisis/confirmación. Una aprobación huérfana sin journal se revoca tras comprobar su ausencia, liberando la revisión sin enviar nada.

SQLite esquema 2 añade `sync_documents` para sesiones, referencias y aprobaciones. La migración crea respaldo consistente y conserva los registros existentes. El checklist JSON anterior permanece separado e intacto. Borrar historial resuelto no borra las referencias de comparación.

## Portadas

Las URLs y bytes de portadas son presentación, fuera de igualdad/hash/huellas musicales y decisiones de equivalencia. `ArtworkComparison` compara píxeles normalizados y conserva estados igual/diferente/posible/no disponible. Una referencia Spotify se rechaza como evidencia del artwork Apple.

`MusicArtworkReader` sólo lee imágenes incrustadas de archivos autorizados y vinculados al XML. No lanza Música, controla la app, inicializa ITLibrary ni consulta bases o cachés privadas. No obtiene portadas de playlists XML ni demuestra el estado de la nube. La interfaz mantiene esas limitaciones visibles.

## Validación

Los tests usan XML, imágenes, almacenamiento y proveedores sintéticos. Cubren importación/identidad, membresías, ambigüedades, baseline, orden/repeticiones, aprobación finita, cancelación, revalidación fallida, reemplazo de búsquedas, reinicio, journal incierto, colisión de IDs y migración. Los tests de callback OAuth requieren permitir un listener local en 127.0.0.1.

La aceptación gráfica debe lanzarse con `SPOTAM_DATA_DIR` temporal antes de iniciar el ejecutable. Una demo verificada no acredita las capacidades de una cuenta real, MusicKit, la propagación cloud ni el envío de notificaciones.

### Validación ejecutada el 24 de octubre de 2026

- Suite integrada: 412 tests, cero fallos (255 SyncCore, 45 interfaz/coordinación y 112 proveedores), incluido un inventario sintético de 1.500 canciones. Las pruebas de callback local se ejecutaron con permiso para el listener; el primer intento bajo sandbox rechazaba esa operación.
- Regresiones de revisión: confirmación durante análisis, resultados posteriores fuera del lote, cancelación de la última petición sin iniciar otro lote, revalidación manual fallida, reemplazo de búsquedas y recuperación de aprobación sin journal.
- Confirmaciones separadas: quitar una membresía guardada conserva las apariciones de playlists; reemplazar una secuencia conserva orden y repeticiones; un lote oficial finito no cuenta diferencias ajenas como operaciones pendientes de ese lote.
- Demo nativa con Bundle ID de QA y almacenamiento temporal: asistente, selección de una playlist, confirmación concreta, aplicación y readback en proveedor ficticio, permanencia en la pantalla de revisión, búsqueda de equivalencias y biblioteca Spotify con unidades separadas. Se verificó el mensaje final de lote y el inicio automático con `--demo`.
- No se modificaron bibliotecas ni se usaron autorizaciones de cuentas reales. La extracción local de artwork se prueba con medios sintéticos; no se leyó la biblioteca personal para validar portadas.
