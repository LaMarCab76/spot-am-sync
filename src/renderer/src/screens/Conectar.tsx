import { useEffect, useRef } from 'react'
import { BrandMark } from '../components/shell/TopBar'
import { Icon } from '../components/Icon'
import { Button, ServiceDot, ui } from '../components/ui'
import { wallArt } from '../data/artwork'
import { fmt } from '../lib/format'
import { useRouter } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import s from './Conectar.module.css'

// Stand-in for the Apple sign-in window until MusicKit is wired in.
const FAKE_SIGN_IN_MS = 1200

function Connected() {
  return (
    <span className={s.connected}>
      <Icon name="checkCircle" size={16} strokeWidth={2.6} />
      <span>Conectado</span>
    </span>
  )
}

export function Conectar() {
  const { accounts, playlists } = useAppState()
  const dispatch = useDispatch()
  const { navigate } = useRouter()
  const timer = useRef<number | undefined>(undefined)
  const apple = accounts.apple.status
  const liked = playlists.find((p) => p.id === 'liked')

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const connectApple = () => {
    if (apple !== 'disconnected') return
    dispatch({ type: 'apple/connect-start' })
    timer.current = window.setTimeout(() => dispatch({ type: 'apple/connect-done' }), FAKE_SIGN_IN_MS)
  }

  const finish = () => {
    dispatch({ type: 'onboarding/complete' })
    navigate({ name: 'inicio' })
  }

  return (
    <div className={`scroll ${s.screen}`}>
      <div aria-hidden="true" className={s.wall}>
        <div className={s.wallGrid}>
          {wallArt.map((src) => (
            <img key={src} src={src} alt="" />
          ))}
        </div>
        <div className={s.wallFade} />
      </div>

      <header className={s.header}>
        <span className={s.brand}>
          <BrandMark />
          Spot·AM Sync
        </span>
        <a href="https://github.com/LaMarCab76/spot-am-sync" target="_blank" rel="noreferrer" className={`${s.help} ${ui.glass}`}>
          Ayuda
        </a>
      </header>

      <div className={s.content}>
        <div className={s.intro}>
          <h1 className={s.title}>Tus playlists, en Spotify y en Apple Music.</h1>
          <p className={s.lead}>Conectá las dos cuentas. Comparamos cada canción y te avisamos cuando no encontramos la versión exacta.</p>
        </div>

        <section aria-label="Cuentas" className={s.accounts}>
          <div className={s.service}>
            <span className={s.serviceHead}>
              <ServiceDot service="spotify" />
              <span className={s.serviceName}>Spotify</span>
              <Connected />
            </span>
            <span className={s.detail}>
              <span>{accounts.spotify.user}</span>
              <span className={ui.muted} style={{ fontSize: 14 }}>
                {accounts.spotify.playlists} playlists{liked ? ` · ${fmt(liked.total)} canciones que te gustan` : ''}
              </span>
            </span>
            <Button variant="tonal" size="sm" style={{ alignSelf: 'flex-start' }}>
              Cambiar cuenta
            </Button>
          </div>

          <div aria-hidden="true" className={s.swap}>
            <Icon name="swap" />
          </div>

          <div className={s.service}>
            <span className={s.serviceHead}>
              <ServiceDot service="apple" />
              <span className={s.serviceName}>Apple Music</span>
              {apple === 'connected' ? <Connected /> : <span className={ui.muted} style={{ fontSize: 13, fontWeight: 600 }}>Sin conectar</span>}
            </span>
            {apple === 'connected' ? (
              <>
                <span className={s.detail}>
                  <span>{accounts.apple.user}</span>
                  <span className={ui.muted} style={{ fontSize: 14 }}>
                    {accounts.apple.playlists} playlists en tu biblioteca
                  </span>
                </span>
                <Button variant="tonal" size="sm" style={{ alignSelf: 'flex-start' }} onClick={() => dispatch({ type: 'account/disconnect', service: 'apple' })}>
                  Cambiar cuenta
                </Button>
              </>
            ) : (
              <>
                <span className={ui.muted} style={{ fontSize: 14, lineHeight: 1.45 }}>
                  Vas a iniciar sesión con tu Apple ID en una ventana de Apple.
                </span>
                <Button variant="primary" style={{ alignSelf: 'flex-start' }} onClick={connectApple} aria-busy={apple === 'connecting'}>
                  {apple === 'connecting' && <Icon name="spinner" size={16} strokeWidth={2.6} className="spin" />}
                  {apple === 'connecting' ? 'Esperando a Apple…' : 'Conectar Apple Music'}
                </Button>
              </>
            )}
          </div>
        </section>

        <p className={s.note}>
          <Icon name="lock" size={15} />
          <span>Solo pedimos permiso para leer tu biblioteca y crear o editar playlists. Nunca publicamos nada en tu nombre.</span>
        </p>

        <div className={s.actions}>
          <Button variant="primary" size="lg" style={{ minWidth: 240 }} disabled={apple !== 'connected'} onClick={finish}>
            {apple === 'connected' ? 'Continuar' : 'Conectá Apple Music para seguir'}
            {apple === 'connected' && <Icon name="arrowRight" size={18} strokeWidth={2.4} />}
          </Button>
          <button type="button" className={s.later} onClick={finish} style={{ background: 'none', border: 0 }}>
            Lo hago después
          </button>
        </div>
      </div>
    </div>
  )
}
