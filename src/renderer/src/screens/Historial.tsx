import { useState } from 'react'
import { AppShell, PanelScroll } from '../components/shell/AppShell'
import { Icon, type IconName } from '../components/Icon'
import { Badge, Button, buttonClass, ChipGroup, Cover, ui } from '../components/ui'
import { directionLabel, fmt, serviceName } from '../lib/format'
import { Link } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import { jobPercent, playlistById } from '../store/selectors'
import type { Direction, Run, RunStatus, StepKind } from '../store/types'
import s from './Historial.module.css'

type Filter = 'all' | RunStatus

const FILTERS: Array<{ id: Filter; label: string }> = [
  { id: 'all', label: 'Todas' },
  { id: 'ok', label: 'Completadas' },
  { id: 'warn', label: 'Con avisos' },
  { id: 'fail', label: 'Fallidas' }
]

const STEP_STYLE: Record<StepKind, { icon: IconName; bg: string; color: string; spin?: boolean }> = {
  ok: { icon: 'check', bg: 'var(--accent-tint)', color: 'var(--accent)' },
  warn: { icon: 'alert', bg: 'rgba(255,169,77,0.18)', color: 'var(--review)' },
  fail: { icon: 'x', bg: 'rgba(255,107,107,0.18)', color: 'var(--danger)' },
  run: { icon: 'spinner', bg: 'var(--raised)', color: 'var(--accent)', spin: true },
  neutral: { icon: 'minus', bg: 'var(--raised)', color: 'var(--missing)' }
}

// The sync in progress shows up as the first row, built from the live job.
const LIVE_ID = 'live'

interface Row {
  id: string
  when: string
  playlistId: string
  direction: string
  syncDirection: Direction
  result: string
  tone: 'ok' | 'warn' | 'fail' | 'neutral'
  label: string
  durationLabel: string
  steps: Array<[StepKind, string]>
  review: number
  undoable: boolean
  retry: boolean
  toName: string
  status: RunStatus | 'running'
}

