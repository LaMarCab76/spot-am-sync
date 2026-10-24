import { useEffect, useRef, useState, type ReactNode } from 'react'
import { AppShell } from '../components/shell/AppShell'
import { Icon } from '../components/Icon'
import { Button, Segmented, ServiceDot, SwitchRow, ui } from '../components/ui'
import { useAppState, useDispatch } from '../store/StoreProvider'
import type { Settings } from '../store/types'
import { PRECISION_HELP, PRECISION_OPTIONS } from './NuevaSync'
import s from './Ajustes.module.css'

const SECTIONS = [
  { id: 'cuentas', label: 'Cuentas' },
  { id: 'sync', label: 'Sincronización' },
  { id: 'coincidencias', label: 'Coincidencias' },
  { id: 'notificaciones', label: 'Notificaciones' },
  { id: 'datos', label: 'Privacidad y datos' }
]

const FREQUENCIES: Array<{ id: Settings['frequency']; label: string }> = [
  { id: 'hourly', label: 'Cada hora' },
  { id: 'daily', label: 'Diaria' },
  { id: 'weekly', label: 'Semanal' }
]

function Row({ title, desc, htmlFor, children }: { title: string; desc?: string; htmlFor?: string; children: ReactNode }) {
  return (
    <div className={s.row}>
      <span className={s.rowText}>
        {htmlFor ? (
          <label htmlFor={htmlFor} className={s.rowTitle}>
            {title}
          </label>
        ) : (
          <span className={s.rowTitle}>{title}</span>
        )}
        {desc && <span className={s.rowDesc}>{desc}</span>}
      </span>
      {children}
    </div>
  )
}

function Select<T extends string>({ id, value, options, onChange }: { id: string; value: T; options: Array<[T, string]>; onChange: (v: T) => void }) {
  return (
    <span className={s.selectWrap}>
      <select id={id} className={s.select} value={value} onChange={(e) => onChange(e.target.value as T)}>
        {options.map(([v, label]) => (
          <option key={v} value={v}>
            {label}
          </option>
        ))}
      </select>
      <Icon name="chevronDown" size={14} strokeWidth={2.6} />
    </span>
  )
}

