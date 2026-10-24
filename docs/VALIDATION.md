# Validación local — 23 de octubre de 2026

Entorno: Mac Apple Silicon, macOS 27.0.1, Xcode 27.1, Swift 6.4 en modo de lenguaje Swift 5. Deployment target: macOS 14. El paquete generado es arm64.

## Pruebas y compilación

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
