export type ServiceId = 'spotify' | 'apple'

/** s2a: Spotify → Apple Music, a2s: Apple Music → Spotify, both: keep both equal. */
export type Direction = 's2a' | 'a2s' | 'both'

export type TrackStatus = 'ok' | 'rev' | 'miss'

export interface Track {
  title: string
  artist: string
  album: string
  duration: string
  status: TrackStatus
}

export interface Playlist {
  id: string
  name: string
  total: number
  duration: string
  lastSync: string
  artwork: string
  heroPosition: string
  matched: number
  review: number
  missing: number
  synced: boolean
  neverSynced: boolean
  inDestination: boolean
  tracks: Track[]
}

export type CandidateTone = 'ok' | 'neutral' | 'warn'

export interface Candidate {
  title: string
  album: string
  duration: string
  artwork: string
  reason: string
  tone: CandidateTone
}

export interface ReviewItem {
  id: string
  playlistId: string
  title: string
  artist: string
  album: string
  duration: string
  artwork: string
  kind: 'rev' | 'miss'
  candidates: Candidate[]
}

export type Resolution = { kind: 'used'; candidate: number } | { kind: 'skipped' }

export type RunStatus = 'ok' | 'warn' | 'fail'
export type StepKind = 'ok' | 'warn' | 'fail' | 'run' | 'neutral'

export interface Run {
  id: string
  when: string
  playlistId: string
  direction: Exclude<Direction, 'both'>
  result: string
  status: RunStatus
  label: string
  duration: string
  review: number
  steps: Array<[StepKind, string]>
}

export interface SyncJob {
  playlistId: string
  direction: Direction
  done: number
  total: number
  state: 'running' | 'paused' | 'done'
}

export interface QueuedSync {
  playlistId: string
  direction: Direction
}

export interface Settings {
  auto: boolean
  frequency: 'hourly' | 'daily' | 'weekly'
  hour: string
  defaultDirection: Direction
  ifExists: 'update' | 'copy'
  precision: 'strict' | 'balanced' | 'flexible'
  preferStudio: boolean
  autoRemaster: boolean
  tolerance: number
  notifyDone: boolean
  notifyReview: boolean
  notifyFail: boolean
}

export interface Accounts {
  spotify: { connected: boolean; user: string; playlists: number }
  apple: { status: 'disconnected' | 'connecting' | 'connected'; user: string; playlists: number }
}

export interface AppState {
  onboarded: boolean
  accounts: Accounts
  playlists: Playlist[]
  job: SyncJob | null
  queue: QueuedSync[]
  review: ReviewItem[]
  resolutions: Record<string, Resolution>
  runs: Run[]
  undoneRuns: Record<string, true>
  settings: Settings
}
