# Spot·AM Sync

App de escritorio (Electron) para sincronizar playlists entre Spotify y Apple Music.
La interfaz sigue el diseño "Liquid": contenido plano sobre negro, color solo en las
portadas, y vidrio translúcido únicamente en los controles que flotan encima
(barra de sincronización, navegación sobre la portada, hojas).

> Estado: la interfaz completa funciona con datos de ejemplo. Todavía no se conecta
> a las APIs de Spotify ni de Apple Music (ver [Próximos pasos](#próximos-pasos)).

## Pantallas

| Ruta | Pantalla | Qué hace |
|---|---|---|
| `#/conectar` | Conectar cuentas | Primer uso: Spotify conectado, conectar Apple Music y continuar. |
| `#/inicio` | Inicio | Resumen: canciones para revisar, próxima sync automática, cuentas, playlists con cambios y actividad. |
| `#/playlist/:id` | Playlist | Cabecera con la portada, dirección de la sync, sync automática, filtros por estado y lista de canciones. |
| `#/nueva` | Nueva sincronización | Asistente en 3 pasos: dirección, playlists y opciones. |
| `#/revisar` | Revisar coincidencias | Cola de canciones dudosas o no encontradas; elegir versión, omitir o buscar. Atajos: ↑ ↓, ↵ y S. |
| `#/historial` | Historial | Cada sincronización con su detalle, reintentar las fallidas y deshacer. |
| `#/ajustes` | Ajustes | Cuentas, sincronización, coincidencias, notificaciones y datos. |

## Desarrollo

Requiere Node 20.19+ o 22.12+.

```bash
npm install        # instala Electron, Vite, React y TypeScript
npm run dev        # abre la app con recarga en caliente
npm run typecheck  # revisa tipos de main, preload y renderer
npm test           # tests del estado (Vitest)
npm run build      # compila a out/
npm start          # abre la versión compilada
npm run dist       # genera el instalador del sistema actual (dist/)
```

`.npmrc` activa `legacy-peer-deps`: npm 10 falla al resolver las dependencias
opcionales de Vitest y así `npm install` y `npm ci` quedan alineados con el lockfile.

## Estructura

```
src/
  main/index.ts          Proceso principal: ventana, seguridad, enlaces externos
  preload/index.ts       Puente mínimo al renderer (solo la plataforma)
  renderer/
    index.html           Entrada con Content-Security-Policy estricta
    src/
      styles/global.css  Tokens de diseño (colores, vidrio, radios, tipografía)
      components/        Íconos, botones, interruptores, barra superior, menú y barra de sync
      screens/           Una pantalla por archivo, cada una con su CSS module
      store/             Estado de la app (reducer, selectores, tests)
      data/              Datos y portadas de ejemplo
      router.tsx         Rutas por hash (funcionan con file://)
```

## Decisiones de diseño

- **Tipografía:** SF Pro en Mac (fuente del sistema) e Inter como respaldo en Windows y Linux, incluida en la app.
- **Acento monocromo** (`#F2F2F7`) con texto oscuro encima. Verde y rosa quedan solo como marcas de Spotify y Apple Music; el naranja es el estado "Revisar".
- **Ventana sin barra de título nativa:** en Mac se ven los semáforos sobre la barra superior; en Windows y Linux, los controles nativos a la derecha. La barra superior sirve para arrastrar la ventana.
- **Seguridad:** `contextIsolation`, `sandbox` y sin `nodeIntegration`; navegación bloqueada fuera de la app y enlaces `https` en el navegador del sistema.

## Próximos pasos

1. **Spotify:** OAuth con PKCE y Web API (playlists, canciones, ISRC). Hace falta un Client ID de Spotify.
2. **Apple Music:** MusicKit con un developer token firmado con una clave de Apple Developer, más el user token del usuario.
3. **Comparación:** buscar por ISRC y, si no hay, por título, artista y duración (con la tolerancia de Ajustes), y mandar lo dudoso a Revisar.
4. **Sync automática:** programarla desde el proceso principal y avisar con notificaciones nativas.

Las portadas de ejemplo son fotos de Unsplash; ver [CREDITS.md](CREDITS.md).
