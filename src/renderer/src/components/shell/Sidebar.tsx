import { useState } from 'react'
import { Link, useRouter } from '../../router'
import { useAppState } from '../../store/StoreProvider'
import { jobPercent, pendingTotal, playlistCounts, playlistStatus, type PlaylistStatus } from '../../store/selectors'
import { Icon } from '../Icon'
import { ChipGroup, Cover, Dot, iconButtonClass } from '../ui'
import s from './shell.module.css'

type LibraryFilter = 'all' | 'pending' | 'synced'

const FILTERS: Array<{ id: LibraryFilter; label: string }> = [
  { id: 'all', label: 'Todas' },
  { id: 'pending', label: 'Pendientes' },
  { id: 'synced', label: 'Sincronizadas' }
]

function StatusIcon({ status }: { status: PlaylistStatus }) {
  if (status === 'syncing') return <Icon name="sync" size={18} strokeWidth={2.4} className="spin" style={{ color: 'var(--accent)' }} />
  if (status === 'synced') return <Icon name="checkCircle" size={18} strokeWidth={2.4} style={{ color: 'var(--accent)' }} />
  if (status === 'pending' || status === 'paused') return <Dot color="var(--review-dot)" style={{ margin: '0 5px' }} />
  return null
}

export function Sidebar({ query }: { query: string }) {
  const state = useAppState()
  const { route } = useRouter()
  const [filter, setFilter] = useState<LibraryFilter>('all')
  const pending = pendingTotal(state)
  const pct = jobPercent(state)
  const q = query.trim().toLowerCase()

  const items = state.playlists
    .map((p) => ({ playlist: p, status: playlistStatus(state, p), counts: playlistCounts(state, p) }))
    .filter(({ playlist }) => !q || playlist.name.toLowerCase().includes(q))
    .filter(({ status }) => {
      if (filter === 'pending') return status !== 'synced'
      if (filter === 'synced') return status === 'synced'
      return true
    })

  const navCurrent = (name: string) => (route.name === name ? 'page' : undefined)

  return (
    <aside aria-label="Navegación y biblioteca" className={`scroll ${s.sidebar}`}>
      <nav aria-label="Secciones" className={s.nav}>
        <Link to={{ name: 'inicio' }} className={s.navItem} aria-current={navCurrent('inicio')}>
          <Icon name="home" />
          <span>Inicio</span>
        </Link>
        <Link to={{ name: 'revisar' }} className={s.navItem} aria-current={navCurrent('revisar')}>
          <Icon name="alert" />
          <span>Revisar</span>
          {pending > 0 && <span className={s.navBadge}>{pending}</span>}
        </Link>
        <Link to={{ name: 'historial' }} className={s.navItem} aria-current={navCurrent('historial')}>
          <Icon name="history" />
          <span>Historial</span>
        </Link>
      </nav>

      <div aria-hidden="true" className={s.divider} />

      <div className={s.libraryHeader}>
        <h2 className={s.libraryTitle}>Tu biblioteca</h2>
        <Link
          to={{ name: 'nueva' }}
          aria-label="Nueva sincronización"
          aria-current={navCurrent('nueva')}
          className={iconButtonClass(false, route.name === 'nueva')}
        >
          <Icon name="plus" />
        </Link>
      </div>

      <ChipGroup label="Filtrar biblioteca" options={FILTERS} value={filter} onChange={setFilter} className={s.libraryChips} />

      <ul style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {items.map(({ playlist, status, counts }) => {
          let meta = `${counts.pending} por revisar`
          let color = 'var(--review)'
          if (status === 'syncing') {
            meta = `Sincronizando · ${pct} %`
            color = 'var(--accent)'
          } else if (status === 'paused') {
            meta = `En pausa · ${pct} %`
          } else if (status === 'synced') {
            meta = `Sincronizada · ${playlist.lastSync}`
            color = 'var(--text-3)'
          } else if (status === 'never') {
            meta = 'Sin sincronizar'
            color = 'var(--text-3)'
          }
          const current = route.name === 'playlist' && route.id === playlist.id
          return (
            <li key={playlist.id}>
              <Link to={{ name: 'playlist', id: playlist.id }} className={s.libraryItem} aria-current={current ? 'page' : undefined}>
                <Cover src={playlist.artwork} size={52} />
                <span className={s.libraryText}>
                  <span className={s.libraryName}>{playlist.name}</span>
                  <span className={s.libraryMeta} style={{ color }}>
                    {meta}
                  </span>
                </span>
                <StatusIcon status={status} />
              </Link>
            </li>
          )
        })}
      </ul>
      {items.length === 0 && <p className={s.empty}>No hay playlists con ese nombre o filtro.</p>}
    </aside>
  )
}
