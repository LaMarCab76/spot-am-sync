import type { AppState, Playlist, ReviewItem, Run, Settings, Track, TrackStatus } from '../store/types'
import { albumArt, playlistArt } from './artwork'

// Sample library used until the real Spotify and Apple Music clients are wired
// in. Artists, songs and numbers are made up.

type Row = [title: string, artist: string, album: string, duration: string, status: TrackStatus]

const tracks = (rows: Row[]): Track[] =>
  rows.map(([title, artist, album, duration, status]) => ({ title, artist, album, duration, status }))

export const samplePlaylists: Playlist[] = [
  {
    id: 'noches', name: 'Noches de Verano', total: 86, duration: '5 h 12 min', lastSync: 'hace 3 días',
    artwork: playlistArt.noches, heroPosition: 'center 35%', matched: 78, review: 6, missing: 2,
    synced: false, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Marea Alta', 'Los Faroles', 'Costa Norte', '3:41', 'ok'],
      ['Bajo la Luna de Enero', 'Julieta Brisa', 'Postales', '4:05', 'rev'],
      ['Calor de Ciudad', 'Nube 9', 'Asfalto', '3:12', 'ok'],
      ['Verano Eterno (Remix)', 'Dúo Arrecife', 'Verano Eterno', '3:58', 'rev'],
      ['Polaroid', 'Camila Ferro', 'Revelado', '2:57', 'miss'],
      ['Ruta 2', 'La Brújula', 'Kilómetro Cero', '4:22', 'ok']
    ])
  },
  {
    id: 'focus', name: 'Focus Flow', total: 120, duration: '7 h 54 min', lastSync: 'hace 2 h',
    artwork: playlistArt.focus, heroPosition: 'center 62%', matched: 120, review: 0, missing: 0,
    synced: true, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Horizonte Lento', 'Atlas Quiet', 'Low Tide', '5:10', 'ok'],
      ['Paper Planes', 'Moss & Fern', 'Greenhouse', '3:44', 'ok'],
      ['Deep Field', 'Atlas Quiet', 'Low Tide', '6:02', 'ok'],
      ['Lumen', 'Niko Arden', 'Lumen', '4:18', 'ok'],
      ['Static Rain', 'Kai Ondo', 'Weather', '3:27', 'ok'],
      ['Northbound', 'Moss & Fern', 'Greenhouse', '4:51', 'ok']
    ])
  },
  {
    id: 'indie', name: 'Indie en Español', total: 64, duration: '3 h 48 min', lastSync: 'hace 1 semana',
    artwork: playlistArt.indie, heroPosition: 'center 55%', matched: 59, review: 4, missing: 1,
    synced: false, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Fotos Viejas', 'Club Tormenta', 'Fiebre', '3:35', 'ok'],
      ['Lunes', 'Las Moscas Azules', 'Semana', '2:49', 'rev'],
      ['Ciudad Dormida', 'Bruma', 'Ciudad Dormida', '4:10', 'ok'],
      ['Avenida', 'Teo Salinas', 'Avenida', '3:02', 'miss'],
      ['Algo Mejor', 'Club Tormenta', 'Fiebre', '3:51', 'ok'],
      ['Neón', 'Bruma', 'Ciudad Dormida', '3:19', 'rev']
    ])
  },
  {
    id: 'liked', name: 'Tus me gusta', total: 1248, duration: '72 h 50 min', lastSync: 'hace 1 día',
    artwork: playlistArt.liked, heroPosition: 'center 40%', matched: 1201, review: 31, missing: 16,
    synced: false, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Mil Kilómetros', 'Julieta Brisa', 'Postales', '3:33', 'ok'],
      ['Golden Hour Drive', 'Niko Arden', 'Lumen', '3:47', 'ok'],
      ['Fuego Lento', 'Dúo Arrecife', 'Verano Eterno', '3:25', 'rev'],
      ['Sin Señal', 'Nube 9', 'Asfalto', '2:58', 'ok'],
      ['Antes del Final', 'La Brújula', 'Kilómetro Cero', '4:40', 'miss'],
      ['Marea Alta', 'Los Faroles', 'Costa Norte', '3:41', 'ok']
    ])
  },
  {
    id: 'rock', name: 'Rock de los 80', total: 92, duration: '6 h 05 min', lastSync: 'ayer',
    artwork: playlistArt.rock, heroPosition: 'center 30%', matched: 92, review: 0, missing: 0,
    synced: true, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Radio Pirata', 'Los Voltios', 'Interferencia', '4:12', 'ok'],
      ['Noche Eléctrica', 'Cromo', 'Alto Voltaje', '3:55', 'ok'],
      ['Ciudad de Neón', 'Los Voltios', 'Interferencia', '4:30', 'ok'],
      ['Vértigo', 'Sombra Azul', 'Vértigo', '3:48', 'ok'],
      ['Fin de Siglo', 'Cromo', 'Alto Voltaje', '5:01', 'ok'],
      ['Autopista', 'Sombra Azul', 'Vértigo', '3:36', 'ok']
    ])
  },
  {
    id: 'lofi', name: 'Lo-fi para estudiar', total: 140, duration: '5 h 36 min', lastSync: 'hace 5 días',
    artwork: playlistArt.lofi, heroPosition: 'center 55%', matched: 128, review: 9, missing: 3,
    synced: false, neverSynced: false, inDestination: true,
    tracks: tracks([
      ['Café a las 3', 'Pluma', 'Apuntes', '2:31', 'ok'],
      ['Lluvia en el Vidrio', 'Kai Ondo', 'Weather', '2:44', 'rev'],
      ['Biblioteca', 'Pluma', 'Apuntes', '2:18', 'ok'],
      ['Sobremesa', 'Tibio', 'Siesta', '2:52', 'rev'],
      ['Página 47', 'Tibio', 'Siesta', '2:09', 'miss'],
      ['Último Tren', 'Kai Ondo', 'Weather', '3:05', 'ok']
    ])
  },
  {
    id: 'ruta', name: 'Ruta y mate', total: 54, duration: '3 h 21 min', lastSync: 'nunca',
    artwork: playlistArt.ruta, heroPosition: 'center 60%', matched: 54, review: 0, missing: 0,
    synced: false, neverSynced: true, inDestination: false,
    tracks: tracks([
      ['Ruta 2', 'La Brújula', 'Kilómetro Cero', '4:22', 'ok'],
      ['Antes del Final', 'La Brújula', 'Kilómetro Cero', '4:40', 'ok'],
      ['Mil Kilómetros', 'Julieta Brisa', 'Postales', '3:33', 'ok'],
      ['Autopista', 'Sombra Azul', 'Vértigo', '3:36', 'ok'],
      ['Sin Señal', 'Nube 9', 'Asfalto', '2:58', 'ok'],
      ['Marea Alta', 'Los Faroles', 'Costa Norte', '3:41', 'ok']
    ])
  },
  {
    id: 'domingo', name: 'Domingo lento', total: 38, duration: '2 h 24 min', lastSync: 'nunca',
    artwork: playlistArt.domingo, heroPosition: 'center 50%', matched: 38, review: 0, missing: 0,
    synced: false, neverSynced: true, inDestination: false,
    tracks: tracks([
      ['Sobremesa', 'Tibio', 'Siesta', '2:52', 'ok'],
      ['Café a las 3', 'Pluma', 'Apuntes', '2:31', 'ok'],
      ['Horizonte Lento', 'Atlas Quiet', 'Low Tide', '5:10', 'ok'],
      ['Paper Planes', 'Moss & Fern', 'Greenhouse', '3:44', 'ok'],
      ['Biblioteca', 'Pluma', 'Apuntes', '2:18', 'ok'],
      ['Static Rain', 'Kai Ondo', 'Weather', '3:27', 'ok']
    ])
  }
]

