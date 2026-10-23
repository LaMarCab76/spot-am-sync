import { directionLabel, fmt } from '../../lib/format'
import { Link, useRouter } from '../../router'
import { useAppState, useDispatch } from '../../store/StoreProvider'
import { jobPercent, playlistById, playlistCounts } from '../../store/selectors'
import { Icon } from '../Icon'
import { Cover, IconButton, iconButtonClass, ProgressBar, ui } from '../ui'
import s from './shell.module.css'

export function SyncBar() {
  const state = useAppState()
  const dispatch = useDispatch()
  const { route } = useRouter()
  const job = state.job
  const playlist = job ? playlistById(state, job.playlistId) : undefined
  if (!job || !playlist) return null

  const pct = jobPercent(state)
  const counts = playlistCounts(state, playlist)
  const queued = state.queue.length

  let line = `Sincronizando · ${directionLabel(job.direction)}`
  let lineColor = 'var(--text-2)'
  let buttonLabel = 'Pausar sincronización'
  let buttonIcon: 'pause' | 'play' | 'sync' = 'pause'
  if (job.state === 'paused') {
    line = `En pausa · ${directionLabel(job.direction)}`
    lineColor = 'var(--review)'
    buttonLabel = 'Reanudar sincronización'
    buttonIcon = 'play'
  } else if (job.state === 'done') {
    line = counts.pending > 0 ? `Completada · ${fmt(counts.pending)} por revisar` : 'Completada · todo coincide'
    lineColor = 'var(--accent)'
    buttonLabel = 'Volver a sincronizar'
    buttonIcon = 'sync'
  }

  return (
    <section aria-label="Sincronización en curso" className={ui.glassBar}>
      <div className={s.barLeft}>
        <Cover src={playlist.artwork} size={52} radius={14} />
        <span className={s.barText}>
          <span className={s.barTitle}>{playlist.name}</span>
          <span className={s.barSub} style={{ color: lineColor }}>
            {line}
            {queued > 0 && ` · ${queued} en cola`}
          </span>
        </span>
      </div>
      <div className={s.barCenter}>
        <button type="button" aria-label={buttonLabel} className={s.playButton} onClick={() => dispatch({ type: 'sync/toggle' })}>
          <Icon name={buttonIcon} strokeWidth={2.4} />
        </button>
        <div className={s.barProgress}>
          <div className={s.barNumbers}>
            <span>
              {fmt(job.done)} de {fmt(job.total)} canciones
            </span>
            <span>{pct} %</span>
          </div>
          <ProgressBar value={job.done} max={job.total} label="Progreso de la sincronización" />
        </div>
      </div>
      <div className={s.barRight}>
        <IconButton icon="queue" label={queued > 0 ? `Cola de sincronización: ${queued}` : 'Cola de sincronización vacía'} />
        <Link to={{ name: 'historial' }} aria-label="Historial" className={iconButtonClass(false, route.name === 'historial')}>
          <Icon name="history" />
        </Link>
        <Link to={{ name: 'ajustes', section: 'sync' }} aria-label="Ajustes de sincronización" className={iconButtonClass(false, route.name === 'ajustes')}>
          <Icon name="sliders" />
        </Link>
      </div>
    </section>
  )
}
