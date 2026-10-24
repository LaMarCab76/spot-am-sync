import { clockTime, directionEnds, fmt, serviceName } from '../lib/format'
import { playlistCounts, type PlaylistCounts } from './selectors'
import type { AppState, Direction, Playlist, Resolution, Run, Settings, StepKind } from './types'

export type Action =
  | { type: 'apple/connect-start' }
  | { type: 'apple/connect-done' }
  | { type: 'account/disconnect'; service: 'spotify' | 'apple' }
  | { type: 'onboarding/complete' }
  | { type: 'sync/start'; playlistIds: string[]; direction: Direction }
  | { type: 'sync/toggle' }
  | { type: 'sync/tick'; now: Date }
  | { type: 'review/resolve'; id: string; resolution: Resolution }
  | { type: 'review/undo'; id: string }
  | { type: 'run/undo'; id: string }
  | { type: 'settings/update'; patch: Partial<Settings> }

/** Songs copied per tick; a whole playlist takes ~70 ticks regardless of size. */
export const tickStep = (total: number): number => Math.max(1, Math.round(total / 70))

function findPlaylist(state: AppState, id: string): Playlist | undefined {
  return state.playlists.find((p) => p.id === id)
}

function startJob(state: AppState, playlistId: string, direction: Direction): AppState {
  const playlist = findPlaylist(state, playlistId)
  if (!playlist) return state
  return { ...state, job: { playlistId, direction, done: 0, total: playlist.total, state: 'running' } }
}

/** Builds the history entry from the counts after the decisions made in Revisar. */
function finishedRun(playlist: Playlist, counts: PlaylistCounts, direction: Direction, now: Date): Run {
  const { pending } = counts
  const chosen = counts.matched - playlist.matched
  const { from, to } = directionEnds(direction)
  const steps: Array<[StepKind, string]> = [
    ['ok', `Leímos ${fmt(playlist.total)} canciones de ${serviceName(from)}.`],
    ['ok', `${fmt(playlist.matched)} coincidencias exactas.`]
  ]
  if (chosen > 0) steps.push(['ok', `${fmt(chosen)} con la versión que elegiste en Revisar.`])
  if (counts.skipped > 0) steps.push(['neutral', `${fmt(counts.skipped)} omitidas por vos.`])
  if (counts.review > 0) steps.push(['warn', `${fmt(counts.review)} dudosas, enviadas a Revisar.`])
  if (counts.missing > 0) steps.push(['warn', `${fmt(counts.missing)} no están en ${serviceName(to)}.`])
  steps.push(['ok', playlist.inDestination ? `Playlist actualizada en ${serviceName(to)}.` : `Playlist creada en ${serviceName(to)}.`])
  return {
    id: `run-${now.getTime()}-${playlist.id}`,
    when: `Hoy, ${clockTime(now)}`,
    playlistId: playlist.id,
    direction: direction === 'a2s' ? 'a2s' : 's2a',
    result: `${fmt(counts.matched)} de ${fmt(playlist.total)}`,
    status: pending > 0 ? 'warn' : 'ok',
    label: pending > 0 ? 'Con avisos' : 'Completada',
    duration: 'menos de 1 min',
    review: pending,
    steps
  }
}

export function reducer(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'apple/connect-start':
      return { ...state, accounts: { ...state.accounts, apple: { ...state.accounts.apple, status: 'connecting' } } }

    case 'apple/connect-done':
      return { ...state, accounts: { ...state.accounts, apple: { ...state.accounts.apple, status: 'connected' } } }

    case 'account/disconnect':
      if (action.service === 'spotify') {
        return { ...state, accounts: { ...state.accounts, spotify: { ...state.accounts.spotify, connected: false } } }
      }
      return { ...state, accounts: { ...state.accounts, apple: { ...state.accounts.apple, status: 'disconnected' } } }

    case 'onboarding/complete':
      return { ...state, onboarded: true }

    case 'sync/start': {
      const ids = action.playlistIds.filter((id) => findPlaylist(state, id))
      if (ids.length === 0) return state
      const busy = state.job !== null && state.job.state !== 'done'
      const queued = ids.map((playlistId) => ({ playlistId, direction: action.direction }))
      if (busy) {
        const current = state.job?.playlistId
        return { ...state, queue: [...state.queue, ...queued.filter((q) => q.playlistId !== current)] }
      }
      const [first, ...rest] = queued
      return { ...startJob(state, first.playlistId, first.direction), queue: [...state.queue, ...rest] }
    }

    case 'sync/toggle': {
      const job = state.job
      if (!job) return state
      if (job.state === 'done') return startJob(state, job.playlistId, job.direction)
      return { ...state, job: { ...job, state: job.state === 'running' ? 'paused' : 'running' } }
    }

    case 'sync/tick': {
      const job = state.job
      if (!job || job.state !== 'running') return state
      const done = Math.min(job.total, job.done + tickStep(job.total))
      if (done < job.total) return { ...state, job: { ...job, done } }

      const playlist = findPlaylist(state, job.playlistId)
      const playlists = state.playlists.map((p) =>
        p.id === job.playlistId ? { ...p, synced: true, neverSynced: false, inDestination: true, lastSync: 'ahora' } : p
      )
      const runs = playlist
        ? [finishedRun(playlist, playlistCounts(state, playlist), job.direction, action.now), ...state.runs]
        : state.runs
      const next: AppState = { ...state, playlists, runs, job: { ...job, done, state: 'done' } }
      const [queued, ...queue] = state.queue
      return queued ? { ...startJob(next, queued.playlistId, queued.direction), queue } : next
    }

    case 'review/resolve':
      return { ...state, resolutions: { ...state.resolutions, [action.id]: action.resolution } }

    case 'review/undo': {
      const resolutions = { ...state.resolutions }
      delete resolutions[action.id]
      return { ...state, resolutions }
    }

    case 'run/undo':
      return { ...state, undoneRuns: { ...state.undoneRuns, [action.id]: true } }

    case 'settings/update':
      return { ...state, settings: { ...state.settings, ...action.patch } }
  }
}
