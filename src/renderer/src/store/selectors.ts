import type { AppState, Playlist } from './types'

export type PlaylistStatus = 'syncing' | 'paused' | 'synced' | 'pending' | 'never'

export interface PlaylistCounts {
  matched: number
  review: number
  missing: number
  pending: number
}

/** Counts after subtracting the songs already decided in Revisar. */
export function playlistCounts(state: AppState, playlist: Playlist): PlaylistCounts {
  let review = playlist.review
  let missing = playlist.missing
  for (const item of state.review) {
    if (item.playlistId !== playlist.id || !state.resolutions[item.id]) continue
    if (item.kind === 'rev') review -= 1
    else missing -= 1
  }
  review = Math.max(0, review)
  missing = Math.max(0, missing)
  return { matched: playlist.total - review - missing, review, missing, pending: review + missing }
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