const A = albumArt

// A slice of the 72 songs waiting for a decision; the rest load on demand.
export const sampleReview: ReviewItem[] = [
  {
    id: 'luna', playlistId: 'noches', title: 'Bajo la Luna de Enero', artist: 'Julieta Brisa', album: 'Postales', duration: '4:05',
    artwork: A['Postales'], kind: 'rev',
    candidates: [
      { title: 'Bajo la Luna de Enero', album: 'Postales', duration: '4:05', artwork: A['Postales'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Bajo la Luna de Enero (Remasterizado)', album: 'Postales (Deluxe)', duration: '4:06', artwork: A['Postales'], reason: 'Otra edición · +1 s', tone: 'neutral' },
      { title: 'Bajo la Luna de Enero (En vivo)', album: 'En vivo en el Club', duration: '4:47', artwork: A['En vivo en el Club'], reason: 'Versión en vivo · +42 s', tone: 'warn' }
    ]
  },
  {
    id: 'verano', playlistId: 'noches', title: 'Verano Eterno (Remix)', artist: 'Dúo Arrecife', album: 'Verano Eterno', duration: '3:58',
    artwork: A['Verano Eterno'], kind: 'rev',
    candidates: [
      { title: 'Verano Eterno (Remix)', album: 'Verano Eterno (Remixes)', duration: '3:58', artwork: A['Verano Eterno'], reason: 'Misma duración, otro álbum', tone: 'ok' },
      { title: 'Verano Eterno', album: 'Verano Eterno', duration: '3:21', artwork: A['Verano Eterno'], reason: 'Versión original · −37 s', tone: 'warn' }
    ]
  },
  {
    id: 'polaroid', playlistId: 'noches', title: 'Polaroid', artist: 'Camila Ferro', album: 'Revelado', duration: '2:57',
    artwork: A['Revelado'], kind: 'miss', candidates: []
  },
  {
    id: 'lunes', playlistId: 'indie', title: 'Lunes', artist: 'Las Moscas Azules', album: 'Semana', duration: '2:49',
    artwork: A['Semana'], kind: 'rev',
    candidates: [
      { title: 'Lunes', album: 'Semana', duration: '2:49', artwork: A['Semana'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Lunes (Versión acústica)', album: 'Semana (Sesiones)', duration: '3:10', artwork: A['Semana'], reason: 'Versión acústica · +21 s', tone: 'warn' }
    ]
  },
  {
    id: 'neon', playlistId: 'indie', title: 'Neón', artist: 'Bruma', album: 'Ciudad Dormida', duration: '3:19',
    artwork: A['Ciudad Dormida'], kind: 'rev',
    candidates: [
      { title: 'Neón', album: 'Ciudad Dormida', duration: '3:19', artwork: A['Ciudad Dormida'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Neón', album: 'Neón (Single)', duration: '3:19', artwork: A['Ciudad Dormida'], reason: 'Sencillo previo · misma duración', tone: 'neutral' }
    ]
  },
  {
    id: 'avenida', playlistId: 'indie', title: 'Avenida', artist: 'Teo Salinas', album: 'Avenida', duration: '3:02',
    artwork: A['Avenida'], kind: 'miss', candidates: []
  },
  {
    id: 'lluvia', playlistId: 'lofi', title: 'Lluvia en el Vidrio', artist: 'Kai Ondo', album: 'Weather', duration: '2:44',
    artwork: A['Weather'], kind: 'rev',
    candidates: [
      { title: 'Lluvia en el Vidrio', album: 'Weather', duration: '2:44', artwork: A['Weather'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Lluvia en el Vidrio (Extendida)', album: 'Weather', duration: '5:12', artwork: A['Weather'], reason: 'Versión extendida · +2 min 28 s', tone: 'warn' }
    ]
  },
  {
    id: 'sobremesa', playlistId: 'lofi', title: 'Sobremesa', artist: 'Tibio', album: 'Siesta', duration: '2:52',
    artwork: A['Siesta'], kind: 'rev',
    candidates: [
      { title: 'Sobremesa', album: 'Siesta', duration: '2:52', artwork: A['Siesta'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Sobremesa', album: 'Lo-fi para la tarde', duration: '2:52', artwork: A['Siesta'], reason: 'Recopilatorio · misma duración', tone: 'neutral' }
    ]
  },
  {
    id: 'fuego', playlistId: 'liked', title: 'Fuego Lento', artist: 'Dúo Arrecife', album: 'Verano Eterno', duration: '3:25',
    artwork: A['Verano Eterno'], kind: 'rev',
    candidates: [
      { title: 'Fuego Lento', album: 'Verano Eterno', duration: '3:25', artwork: A['Verano Eterno'], reason: 'Mismo álbum y duración', tone: 'ok' },
      { title: 'Fuego Lento (feat. Nube 9)', album: 'Fuego Lento (Single)', duration: '3:31', artwork: A['Asfalto'], reason: 'Otra versión con invitado · +6 s', tone: 'warn' }
    ]
  }
]

export const sampleRuns: Run[] = [
  {
    id: 'r2', when: 'Hoy, 19:12', playlistId: 'focus', direction: 's2a', result: '120 de 120', status: 'ok', label: 'Completada', duration: '1 min 12 s', review: 0,
    steps: [['ok', 'Leímos 120 canciones de Spotify.'], ['ok', '120 coincidencias exactas.'], ['ok', 'Playlist actualizada en Apple Music: 3 agregadas y 1 quitada.']]
  },
  {
    id: 'r3', when: 'Ayer, 22:00', playlistId: 'rock', direction: 's2a', result: '92 de 92', status: 'ok', label: 'Sin cambios', duration: '18 s', review: 0,
    steps: [['ok', 'Leímos 92 canciones de Spotify.'], ['neutral', 'No hubo cambios desde la última vez.']]
  },
  {
    id: 'r4', when: '20 oct, 22:00', playlistId: 'noches', direction: 's2a', result: '78 de 86', status: 'warn', label: 'Con avisos', duration: '52 s', review: 8,
    steps: [['ok', 'Leímos 86 canciones de Spotify.'], ['ok', '78 coincidencias exactas.'], ['warn', '6 dudosas, enviadas a Revisar.'], ['warn', '2 no están en Apple Music.'], ['ok', 'Playlist actualizada en Apple Music: 5 agregadas.']]
  },
  {
    id: 'r5', when: '18 oct, 22:00', playlistId: 'lofi', direction: 's2a', result: '128 de 140', status: 'warn', label: 'Con avisos', duration: '1 min 4 s', review: 12,
    steps: [['ok', 'Leímos 140 canciones de Spotify.'], ['ok', '128 coincidencias exactas.'], ['warn', '9 dudosas, enviadas a Revisar.'], ['warn', '3 no están en Apple Music.'], ['ok', 'Playlist creada en Apple Music.']]
  },
  {
    id: 'r6', when: '16 oct, 10:31', playlistId: 'indie', direction: 'a2s', result: '59 de 64', status: 'warn', label: 'Con avisos', duration: '38 s', review: 5,
    steps: [['ok', 'Leímos 64 canciones de Apple Music.'], ['ok', '59 coincidencias exactas.'], ['warn', '4 dudosas, enviadas a Revisar.'], ['warn', '1 no está en Spotify.'], ['ok', 'Playlist actualizada en Spotify: 2 agregadas.']]
  },
  {
    id: 'r7', when: '15 oct, 22:00', playlistId: 'liked', direction: 's2a', result: '0 de 1.248', status: 'fail', label: 'Falló', duration: '3 min', review: 0,
    steps: [['ok', 'Leímos 1.248 canciones de Spotify.'], ['fail', 'Apple Music no respondió. Reintentamos 3 veces.'], ['neutral', 'No se hizo ningún cambio en Apple Music.']]
  },
  {
    id: 'r8', when: '12 oct, 18:05', playlistId: 'focus', direction: 's2a', result: '117 de 117', status: 'ok', label: 'Completada', duration: '1 min 2 s', review: 0,
    steps: [['ok', 'Leímos 117 canciones de Spotify.'], ['ok', '117 coincidencias exactas.'], ['ok', 'Playlist creada en Apple Music.']]
  }
]

export const defaultSettings: Settings = {
  auto: true,
  frequency: 'daily',
  hour: '22:00',
  defaultDirection: 's2a',
  ifExists: 'update',
  precision: 'balanced',
  preferStudio: true,
  autoRemaster: true,
  tolerance: 3,
  notifyDone: true,
  notifyReview: true,
  notifyFail: true
}

export function createInitialState(): AppState {
  return {
    onboarded: false,
    accounts: {
      spotify: { connected: true, user: '[tu usuario de Spotify]', playlists: 42 },
      apple: { status: 'disconnected', user: '[tu Apple ID]', playlists: 38 }
    },
    playlists: samplePlaylists,
    job: { playlistId: 'liked', direction: 's2a', done: 612, total: 1248, state: 'running' },
    queue: [],
    review: sampleReview,
    resolutions: {},
    runs: sampleRuns,
    undoneRuns: {},
    settings: defaultSettings
  }
}
