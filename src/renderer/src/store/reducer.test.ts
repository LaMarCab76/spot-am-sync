import { describe, expect, it } from 'vitest'
import { createInitialState } from '../data/mock'
import { reducer, tickStep } from './reducer'
import { pendingTotal, playlistCounts, playlistStatus, reviewTotals, trackState } from './selectors'
import type { AppState } from './types'

const now = new Date('2026-10-23T21:40:00')

function tickWhile(state: AppState, keepGoing: (s: AppState) => boolean): AppState {
  let s = state
  for (let i = 0; i < 10_000 && keepGoing(s); i++) {
    s = reducer(s, { type: 'sync/tick', now })
  }
  return s
}

const runToCompletion = (state: AppState) => tickWhile(state, (s) => s.job?.state === 'running')

describe('sample data', () => {
  it('adds up to the 72 songs shown in Revisar', () => {
    const state = createInitialState()
    expect(pendingTotal(state)).toBe(72)
    expect(reviewTotals(state)).toEqual({ all: 72, rev: 50, miss: 22 })
  })
})

describe('sync jobs', () => {
  it('advances by a fixed share of the playlist per tick', () => {
    const state = createInitialState()
    const next = reducer(state, { type: 'sync/tick', now })
    expect(next.job?.done).toBe(612 + tickStep(1248))
  })

  it('does not advance while paused', () => {
    const paused = reducer(createInitialState(), { type: 'sync/toggle' })
    expect(paused.job?.state).toBe('paused')
    expect(reducer(paused, { type: 'sync/tick', now })).toBe(paused)
  })

  it('queues new playlists while another one is syncing and runs them in order', () => {
    let state = reducer(createInitialState(), { type: 'sync/start', playlistIds: ['noches', 'lofi'], direction: 's2a' })
    expect(state.job?.playlistId).toBe('liked')
    expect(state.queue.map((q) => q.playlistId)).toEqual(['noches', 'lofi'])

    state = tickWhile(state, (s) => s.job?.playlistId === 'liked')
    expect(state.job).toMatchObject({ playlistId: 'noches', done: 0, state: 'running' })
    expect(state.queue.map((q) => q.playlistId)).toEqual(['lofi'])
    expect(state.runs[0].playlistId).toBe('liked')
  })

  it('records a run and marks the playlist as synced when it finishes', () => {
    const start = reducer({ ...createInitialState(), job: null }, { type: 'sync/start', playlistIds: ['ruta'], direction: 's2a' })
    expect(playlistStatus(start, start.playlists.find((p) => p.id === 'ruta')!)).toBe('syncing')

    const done = runToCompletion(start)
    const ruta = done.playlists.find((p) => p.id === 'ruta')!
    expect(done.job?.state).toBe('done')
    expect(ruta.neverSynced).toBe(false)
    expect(ruta.inDestination).toBe(true)
    expect(playlistStatus(done, ruta)).toBe('synced')
    expect(done.runs[0]).toMatchObject({ playlistId: 'ruta', status: 'ok', label: 'Completada', when: 'Hoy, 21:40' })
  })

  it('restarts a finished job when toggled again', () => {
    const done = runToCompletion(createInitialState())
    const again = reducer(done, { type: 'sync/toggle' })
    expect(again.job).toMatchObject({ playlistId: 'liked', done: 0, state: 'running' })
  })

  it('ignores playlists that do not exist', () => {
    const state = createInitialState()
    expect(reducer(state, { type: 'sync/start', playlistIds: ['nope'], direction: 's2a' })).toBe(state)
  })
})

describe('review', () => {
  it('lowers the pending count of the playlist and the total when a song is resolved', () => {
    const state = createInitialState()
    const noches = state.playlists.find((p) => p.id === 'noches')!
    const used = reducer(state, { type: 'review/resolve', id: 'luna', resolution: { kind: 'used', candidate: 0 } })
    const skipped = reducer(used, { type: 'review/resolve', id: 'polaroid', resolution: { kind: 'skipped' } })

    expect(playlistCounts(skipped, noches)).toEqual({ matched: 79, review: 5, missing: 1, skipped: 1, pending: 6 })
    expect(pendingTotal(skipped)).toBe(70)

    const undone = reducer(skipped, { type: 'review/undo', id: 'luna' })
    expect(pendingTotal(undone)).toBe(71)
  })

  it('shows resolved songs in the playlist with their decision', () => {
    const state = createInitialState()
    const noches = state.playlists.find((p) => p.id === 'noches')!
    const track = (title: string) => noches.tracks.find((t) => t.title === title)!
    const used = reducer(state, { type: 'review/resolve', id: 'luna', resolution: { kind: 'used', candidate: 0 } })
    const skipped = reducer(used, { type: 'review/resolve', id: 'polaroid', resolution: { kind: 'skipped' } })

    expect(trackState(skipped, noches, track('Bajo la Luna de Enero'))).toBe('ok')
    expect(trackState(skipped, noches, track('Polaroid'))).toBe('skipped')
    expect(trackState(skipped, noches, track('Verano Eterno (Remix)'))).toBe('rev')
    expect(trackState(skipped, noches, track('Marea Alta'))).toBe('ok')
  })

  it('records a new sync with the decisions already made', () => {
    const start = { ...createInitialState(), job: null }
    const resolved = reducer(start, { type: 'review/resolve', id: 'luna', resolution: { kind: 'used', candidate: 0 } })
    const done = runToCompletion(reducer(resolved, { type: 'sync/start', playlistIds: ['noches'], direction: 's2a' }))

    expect(done.runs[0]).toMatchObject({ playlistId: 'noches', result: '79 de 86', review: 7, status: 'warn' })
    expect(done.runs[0].steps).toContainEqual(['ok', '1 con la versión que elegiste en Revisar.'])
    expect(done.runs[0].steps).toContainEqual(['warn', '5 dudosas, enviadas a Revisar.'])
  })
})

describe('accounts and settings', () => {
  it('connects Apple Music in two steps', () => {
    const connecting = reducer(createInitialState(), { type: 'apple/connect-start' })
    expect(connecting.accounts.apple.status).toBe('connecting')
    expect(reducer(connecting, { type: 'apple/connect-done' }).accounts.apple.status).toBe('connected')
  })

  it('merges settings patches', () => {
    const state = reducer(createInitialState(), { type: 'settings/update', patch: { tolerance: 5, auto: false } })
    expect(state.settings).toMatchObject({ tolerance: 5, auto: false, hour: '22:00' })
  })

  it('marks runs as undone', () => {
    const state = reducer(createInitialState(), { type: 'run/undo', id: 'r4' })
    expect(state.undoneRuns).toEqual({ r4: true })
  })
})
