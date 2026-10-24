import { AppShell, PanelScroll } from '../components/shell/AppShell'
import { Icon } from '../components/Icon'
import { Button, buttonClass, Cover, Dot, ServiceDot, ui } from '../components/ui'
import { directionLabel, fmt } from '../lib/format'
import { Link } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import { jobPercent, pendingTotal, playlistById, playlistCounts, playlistStatus } from '../store/selectors'
import type { Run } from '../store/types'
import s from './Inicio.module.css'

const FREQUENCY = { hourly: 'cada hora', daily: 'todos los días', weekly: 'una vez por semana' }

function greeting(date: Date): string {
  const h = date.getHours()
  if (h < 6 || h >= 20) return 'Buenas noches'
  if (h < 13) return 'Buen día'
  return 'Buenas tardes'
}

function todayLabel(date: Date): string {
  const text = date.toLocaleDateString('es-AR', { weekday: 'long', day: 'numeric', month: 'long' })
  return text.replace(',', '')
}

function RunIcon({ run }: { run: Run }) {
  const map = {
    ok: { icon: 'check' as const, bg: 'var(--accent-tint)', color: 'var(--accent)' },
    warn: { icon: 'alert' as const, bg: 'var(--review-tint)', color: 'var(--review)' },
    fail: { icon: 'x' as const, bg: 'rgba(255,107,107,0.14)', color: 'var(--danger)' }
  }
  const m = map[run.status]
  return (
    <span aria-hidden="true" className={s.activityIcon} style={{ background: m.bg, color: m.color }}>
      <Icon name={m.icon} size={18} strokeWidth={2.6} />
    </span>
  )
}

