# Consolidación nativa de Spot·AM Sync

## Procedencia y estructura

La rama de integración parte de `main` Electron (`ac9c287`) e incorpora mediante un merge de dos padres la historia de `base/native-swift-checklist` (`361e8bc`). La interfaz Electron y sus créditos siguen disponibles en el historial Git. La aplicación activa usa `Package.swift`, SwiftUI, AppKit, los adaptadores oficiales y SQLite. Los manifiestos npm y el runtime Electron fueron retirados.

El checkout original, sus ramas y los datos del usuario no se reemplazan al desarrollar. Antes de la integración se verificó un bundle Git completo con todas las ramas.

## Contratos de alcance

`SyncRequest` captura identidad estable de ambas cuentas, storefront, revisión de configuración, dirección, referencias de playlists, destinos confirmados y opciones. La propuesta conserva los inventarios completos para comprobar cambios externos; filtrar el alcance no fabrica inventarios completos.

Una petición por playlist no propone cambios en canciones o álbumes guardados y no elimina otras playlists del destino. Una dirección con base solo permite playlists de ese origen. La fusión incorpora la contraparte de un vínculo confirmado y no permite bajas o reemplazos. No se aceptan cuentas o regiones diferentes, IDs faltantes, vínculos ambiguos o alcances vacíos. Los vínculos guardados en una configuración prevalecen sobre posteriores cambios de vínculos globales.

La sincronización global de bibliotecas sigue disponible de forma explícita en Bibliotecas. Los favoritos de Apple y las operaciones sin contrato público conservan sus restricciones.

`keepOrder` conserva por defecto la secuencia de origen. Desactivado, conserva el orden actual de las ocurrencias que aún pertenecen a la propuesta y agrega las faltantes. `skipDuplicates` conserva únicamente la primera ocurrencia de cada ID de destino cuando el usuario lo activa. La multiplicidad predeterminada y las comprobaciones de lotes no cambian.

La política de copia crea una playlist independiente. Cada paso durable conserva la referencia de origen y el ID creado verificado. La configuración guarda ese ID incluso si falla un lote posterior. Un destino de copia desaparecido se informa como pendiente; no provoca otra creación automática. Una creación incierta bloquea otras escrituras hasta reconciliarse. Al iniciar o reconciliar se recuperan los destinos desde recibos verificados del journal, incluso si el cierre ocurrió antes de guardar la configuración. Si aparecen destinos contradictorios no se elige uno implícitamente.

## Cola, aprobación y programación

`WorkspaceCoordinator` persiste configuraciones y propuestas mediante `SyncStore`. Serializa la preparación usando el estado ocupado de la app. La interfaz permite pausar, preparar de nuevo, revisar y retirar entradas de la cola. Pausar una escritura detiene nuevas operaciones y completa la reconciliación de la petición en curso; los pasos verificados permanecen en el journal.

`ReviewSchedule` no contiene una autorización de escritura. El temporizador de la app y el evento de despertar solo pueden encolar lecturas. Se respeta la zona horaria guardada y se calcula el siguiente horario con un calendario, incluidos los cambios de horario de verano. Una cuenta desconectada no consume el vencimiento. No se acumulan todos los intervalos vencidos ni se duplican propuestas pendientes de una configuración.

Una propuesta lista no es una aprobación. `executeApproved` requiere una acción de confirmación, una revisión vigente y una selección compatible. Antes de la primera mutación y entre lotes, `SyncExecutor` verifica cuentas, permisos, capacidades e inventarios. Editar una configuración revoca las aprobaciones relacionadas. Una cola restaurada nunca retoma escrituras por sí sola. Una revisión completa sin diferencias finaliza sin aprobación ni escrituras y no bloquea el siguiente vencimiento.

La app permanece ejecutándose al cerrar su última ventana. Abrirla nuevamente muestra la ventana principal, y el menú Archivo ofrece Abrir ventana principal (⌘0). ⌘Q termina el proceso; no se instala un LaunchAgent ni un helper. Al abrir o despertar se comprueban revisiones vencidas. La programación depende de cuentas conectadas y autorizaciones vigentes. Si falta acceso, la propuesta queda pendiente de intervención.

