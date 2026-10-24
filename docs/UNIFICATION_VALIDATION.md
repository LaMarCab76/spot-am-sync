# Validación de la unificación Swift — 24 de octubre de 2026

## Entorno y alcance

Verificado en Mac Apple Silicon con macOS 27.0.1, Xcode 27.1 y Swift 6.4. Se conserva deployment target macOS 14 y modo de lenguaje Swift 5. El paquete generado es arm64. La ejecución en macOS 14 y en equipos Intel no se comprobó.

El trabajo se realizó en `feature/swift-unification`, dentro de un worktree independiente. El checkout original permanece limpio en `main` (`4a219ff`). El merge inicial conserva como ancestros el `main` remoto Electron y la rama nativa completa. No se reescribieron historias ni se eliminaron ramas remotas.

## Pruebas automatizadas

`bash scripts/test.sh`: **259 pruebas aprobadas, cero fallos**:

- SyncCore: 172 pruebas.
- MusicProviders: 66 pruebas.
- Modelos de la app: 21 pruebas.

La base anterior tenía 221 pruebas. Las 38 incorporadas cubren alcance exclusivo por playlist, dirección, cuentas y storefront, orden y multiplicidad, deduplicación explícita, copia y recuperación de su ID desde el journal, decisiones anteriores fuera del alcance, destinos ambiguos, cambios de configuración y rechazo de vistas previas obsoletas, cola, pausa, cancelación de lecturas tardías, programación sin escrituras, DST, reinicio, migración SQLite con respaldo, rechazo de esquemas futuros, conservación de registros inciertos, propuestas inversas, protecciones e importación limitada de preferencias Electron.

Los tests de programación comprueban que una propuesta lista no envía mutaciones. El ejecutor comprueba la configuración persistida antes de escribir, incluso si cambió mediante otra instancia de `SyncStore`. Los tests de copia comprueban creación y adición verificadas, conservación del destino y ausencia de una segunda creación al reanalizar. Las revisiones sin diferencias finalizan sin aprobación y permiten la próxima revisión programada.

## Compilación y paquete

- `bash scripts/build-app.sh`: producción compilada y empaquetada.
- `codesign --verify --deep --strict 'build/SpotAM Sync.app'`: correcto.
- Versión 0.2.0, Bundle ID `com.lamarcab.spotamsync`, ejecutable Mach-O arm64.
- Firma local ad hoc, sin TeamIdentifier. No es un paquete notarizado ni habilita por sí solo MusicKit de producción.
- No quedan runtime Electron, manifiestos npm ni archivos React/TypeScript en la implementación activa.
- `git diff --check`: sin errores.

## Comprobación nativa

Se abrió el build compilado con `SPOTAM_DATA_DIR` temporal y proveedores de demostración. Se verificó:

- Inicio, navegación, barra flotante y selección de playlists.
- Detalle con las cuatro ocurrencias de una playlist, incluida su repetición intencional.
- Comparador desde el detalle: búsqueda sin cerrar la hoja, elección manual y actualización de la fila sin ejecutar cambios.
- Asistente completo: dirección, selección de una sola playlist, opciones, frecuencia y zona horaria.
- Edición de una configuración que conserva la selección e invalida la propuesta anterior.
- Propuesta de copia con una operación disponible y cero observaciones fuera del alcance.
- Confirmación explícita y ejecución de dos pasos de demostración: creación y adición, ambos verificados.
- Resultado completado y nuevo análisis con cero operaciones y cero observaciones, sin otra creación.
- Historial por pasos y propuesta inversa que muestra bloqueada la eliminación no compatible de Apple Music.
- Ajustes de sincronización y coincidencias con textos que conservan la revisión de ediciones ambiguas.
- Cierre de la última ventana y reapertura de la principal, conservando las cuentas y bibliotecas de demostración en memoria. La comprobación se realizó con el paquete QA de identidad separada y entorno temporal fijado.

El recorrido detectó y permitió corregir observaciones de playlists ajenas al alcance, el nombre pendiente de una copia ya creada, el tratamiento de propuestas sin diferencias y la reapertura después de cerrar la última ventana.

## Migración local observada durante la validación

El primer intento de arranque aislado fue abortado por el sandbox antes de crear su base temporal. La herramienta de UI abrió entonces una instancia sin ese entorno y la base habitual pasó de esquema 0 a 1. Se cerró esa instancia y se continuó con el entorno temporal explícito.

Se comprobó mediante copias locales de lectura, incluyendo WAL, que `runs` y `decisions` de la base habitual son idénticos a su respaldo previo: tres registros de historial, cero decisiones guardadas y los mismos payloads completos. El respaldo consistente se conserva en:

`~/Library/Application Support/SpotAMSync/library-sync-before-workspace-<UUID>.sqlite`

La modificación habitual fue la migración del esquema y la inicialización del workspace. No se conectaron cuentas ni se escribieron bibliotecas remotas durante esa apertura.

La revisión automática rechazó posteriormente una apertura desde Finder que no garantizaba el entorno temporal. Para aislar la prueba de reapertura se creó un paquete QA en `/private/tmp`, con Bundle ID separado y `SPOTAM_DATA_DIR` fijado en `LSEnvironment`. Ese paquete no se instala ni forma parte de la entrega de producción.

## Aceptación externa pendiente

Las pruebas de proveedores usan transportes controlados o proveedores en memoria. No se modificaron bibliotecas reales de Spotify ni Apple Music. Quedan para aceptación con contenido destinado a pruebas:

- OAuth y permisos efectivos de las cuentas que usarán la app.
- Firma con equipo Developer ID y App ID con MusicKit habilitado.
- Operaciones reales permitidas, propagación de cambios y comprobación de resultados.
- Notificaciones autorizadas por el usuario en macOS; no se solicitó ese permiso durante la validación.
- Notarización y distribución a otros Macs.

La revisión programada requiere que el proceso esté ejecutándose y las cuentas estén conectadas. No se instala un LaunchAgent ni se ejecuta trabajo con la app terminada.