export function Inicio() {
  const state = useAppState()
  const dispatch = useDispatch()
  const now = new Date()
  const pending = pendingTotal(state)
  const pct = jobPercent(state)
  const { settings } = state

  const withChanges = state.playlists
    .map((p) => ({ playlist: p, status: playlistStatus(state, p), counts: playlistCounts(state, p) }))
    .filter(({ status }) => status === 'pending' || status === 'syncing' || status === 'paused')
  const pendingPlaylists = withChanges.filter(({ status }) => status === 'pending')
  const reviewCovers = state.review.filter((r) => !state.resolutions[r.id]).slice(0, 3)
  const reviewPlaylistCount = state.playlists.filter((p) => playlistCounts(state, p).pending > 0).length

  return (
    <AppShell>
      <PanelScroll>
        <div className={s.page}>
          <div className={s.head}>
            <div className={s.greeting}>
              <span className={ui.eyebrow}>{todayLabel(now)}</span>
              <h1 className={s.title}>{greeting(now)}</h1>
            </div>
            <div className={s.actions}>
              <Link to={{ name: 'nueva' }} className={buttonClass('secondary', 'md', true)}>
                <Icon name="plus" size={18} strokeWidth={2.4} />
                Nueva sincronización
              </Link>
              <Button
                variant="primary"
                icon="sync"
                disabled={pendingPlaylists.length === 0}
                onClick={() => dispatch({ type: 'sync/start', playlistIds: pendingPlaylists.map((p) => p.playlist.id), direction: settings.defaultDirection })}
              >
                Sincronizar todo
              </Button>
            </div>
          </div>

          <div className={s.cards}>
            <Link to={{ name: 'revisar' }} className={s.card}>
              <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <span className={s.cardLabel} style={{ color: 'var(--review)' }}>
                  Para revisar
                </span>
                <span aria-hidden="true" className={s.stack}>
                  {reviewCovers.map((r) => (
                    <Cover key={r.id} src={r.artwork} size={32} radius={6} />
                  ))}
                </span>
              </span>
              <span style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <span className={s.bigNumber}>{pending}</span>
                <span className={s.cardText}>
                  {pending === 0 ? 'No queda nada por decidir.' : `canciones esperan tu decisión en ${reviewPlaylistCount} playlists`}
                </span>
              </span>
              <span className={s.cardLink}>
                Revisar ahora <Icon name="arrowRight" size={16} strokeWidth={2.4} />
              </span>
            </Link>

            <Link to={{ name: 'ajustes', section: 'sync' }} className={s.card}>
              <span className={s.cardLabel}>Próxima sincronización automática</span>
              <span style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <span className={s.bigNumber}>{settings.auto ? settings.hour : 'Apagada'}</span>
                <span className={s.cardText}>
                  {settings.auto ? `${FREQUENCY[settings.frequency]} · ${directionLabel(settings.defaultDirection)}` : 'Activala en Ajustes para no tener que acordarte.'}
                </span>
              </span>
              <span className={s.cardLink}>
                Cambiar horario <Icon name="arrowRight" size={16} strokeWidth={2.4} />
              </span>
            </Link>

            <div className={s.card}>
              <span className={s.cardLabel}>Cuentas conectadas</span>
              <span style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                <span className={s.accountRow}>
                  <ServiceDot service="spotify" />
                  <span style={{ flex: '1 1 auto', fontSize: 16, fontWeight: 600 }}>Spotify</span>
                  <span className={ui.muted} style={{ fontSize: 14 }}>
                    {state.accounts.spotify.connected ? `${state.accounts.spotify.playlists} playlists` : 'Sin conectar'}
                  </span>
                </span>
                <span className={s.accountRow}>
                  <ServiceDot service="apple" />
                  <span style={{ flex: '1 1 auto', fontSize: 16, fontWeight: 600 }}>Apple Music</span>
                  <span className={ui.muted} style={{ fontSize: 14 }}>
                    {state.accounts.apple.status === 'connected' ? `${state.accounts.apple.playlists} playlists` : 'Sin conectar'}
                  </span>
                </span>
              </span>
              <Link to={{ name: 'ajustes', section: 'cuentas' }} className={s.cardLink}>
                Administrar cuentas <Icon name="arrowRight" size={16} strokeWidth={2.4} />
              </Link>
            </div>
          </div>

          {withChanges.length > 0 && (
            <section style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
              <div className={s.sectionHead}>
                <h2 className={ui.sectionTitle}>Playlists con cambios</h2>
              </div>
              <div className={s.tiles}>
                {withChanges.map(({ playlist, status, counts }) => (
                  <Link key={playlist.id} to={{ name: 'playlist', id: playlist.id }} className={s.tile}>
                    <span className={s.tileArt}>
                      <img src={playlist.artwork} alt="" />
                      <span className={`${s.tileChip} ${ui.glass}`}>
                        {status === 'pending' ? (
                          <>
                            <Dot color="var(--review-dot)" style={{ width: 7, height: 7 }} />
                            {counts.pending} por revisar
                          </>
                        ) : (
                          <>
                            <Icon name="sync" size={13} strokeWidth={2.8} className={status === 'syncing' ? 'spin' : undefined} />
                            {status === 'syncing' ? `Sincronizando · ${pct} %` : `En pausa · ${pct} %`}
                          </>
                        )}
                      </span>
                    </span>
                    <span style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                      <span className={s.tileName}>{playlist.name}</span>
                      <span className={ui.muted} style={{ fontSize: 13 }}>
                        {fmt(playlist.total)} canciones · {playlist.lastSync}
                      </span>
                    </span>
                  </Link>
                ))}
              </div>
            </section>
          )}

          <section className={s.activity}>
            <div className={s.sectionHead} style={{ marginBottom: 8 }}>
              <h2 className={ui.sectionTitle}>Actividad reciente</h2>
              <Link to={{ name: 'historial' }} className={s.sectionLink}>
                Ver historial
              </Link>
            </div>
            {state.runs.slice(0, 4).map((run) => {
              const playlist = playlistById(state, run.playlistId)
              const text =
                run.status === 'fail'
                  ? `Falló: ${run.steps.find(([k]) => k === 'fail')?.[1] ?? ''}`
                  : run.review > 0
                    ? `${run.result} coinciden · ${run.review} canciones quedaron para revisar`
                    : run.label === 'Sin cambios'
                      ? 'Sin cambios desde la última sincronización'
                      : `${run.result} canciones copiadas`
              return (
                <Link key={run.id} to={{ name: 'historial' }} className={s.activityRow}>
                  <RunIcon run={run} />
                  <span className={s.activityText}>
                    <span style={{ fontSize: 15, fontWeight: 600 }}>{playlist?.name ?? 'Playlist'}</span>
                    <span className={ui.muted} style={{ fontSize: 14 }}>
                      {text}
                    </span>
                  </span>
                  <span className={ui.muted} style={{ flex: 'none', fontSize: 13 }}>
                    {run.when}
                  </span>
                </Link>
              )
            })}
          </section>
        </div>
      </PanelScroll>
    </AppShell>
  )
}
