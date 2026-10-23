import { Link, useRouter } from '../../router'
import { useAppState } from '../../store/StoreProvider'
import { Icon } from '../Icon'
import { cx, ServiceDot } from '../ui'
import s from './shell.module.css'

export function BrandMark() {
  return (
    <span className={s.brandMark}>
      <Icon name="sync" strokeWidth={2.4} />
    </span>
  )
}

export function TopBar({ query, onQuery }: { query: string; onQuery: (q: string) => void }) {
  const { route } = useRouter()
  const { accounts } = useAppState()
  const appleOn = accounts.apple.status === 'connected'

  return (
    <header className={s.topbar}>
      <div className={s.topLeft}>
        <Link to={{ name: 'inicio' }} className={s.brand}>
          <BrandMark />
          <span className={s.brandName}>Spot·AM Sync</span>
        </Link>
      </div>

      <div className={s.topCenter}>
        <Link to={{ name: 'inicio' }} aria-label="Inicio" aria-current={route.name === 'inicio' ? 'page' : undefined} className={s.homeButton}>
          <Icon name={route.name === 'inicio' ? 'homeFilled' : 'home'} size={22} strokeWidth={2} />
        </Link>
        <div className={s.search}>
          <label htmlFor="buscar" className="visually-hidden">
            Buscar en tu biblioteca
          </label>
          <Icon name="search" className={s.searchIcon} />
          <input
            id="buscar"
            type="search"
            className={s.searchInput}
            placeholder="Buscar playlists"
            value={query}
            onChange={(e) => onQuery(e.target.value)}
          />
        </div>
      </div>

      <div className={s.topRight}>
        <Link to={{ name: 'ajustes', section: 'cuentas' }} className={cx(s.servicePill, !accounts.spotify.connected && s.off)}>
          <ServiceDot service="spotify" />
          <span>Spotify</span>
          <span className="visually-hidden">{accounts.spotify.connected ? 'conectado' : 'sin conectar'}</span>
        </Link>
        <Link to={{ name: 'ajustes', section: 'cuentas' }} className={cx(s.servicePill, !appleOn && s.off)}>
          <ServiceDot service="apple" />
          <span>Apple Music</span>
          <span className="visually-hidden">{appleOn ? 'conectado' : 'sin conectar'}</span>
        </Link>
        <Link
          to={{ name: 'ajustes' }}
          aria-label="Ajustes y cuenta"
          aria-current={route.name === 'ajustes' ? 'page' : undefined}
          className={s.avatar}
        >
          <Icon name="user" strokeWidth={2} />
        </Link>
      </div>
    </header>
  )
}