export function Historial() {
  const state = useAppState()
  const dispatch = useDispatch()
  const [filter, setFilter] = useState<Filter>('all')
  const [selectedId, setSelectedId] = useState<string>('r4')

  const rows: Row[] = []
  const job = state.job
  if (job && job.state !== 'done') {
    const pct = jobPercent(state)
    const toName = job.direction === 'a2s' ? 'Spotify' : 'Apple Music'
    rows.push({
      id: LIVE_ID,
      when: 'Ahora',
      playlistId: job.playlistId,
      direction: directionLabel(job.direction),
      syncDirection: job.direction,
      result: `${fmt(job.done)} de ${fmt(job.total)}`,
      tone: 'neutral',
      label: job.state === 'running' ? `En curso · ${pct} %` : `En pausa · ${pct} %`,
      durationLabel: 'en curso',
      steps: [
        ['ok', `Leímos ${fmt(job.total)} canciones de ${job.direction === 'a2s' ? 'Apple Music' : 'Spotify'}.`],
        [job.state === 'running' ? 'run' : 'neutral', `Copiando a ${toName} · ${pct} %.`]
      ],
      review: 0,
      undoable: false,
      retry: false,
      toName,
      status: 'running'
    })
  }
  for (const run of state.runs) {
    const undone = !!state.undoneRuns[run.id]
    rows.push(toRow(run, undone))
  }

  const visible = rows.filter((r) => filter === 'all' || r.status === filter)
  const current = rows.find((r) => r.id === selectedId) ?? rows[0]
  const currentPlaylist = current ? playlistById(state, current.playlistId) : undefined

  return (
    <AppShell>
      <PanelScroll>
        <div className={s.page}>
          <div className={s.head}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <h1 className={ui.pageTitle}>Historial</h1>
              <p className={ui.muted}>Podés deshacer cualquier sincronización de los últimos 30 días.</p>
            </div>
            <Button variant="secondary" icon="download">
              Exportar CSV
            </Button>
          </div>

          <ChipGroup label="Filtrar por estado" options={FILTERS} value={filter} onChange={setFilter} />

          <div className={s.layout}>
            <div className={s.tableArea}>
              <div className="scroll" style={{ overflowX: 'auto' }}>
                <div className={s.table}>
                  <div className={s.headRow}>
                    <span>Fecha</span>
                    <span>Playlist</span>
                    <span>Canciones</span>
                    <span>Estado</span>
                  </div>
                  <ul className={s.rows}>
                    {visible.map((r) => {
                      const playlist = playlistById(state, r.playlistId)
                      return (
                        <li key={r.id}>
                          <button type="button" className={s.row} aria-current={r.id === current?.id} onClick={() => setSelectedId(r.id)}>
                            <span className={s.when}>{r.when}</span>
                            <span className={s.plCell}>
                              {playlist && <Cover src={playlist.artwork} size={44} radius={6} />}
                              <span style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
                                <span style={{ fontSize: 15, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                  {playlist?.name}
                                </span>
                                <span className={ui.muted} style={{ fontSize: 13 }}>
                                  {r.direction}
                                </span>
                              </span>
                            </span>
                            <span className={s.when}>{r.result}</span>
                            <span>
                              <Badge tone={r.tone}>{r.label}</Badge>
                            </span>
                          </button>
                        </li>
                      )
                    })}
                  </ul>
                  {visible.length === 0 && (
                    <p className={ui.muted} style={{ margin: '20px 12px' }}>
                      No hay sincronizaciones con este estado.
                    </p>
                  )}
                </div>
              </div>
            </div>

            {current && currentPlaylist && (
              <aside aria-label="Detalle de la sincronización" className={s.detail}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                  <Cover src={currentPlaylist.artwork} size={64} />
                  <span style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
                    <span style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.02em' }}>{currentPlaylist.name}</span>
                    <span className={ui.muted} style={{ fontSize: 13 }}>
                      {current.when} · {current.durationLabel}
                    </span>
                  </span>
                </div>
                <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}>
                  <Badge tone={current.tone}>{current.label}</Badge>
                  <span style={{ fontSize: 13, color: 'var(--text-2)' }}>{current.direction}</span>
                </div>
                <ol className={s.steps}>
                  {current.steps.map(([kind, text]) => {
                    const st = STEP_STYLE[kind]
                    return (
                      <li key={text} className={s.step}>
                        <span aria-hidden="true" className={s.stepDot} style={{ background: st.bg, color: st.color }}>
                          <Icon name={st.icon} size={12} strokeWidth={3.4} className={st.spin ? 'spin' : undefined} />
                        </span>
                        {text}
                      </li>
                    )
                  })}
                </ol>
                <div className={s.detailActions}>
                  {current.review > 0 && (
                    <Link to={{ name: 'revisar' }} className={buttonClass('primary', 'md', false, true)}>
                      Revisar {current.review} canciones
                    </Link>
                  )}
                  {current.retry && (
                    <Button
                      variant="primary"
                      icon="sync"
                      block
                      onClick={() => dispatch({ type: 'sync/start', playlistIds: [current.playlistId], direction: current.syncDirection })}
                    >
                      Reintentar ahora
                    </Button>
                  )}
                  <Link to={{ name: 'playlist', id: current.playlistId }} className={buttonClass('secondary', 'md', false, true)}>
                    Abrir playlist
                  </Link>
                  {current.undoable && (
                    <Button variant="danger" icon="undo" block onClick={() => dispatch({ type: 'run/undo', id: current.id })}>
                      Deshacer esta sincronización
                    </Button>
                  )}
                  {state.undoneRuns[current.id] && (
                    <p style={{ fontSize: 14, lineHeight: 1.45, color: 'var(--text-2)' }}>
                      La playlist en {current.toName} volvió a como estaba antes de esta sincronización.
                    </p>
                  )}
                </div>
              </aside>
            )}
          </div>
        </div>
      </PanelScroll>
    </AppShell>
  )
}

function toRow(run: Run, undone: boolean): Row {
  const toName = serviceName(run.direction === 'a2s' ? 'spotify' : 'apple')
  return {
    id: run.id,
    when: run.when,
    playlistId: run.playlistId,
    direction: directionLabel(run.direction),
    syncDirection: run.direction,
    result: run.result,
    tone: undone ? 'neutral' : run.status,
    label: undone ? 'Deshecha' : run.label,
    durationLabel: `duró ${run.duration}`,
    steps: run.steps,
    review: undone ? 0 : run.review,
    undoable: !undone && run.status !== 'fail' && run.label !== 'Sin cambios',
    retry: run.status === 'fail',
    toName,
    status: run.status
  }
}
