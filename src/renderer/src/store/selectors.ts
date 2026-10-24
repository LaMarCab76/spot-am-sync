import type { AppState, Playlist, Track, TrackStatus } from './types'

export type PlaylistStatus = 'syncing' | 'paused' | 'synced' | 'pending' | 'never'

export interface PlaylistCounts {
  matched: number
  review: number
  missing: number
  /** Songs the user chose to leave out in Revisar; they are neither matched nor pending. */
  skipped: number
  pending: number
}

/** Counts after applying the decisions already made in Revisar. */
export function playlistCounts(state: AppState, playlist: Playlist): PlaylistCounts {
  let review = playlist.review
  let missing = playlist.missing
  let skipped = 0
  for (const item of state.review) {
    const resolution = item.playlistId === playlist.id ? state.resolutions[item.id] : undefined
    if (!resolution) continue
    if (item.kind === 'rev') review -= 1
    else missing -= 1
    if (resolution.kind === 'skipped') skipped += 1
  }
  review = Math.max(0, review)
  missing = Math.max(0, missing)
  return { matched: playlist.total - review - missing - skipped, review, missing, skipped, pending: review + missing }
}

export type TrackState = TrackStatus | 'skipped'

/** A track's status once its Revisar decision, if any, is applied. */
export function trackState(state: AppState, playlist: Playlist, track: Track): TrackState {
  if (track.status === 'ok') return 'ok'
  const item = state.review.find((r) => r.playlistId === playlist.id && r.title === track.title && r.artist === track.artist)
  const resolution = item ? state.resolutions[item.id] : undefined
  if (!resolution) return track.status
  return resolution.kind === 'used' ? 'ok' : 'skipped'
}

export function pendingTotal(state: AppState): number {
  return state.playlists.reduce((sum, p) => sum + playlistCounts(state, p).pending, 0)
}

export function reviewTotals(state: AppState): { all: number; rev: number; miss: number } {
  let rev = 0
  let miss = 0
  for (const p of state.playlists) {
    const c = playlistCounts(state, p)
    rev += c.review
    miss += c.missing
  }
  return { all: rev + miss, rev, miss }
}

export function playlistStatus(state: AppState, playlist: Playlist): PlaylistStatus {
  const job = state.job
  if (job && job.playlistId === playlist.id && job.state !== 'done') return job.state === 'running' ? 'syncing' : 'paused'
  if (playlist.neverSynced) return 'never'
  return playlistCounts(state, playlist).pending === 0 ? 'synced' : 'pending'
}

export function jobPercent(state: AppState): number {
  const job = state.job
  if (!job || job.total === 0) return 0
  return Math.round((job.done / job.total) * 100)
}

export function playlistById(state: AppState, id: string): Playlist | undefined {
  return state.playlists.find((p) => p.id === id)
}