Las notificaciones usan UserNotifications únicamente si macOS lo permite. Nunca se solicita ese permiso durante el arranque; el usuario lo solicita desde Ajustes. La cola sigue siendo el lugar persistente para revisar los resultados aunque los avisos estén desactivados.

## Historial y propuestas inversas

Las ejecuciones se muestran por pasos con estados separados: sin enviar, en curso, verificado, rechazado, fallido e incierto. CSV exporta los resúmenes disponibles y protege valores que un lector de hojas de cálculo podría interpretar como fórmulas. JSON conserva inventarios y evidencia detallada, sin tokens ni audio.

Comprobar resultados inciertos solo lee. Preparar de nuevo realiza otro análisis y requiere confirmación. Deshacer genera un `SyncPlan` inverso con referencia a la ejecución original y comprueba que el estado actual siga siendo el registrado. Rechaza resultados inciertos o bibliotecas modificadas. Las operaciones inversas no soportadas quedan bloqueadas y visibles; no se promete restaurar el ID, enlaces o seguidores de una playlist eliminada. El ejecutor aplica y verifica una propuesta inversa con las mismas garantías que cualquier otra ejecución.

## Persistencia y migración

El esquema SQLite pasa de `user_version=0` a `1`, con una tabla `workspace`. Antes de migrar una base existente, se usa la API de backup SQLite, que incluye correctamente el estado WAL, en `library-sync-before-workspace-<UUID>.sqlite`. Se mantienen `runs` y `decisions` y sus formatos anteriores. Campos nuevos opcionales permiten leer planes y canciones existentes. Una versión futura incompatible se rechaza.

Preferencias y configuraciones no almacenan tokens. El Bundle ID se conserva (`com.lamarcab.spotamsync`). El directorio por defecto sigue siendo `~/Library/Application Support/SpotAMSync`, y `SPOTAM_DATA_DIR` permite aislar pruebas. El modo demo mantiene su workspace en memoria separado del real; los registros de simulación permanecen identificados como tales.

El borrado de historial resuelto conserva ejecuciones en curso y registros con evidencia incierta necesaria para recuperar escrituras. Eliminar configuraciones o desconectar cuentas no modifica bibliotecas remotas ni elimina el journal.

## Preferencias de Electron

No se detectaron los directorios de datos Electron candidatos `~/Library/Application Support/spot-am-sync` ni `~/Library/Application Support/SpotAM Sync` durante esta integración. Esto no es un inventario exhaustivo de instalaciones con otro nombre.

Ajustes permite seleccionar un JSON de las preferencias anteriores (`spotam:prefs:v1`). Se admite el objeto con `settings` mediante una lista explícita de campos compatibles. Se descartan conectividad simulada, música, historial y programación sin alcance. Dirección, política de destino, preferencias de avisos y prioridad de versiones de estudio pueden trasladarse. La tolerancia y la aceptación automática de remasterizaciones no relajan la comprobación estricta de edición.

Para obtener ese JSON desde la implementación anterior, el usuario puede exportar el valor de `localStorage.getItem('spotam:prefs:v1')` desde sus herramientas de desarrollo. No se leen automáticamente cookies, bases del navegador ni credenciales.

## Interfaz nativa

Inicio, asistente, detalle de playlist, cola, comparadores, historial y Ajustes usan SwiftUI. Se conservan la biblioteca guardada, el checklist XML, las protecciones y el detalle de operaciones de la implementación nativa. No existe una WebView ni una interfaz React incrustada. Los colores de servicios se limitan a sus marcas y las advertencias conservan un color distinto. Los materiales del sistema respetan las preferencias de accesibilidad.

Las portadas de playlists se leen del metadato oficial por HTTPS. Las URLs de portada son presentación y no forman parte del fingerprint de estado musical. Las filas de canciones conservan índices de ocurrencia para que los duplicados no desaparezcan de la vista. Elegir una coincidencia no equivale a verificar una escritura ni a confirmar presencia en el XML.
