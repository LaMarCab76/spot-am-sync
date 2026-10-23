# Validación local — 23 de octubre de 2026

Entorno: Mac Apple Silicon, macOS 27.0.1, Xcode 27.1, Swift 6.4 en modo de lenguaje Swift 5. Deployment target: macOS 14. El paquete generado es arm64.

## Pruebas y compilación

- `bash scripts/test.sh`: **152 pruebas aprobadas**, sin fallos —94 de SyncCore y 58 de MusicProviders—.
- `bash scripts/build-app.sh`: compilación de producción y empaquetado correctos.
- `codesign --verify --deep --strict 'build/SpotAM Sync.app'`: correcto.
- Firma local **ad hoc**, sin TeamIdentifier. No es una distribución notarizada ni habilita la integración de producción con MusicKit.
- Icono ICNS y ejecutable Mach-O arm64 presentes y reconocidos.

Las pruebas usan transportes y proveedores controlados. Cubren paginación, permisos, identidad, coincidencias ambiguas, orden y duplicados, álbumes parciales, inventarios incompletos, revocación de aprobaciones, cancelación antes del envío, errores después de escrituras, recuperación entre ejecuciones y continuidad de la autorización Apple.

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

## Pendiente con servicios reales

- Spotify: introducir el Client ID público de la app registrada, verificar el redirect URI, autorizar una cuenta habilitada y probar primero contenido destinado a pruebas.
- Apple Music: disponer de la firma y el App ID del Apple Developer Program con MusicKit habilitado; autorizar y verificar el acceso efectivo a la biblioteca.
- La revisión automática de acciones rechazó la prueba del botón «Conectar Apple Music» por el posible inicio de una solicitud de permisos. Se comprobó el requisito de firma mediante lectura del paquete y del código; no se autorizó una cuenta ni se leyó una biblioteca real.
- Distribución al grupo: firma Developer ID, notarización y prueba en otro Mac.
- Automatización local de Música sin MusicKit: no implementada; requiere demostrar identidad, operaciones permitidas y propagación a la biblioteca cloud antes de habilitar escrituras.

Las bajas y los reemplazos que Apple Music no documenta en su API pública permanecen bloqueados. No se realizaron commits, pushes ni modificaciones de bibliotecas reales.