export function Ajustes({ section }: { section?: string }) {
  const { settings, accounts } = useAppState()
  const dispatch = useDispatch()
  const [active, setActive] = useState(section ?? 'cuentas')
  const content = useRef<HTMLDivElement>(null)
  const set = (patch: Partial<Settings>) => dispatch({ type: 'settings/update', patch })

  const goTo = (id: string) => {
    setActive(id)
    content.current?.querySelector(`#${id}`)?.scrollIntoView({ block: 'start' })
  }

  // Follow the section in the route (links like "Administrar cuentas"); local clicks don't change it.
  useEffect(() => {
    if (!section) return
    setActive(section)
    content.current?.querySelector(`#${section}`)?.scrollIntoView({ block: 'start' })
  }, [section])

  const appleConnected = accounts.apple.status === 'connected'

  return (
    <AppShell>
      <div className={s.split}>
        <nav aria-label="Secciones de ajustes" className={s.nav}>
          <h1 className={`${ui.pageTitle} ${s.navTitle}`}>Ajustes</h1>
          {SECTIONS.map((sec) => (
            <button key={sec.id} type="button" className={s.navItem} aria-current={active === sec.id} onClick={() => goTo(sec.id)}>
              {sec.label}
            </button>
          ))}
        </nav>

        <div ref={content} className={`scroll ${s.content}`}>
          <div className={s.inner}>
            <section id="cuentas" aria-labelledby="h-cuentas" className={s.section}>
              <h2 id="h-cuentas" className={ui.sectionTitle}>
                Cuentas
              </h2>
              <div className={ui.listCard}>
                <div className={s.account}>
                  <ServiceDot service="spotify" />
                  <span className={s.rowText} style={{ flex: '1 1 260px' }}>
                    <span style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.02em' }}>Spotify</span>
                    <span style={{ fontSize: 14, color: 'var(--text-2)' }}>
                      {accounts.spotify.connected ? `Conectado como ${accounts.spotify.user}` : 'Sin conectar'}
                    </span>
                    <span className={s.rowDesc}>Puede leer tu biblioteca y crear o editar playlists.</span>
                  </span>
                  <Button variant="secondary" size="sm" disabled={!accounts.spotify.connected} onClick={() => dispatch({ type: 'account/disconnect', service: 'spotify' })}>
                    Desconectar
                  </Button>
                </div>
                <div className={s.account}>
                  <ServiceDot service="apple" />
                  <span className={s.rowText} style={{ flex: '1 1 260px' }}>
                    <span style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.02em' }}>Apple Music</span>
                    <span style={{ fontSize: 14, color: 'var(--text-2)' }}>{appleConnected ? `Conectado como ${accounts.apple.user}` : 'Sin conectar'}</span>
                    <span className={s.rowDesc}>Puede leer tu biblioteca y crear o editar playlists.</span>
                  </span>
                  {appleConnected ? (
                    <Button variant="secondary" size="sm" onClick={() => dispatch({ type: 'account/disconnect', service: 'apple' })}>
                      Desconectar
                    </Button>
                  ) : (
                    <Button
                      variant="primary"
                      size="sm"
                      onClick={() => {
                        dispatch({ type: 'apple/connect-start' })
                        window.setTimeout(() => dispatch({ type: 'apple/connect-done' }), 1200)
                      }}
                    >
                      {accounts.apple.status === 'connecting' ? 'Esperando a Apple…' : 'Conectar'}
                    </Button>
                  )}
                </div>
              </div>
            </section>

            <section id="sync" aria-labelledby="h-sync" className={s.section}>
              <h2 id="h-sync" className={ui.sectionTitle}>
                Sincronización
              </h2>
              <div className={ui.listCard}>
                <SwitchRow
                  title="Sincronización automática"
                  description="Revisa cambios y sincroniza sin que abras la app."
                  checked={settings.auto}
                  onChange={(auto) => set({ auto })}
                />
                <div className={settings.auto ? s.undimmed : s.dimmed}>
                  <Row title="Frecuencia" desc="Cada hora solo revisa; copia si hubo cambios.">
                    <span id="freq-label" className="visually-hidden">
                      Frecuencia
                    </span>
                    <Segmented labelledBy="freq-label" options={FREQUENCIES} value={settings.frequency} onChange={(frequency) => set({ frequency })} />
                  </Row>
                  <Row title="Hora" desc="Para la sincronización diaria o semanal." htmlFor="hora">
                    <Select
                      id="hora"
                      value={settings.hour}
                      options={['06:00', '12:00', '18:00', '22:00'].map((h) => [h, h] as [string, string])}
                      onChange={(hour) => set({ hour })}
                    />
                  </Row>
                </div>
                <Row title="Dirección predeterminada" desc="Se usa al crear una sincronización nueva." htmlFor="dir">
                  <Select
                    id="dir"
                    value={settings.defaultDirection}
                    options={[
                      ['s2a', 'Spotify → Apple Music'],
                      ['a2s', 'Apple Music → Spotify'],
                      ['both', 'En los dos sentidos']
                    ]}
                    onChange={(defaultDirection) => set({ defaultDirection })}
                  />
                </Row>
                <Row title="Si la playlist ya existe en destino" desc="Actualizarla agrega y quita canciones para que quede igual." htmlFor="existe">
                  <Select
                    id="existe"
                    value={settings.ifExists}
                    options={[
                      ['update', 'Actualizarla'],
                      ['copy', 'Crear una copia nueva']
                    ]}
                    onChange={(ifExists) => set({ ifExists })}
                  />
                </Row>
              </div>
            </section>

            <section id="coincidencias" aria-labelledby="h-coin" className={s.section}>
              <h2 id="h-coin" className={ui.sectionTitle}>
                Coincidencias
              </h2>
              <div className={ui.listCard}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '16px 20px', alignItems: 'flex-start' }}>
                  <span id="prec-label" className={s.rowTitle}>
                    Precisión
                  </span>
                  <Segmented labelledBy="prec-label" options={PRECISION_OPTIONS} value={settings.precision} onChange={(precision) => set({ precision })} />
                  <span className={s.rowDesc} style={{ maxWidth: '60ch', lineHeight: 1.45 }}>
                    {PRECISION_HELP[settings.precision]}
                  </span>
                </div>
                <SwitchRow
                  title="Preferir versiones de estudio"
                  description="Evita versiones en vivo o acústicas cuando hay opción."
                  checked={settings.preferStudio}
                  onChange={(preferStudio) => set({ preferStudio })}
                />
                <SwitchRow
                  title="Aceptar remasterizaciones automáticamente"
                  description="No las manda a Revisar si la duración coincide."
                  checked={settings.autoRemaster}
                  onChange={(autoRemaster) => set({ autoRemaster })}
                />
                <Row title="Diferencia de duración permitida" desc="Si la versión de destino dura más o menos que esto, queda en Revisar." htmlFor="tolerancia">
                  <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <input
                      id="tolerancia"
                      type="number"
                      min={0}
                      max={30}
                      className={s.number}
                      value={settings.tolerance}
                      onChange={(e) => set({ tolerance: Math.max(0, Math.min(30, Number(e.target.value) || 0)) })}
                    />
                    <span style={{ fontSize: 14, color: 'var(--text-2)' }}>segundos</span>
                  </span>
                </Row>
              </div>
            </section>

            <section id="notificaciones" aria-labelledby="h-notif" className={s.section}>
              <h2 id="h-notif" className={ui.sectionTitle}>
                Notificaciones
              </h2>
              <div className={ui.listCard}>
                <SwitchRow title="Cuando termine una sincronización" checked={settings.notifyDone} onChange={(notifyDone) => set({ notifyDone })} />
                <SwitchRow title="Cuando haya canciones para revisar" checked={settings.notifyReview} onChange={(notifyReview) => set({ notifyReview })} />
                <SwitchRow title="Si una sincronización falla" checked={settings.notifyFail} onChange={(notifyFail) => set({ notifyFail })} />
              </div>
            </section>

            <section id="datos" aria-labelledby="h-datos" className={s.section}>
              <h2 id="h-datos" className={ui.sectionTitle}>
                Privacidad y datos
              </h2>
              <div className={ui.listCard}>
                <Row title="Exportar historial" desc="Un archivo CSV con cada sincronización y su resultado.">
                  <Button variant="secondary" size="sm">
                    Exportar CSV
                  </Button>
                </Row>
                <Row title="Borrar historial" desc="Ya no vas a poder deshacer sincronizaciones anteriores.">
                  <Button variant="secondary" size="sm">
                    Borrar
                  </Button>
                </Row>
                <Row title="Desconectar todo y borrar mis datos" desc="Tus playlists en Spotify y Apple Music no se tocan.">
                  <Button variant="danger" size="sm">
                    Borrar todo
                  </Button>
                </Row>
              </div>
            </section>
          </div>
        </div>
      </div>
    </AppShell>
  )
}
