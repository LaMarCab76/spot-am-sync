import { useState } from 'react'
import { AppShell, PanelScroll } from '../components/shell/AppShell'
import { Icon } from '../components/Icon'
import { Button, Cover, Dot, IconButton, ServiceDot, SwitchVisual, ui } from '../components/ui'
import { albumArt } from '../data/artwork'
import { directionEnds, fmt, serviceName } from '../lib/format'
import { Link } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import { playlistById, playlistCounts } from '../store/selectors'
import type { Direction, TrackStatus } from '../store/types'
import s from './Playlist.module.css'

type Filter = 'all' | TrackStatus

export function Playlist({ id }: { id: string }) {
  const state = useAppState()
  const dispatch = useDispatch()
  const [filter, setFilter] = useState<Filter>('all')
  const [direction, setDirection] = useState<Exclude<Direction, 'both'>>(state.settings.defaultDirection === 'a2s' ? 'a2s' : 's2a')
  const playlist = playlistById(state, id) ?? state.playlists[0]
  const counts = playlistCounts(state, playlist)
  const { from, to } = directionEnds(direction)
  const toName = serviceName(to)

  const job = state.job
  const isJob = job !== null && job.playlistId === playlist.id && job.state !== 'done'
  const running = isJob && job.state === 'running'
  const queued = state.queue.some((q) => q.playlistId === playlist.id)

  const onSync = () => {
    if (isJob) dispatch({ type: 'sync/toggle' })
    else dispatch({ type: 'sync/start', playlistIds: [playlist.id], direction })
  }
  const syncLabel = running ? 'Pausar' : isJob ? 'Reanudar' : queued ? 'En cola' : 'Sincronizar ahora'

  const tiles: Array<{ id: Filter; label: string; count: number; color: string }> = [
    { id: 'all', label: 'Todas', count: playlist.total, color: '#6e6e76' },
    { id: 'ok', label: 'Coinciden', count: counts.matched, color: 'var(--accent)' },
    { id: 'rev', label: 'Revisar', count: counts.review, color: 'var(--review-dot)' },
    { id: 'miss', label: 'No encontradas', count: counts.missing, color: '#a1a1aa' }
  ]

  const tracks = playlist.tracks.map((t, i) => ({ ...t, n: i + 1 })).filter((t) => filter === 'all' || t.status === filter)
  const lastSync = playlist.neverSynced ? 'Nunca sincronizada' : `Última sync: ${playlist.lastSync}`

  return (
    <AppShell>
      <PanelScroll>
        <section aria-labelledby="pl-title" className={s.hero}>
          <img src={playlist.artwork} alt="" className={s.heroImage} style={{ objectPosition: playlist.heroPosition }} />
          <div aria-hidden="true" className={s.heroScrim} />
          <div className={s.heroControls}>
            <div className={`${s.glassGroup} ${ui.glass}`}>
              <IconButton icon="chevronLeft" label="Atrás" onClick={() => window.history.back()} />
              <IconButton icon="chevronRight" label="Adelante" onClick={() => window.history.forward()} />
            </div>
            <div className={`${s.glassGroup} ${ui.glass}`}>
              <IconButton icon="share" label="Compartir" />
              <IconButton icon="more" label="Más opciones" />
            </div>
          </div>
          <div className={s.heroText}>
            <h1 id="pl-title" className={s.title}>
              {playlist.name}
            </h1>
            <span className={s.subtitle}>Playlist de {serviceName(from)}</span>
            <span className={s.meta}>
              {fmt(playlist.total)} canciones · {playlist.duration} · {lastSync}
            </span>
          </div>
        </section>

        <div className={s.actions}>
          <Button variant="primary" size="lg" icon={running ? 'pause' : 'sync'} onClick={onSync} disabled={queued && !isJob}>
            {syncLabel}
          </Button>

          <div className={s.direction}>
            <span className={s.directionEnd}>
              <ServiceDot service={from} />
              {serviceName(from)}
            </span>
            <IconButton icon="swap" label="Invertir dirección" onClick={() => setDirection(direction === 's2a' ? 'a2s' : 's2a')} />
            <span className={s.directionEnd}>
              <ServiceDot service={to} />
              {toName}
            </span>
          </div>

          <button
            type="button"
            role="switch"
            aria-checked={state.settings.auto}
            className={s.autoToggle}
            onClick={() => dispatch({ type: 'settings/update', patch: { auto: !state.settings.auto } })}
          >
            <span>Sync automática</span>
            <SwitchVisual on={state.settings.auto} />
          </button>
        </div>

        <div className={s.summary}>
          {playlist.neverSynced ? (
            <p className={s.notice}>
              <Icon name="alert" />
              Todavía no se sincronizó. Sincronizala para ver qué canciones encontramos en {toName}.
            </p>
          ) : (
            <>
              <p className={ui.muted} style={{ fontSize: 14 }}>
                Las canciones dudosas quedan en Revisar hasta que elijas la versión correcta en {toName}.
              </p>
              <div role="group" aria-label="Filtrar canciones por estado" className={s.tiles}>
                {tiles.map((t) => (
                  <button key={t.id} type="button" className={s.tile} aria-pressed={filter === t.id} onClick={() => setFilter(t.id)}>
                    <span className={s.tileLabel}>
                      <Dot color={t.color} />
                      {t.label}
                    </span>
                    <span className={s.tileCount}>{fmt(t.count)}</span>
                    <span aria-hidden="true" className={s.tileBar}>
                      <span style={{ width: `${t.count === 0 ? 0 : Math.max(2, Math.round((t.count / playlist.total) * 100))}%`, background: t.color }} />
                    </span>
                  </button>
                ))}
              </div>
            </>
          )}
        </div>

        <div className={s.tableWrap}>
          <div className="scroll" style={{ overflowX: 'auto' }}>
            <div className={s.table}>
              <div className={s.headRow}>
                <span style={{ textAlign: 'right' }}>#</span>
                <span>Título</span>
                <span>Álbum</span>
                <span>En {toName}</span>
                <span style={{ display: 'flex', justifyContent: 'flex-end' }}>
                  <Icon name="clock" size={16} label="Duración" />
                </span>
              </div>
              <ol className={s.rows}>
                {tracks.map((t) => (
                  <li key={t.n} className={s.row}>
                    <span className={s.num}>{t.n}</span>
                    <span className={s.trackCell}>
                      <Cover src={albumArt[t.album]} size={44} radius={6} />
                      <span className={s.trackText}>
                        <span className={s.ellipsis} style={{ fontSize: 15, fontWeight: 500 }}>
                          {t.title}
                        </span>
                        <span className={`${s.ellipsis} ${ui.muted}`} style={{ fontSize: 14 }}>
                          {t.artist}
                        </span>
                      </span>
                    </span>
                    <span className={`${s.ellipsis} ${ui.muted}`} style={{ fontSize: 14 }}>
                      {t.album}
                    </span>
                    <span>
                      {playlist.neverSynced ? (
                        <span className={ui.muted} style={{ fontSize: 14 }}>
                          Sin comparar
                        </span>
                      ) : t.status === 'ok' ? (
                        <span className={ui.statusOk}>
                          <Icon name="checkCircle" size={18} strokeWidth={2.4} />
                          Coincide
                        </span>
                      ) : t.status === 'rev' ? (
                        <Link to={{ name: 'revisar' }} className={`${ui.statusPill} ${ui.statusRev}`} aria-label={`Revisar coincidencia de ${t.title}`}>
                          <Icon name="alert" size={18} strokeWidth={2.4} />
                          Revisar
                        </Link>
                      ) : (
                        <Link to={{ name: 'revisar' }} className={`${ui.statusPill} ${ui.statusMiss}`} aria-label={`${t.title} no está en ${toName}: buscar manualmente`}>
                          <Icon name="xCircle" size={18} strokeWidth={2.4} />
                          No encontrada
                        </Link>
                      )}
                    </span>
                    <span className={ui.muted} style={{ textAlign: 'right', fontSize: 14, fontVariantNumeric: 'tabular-nums' }}>
                      {t.duration}
                    </span>
                  </li>
                ))}
              </ol>
              {tracks.length === 0 && (
                <p className={ui.muted} style={{ margin: '24px 12px', fontSize: 15 }}>
                  No hay canciones con este estado en {playlist.name}.
                </p>
              )}
            </div>
          </div>
          {playlist.total > playlist.tracks.length && (
            <p className={`${s.more} ${ui.muted}`} style={{ fontSize: 13 }}>
              Mostrando {playlist.tracks.length} de {fmt(playlist.total)} canciones de ejemplo.
            </p>
          )}
        </div>
      </PanelScroll>
    </AppShell>
  )
}
