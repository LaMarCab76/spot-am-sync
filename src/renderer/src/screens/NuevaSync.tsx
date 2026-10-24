import { useState } from 'react'
import { AppShell, PanelScroll } from '../components/shell/AppShell'
import { Icon } from '../components/Icon'
import { Button, buttonClass, cx, Cover, Dot, Segmented, SwitchRow, ui } from '../components/ui'
import { directionEnds, directionLabel, fmt, serviceName } from '../lib/format'
import { Link, useRouter } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import type { Direction, Settings } from '../store/types'
import s from './NuevaSync.module.css'

const STEPS = ['Dirección', 'Playlists', 'Opciones']

const DIRECTIONS: Array<{ id: Direction; title: string; desc: string }> = [
  { id: 's2a', title: 'De Spotify a Apple Music', desc: 'Copia tus playlists de Spotify en Apple Music.' },
  { id: 'a2s', title: 'De Apple Music a Spotify', desc: 'Copia tus playlists de Apple Music en Spotify.' },
  { id: 'both', title: 'En los dos sentidos', desc: 'Mantiene las dos versiones iguales: lo que cambies en una se copia a la otra.' }
]

export const PRECISION_HELP: Record<Settings['precision'], string> = {
  strict: 'Solo acepta la misma grabación exacta. Más canciones van a quedar en Revisar.',
  balanced: 'Acepta remasterizaciones y ediciones con la misma duración. Lo dudoso queda en Revisar.',
  flexible: 'Acepta la versión más parecida aunque cambie el álbum. Revisás menos, pero puede haber errores.'
}

export const PRECISION_OPTIONS: Array<{ id: Settings['precision']; label: string }> = [
  { id: 'strict', label: 'Estricta' },
  { id: 'balanced', label: 'Equilibrada' },
  { id: 'flexible', label: 'Flexible' }
]

export function NuevaSync() {
  const state = useAppState()
  const dispatch = useDispatch()
  const { navigate } = useRouter()
  const { settings } = state

  const [step, setStep] = useState(1)
  const [direction, setDirection] = useState<Direction>(settings.defaultDirection)
  const [selected, setSelected] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(state.playlists.filter((p) => p.review + p.missing > 0 && p.id !== 'liked').map((p) => [p.id, true]))
  )
  const [query, setQuery] = useState('')
  const [ifExists, setIfExists] = useState(settings.ifExists)
  const [precision, setPrecision] = useState(settings.precision)
  const [keepOrder, setKeepOrder] = useState(true)
  const [skipDupes, setSkipDupes] = useState(true)
  const [daily, setDaily] = useState(false)

  const { from, to } = directionEnds(direction)
  const fromName = serviceName(from)
  const toName = serviceName(to)
  const chosen = state.playlists.filter((p) => selected[p.id])
  const songs = chosen.reduce((n, p) => n + p.total, 0)
  const q = query.trim().toLowerCase()
  const visible = state.playlists.filter((p) => !q || p.name.toLowerCase().includes(q))
  const allOn = visible.length > 0 && visible.every((p) => selected[p.id])
  const nextDisabled = step === 2 && chosen.length === 0

  const toggleAll = () => {
    const next = { ...selected }
    for (const p of visible) next[p.id] = !allOn
    setSelected(next)
  }

  const start = () => {
    dispatch({ type: 'settings/update', patch: { ifExists, precision, ...(daily ? { auto: true, frequency: 'daily' as const } : {}) } })
    dispatch({ type: 'sync/start', playlistIds: chosen.map((p) => p.id), direction })
    navigate({ name: 'playlist', id: chosen[0].id })
  }

  const bar = (
    <section aria-label="Acciones" className={ui.glassBar}>
      <span className={s.barText}>
        <span style={{ fontSize: 15, fontWeight: 600 }}>
          {chosen.length} {chosen.length === 1 ? 'playlist' : 'playlists'} · {fmt(songs)} canciones
        </span>
        <span style={{ fontSize: 13, color: 'var(--text-2)' }}>{directionLabel(direction)}</span>
      </span>
      <div className={s.barActions}>
        <Link to={{ name: 'inicio' }} className={buttonClass('ghost')}>
          Cancelar
        </Link>
        {step > 1 && (
          <Button variant="tonal" onClick={() => setStep(step - 1)}>
            Atrás
          </Button>
        )}
        {step < 3 ? (
          <Button variant="primary" disabled={nextDisabled} onClick={() => setStep(step + 1)}>
            Siguiente
            <Icon name="arrowRight" size={18} strokeWidth={2.4} />
          </Button>
        ) : (
          <Button variant="primary" icon="sync" onClick={start}>
            Empezar sincronización
          </Button>
        )}
      </div>
    </section>
  )

  return (
    <AppShell bar={bar}>
      <PanelScroll>
        <div className={s.page}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
            <span className={ui.eyebrow}>Nueva sincronización</span>
            <ol aria-label="Pasos" className={s.steps}>
              {STEPS.map((label, i) => {
                const n = i + 1
                const done = n < step
                return (
                  <li key={label} className={s.step}>
                    <button
                      type="button"
                      className={cx(s.stepButton, done && s.stepDone)}
                      aria-current={n === step ? 'step' : undefined}
                      disabled={n > step}
                      onClick={() => setStep(n)}
                    >
                      <span className={s.stepMark}>{done ? <Icon name="check" size={14} strokeWidth={3} /> : n}</span>
                      {label}
                    </button>
                    {n < STEPS.length && <span aria-hidden="true" className={s.stepLine} />}
                  </li>
                )
              })}
            </ol>
          </div>

          {step === 1 && (
            <section className={s.section}>
              <div className={s.heading}>
                <h1 className={ui.pageTitle}>¿Desde dónde y hacia dónde?</h1>
                <p className={ui.muted}>Las dos cuentas ya están conectadas. Elegí en qué sentido copiar.</p>
              </div>
              <fieldset className={s.grid}>
                <legend className="visually-hidden">Dirección de la sincronización</legend>
                {DIRECTIONS.map((d) => {
                  const ends = d.id === 'a2s' ? (['apple', 'spotify'] as const) : (['spotify', 'apple'] as const)
                  return (
                    <label key={d.id} className={cx(ui.optionCard, s.dirCard)}>
                      <span className={s.dirTop}>
                        <span className={s.dirEnds}>
                          <Dot color={`var(--${ends[0]})`} />
                          {serviceName(ends[0])}
                          <span aria-hidden="true" className={ui.muted}>
                            {d.id === 'both' ? '⇄' : '→'}
                          </span>
                          <Dot color={`var(--${ends[1]})`} />
                          {serviceName(ends[1])}
                        </span>
                        <input type="radio" name="direction" className={ui.radio} checked={direction === d.id} onChange={() => setDirection(d.id)} />
                      </span>
                      <span style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                        <span style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.02em' }}>{d.title}</span>
                        <span className={ui.muted} style={{ fontSize: 14, lineHeight: 1.45 }}>
                          {d.desc}
                        </span>
                      </span>
                    </label>
                  )
                })}
              </fieldset>
            </section>
          )}

          {step === 2 && (
            <section className={s.section}>
              <div className={s.heading}>
                <h1 className={ui.pageTitle}>Elegí las playlists</h1>
                <p className={ui.muted}>
                  Se muestran tus playlists de {fromName}. Las que ya existen en {toName} se actualizan.
                </p>
              </div>
              <div className={s.toolbar}>
                <div className={s.filter}>
                  <label htmlFor="filtro" className="visually-hidden">
                    Filtrar playlists
                  </label>
                  <Icon name="search" size={18} />
                  <input id="filtro" type="search" placeholder="Filtrar por nombre" value={query} onChange={(e) => setQuery(e.target.value)} />
                </div>
                <label className={s.selectAll}>
                  <input type="checkbox" className={ui.checkbox} style={{ width: 18, height: 18 }} checked={allOn} onChange={toggleAll} />
                  Seleccionar todas
                </label>
              </div>
              <ul style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                {visible.map((p) => (
                  <li key={p.id}>
                    <label className={s.plRow}>
                      <input
                        type="checkbox"
                        className={ui.checkbox}
                        checked={!!selected[p.id]}
                        onChange={() => setSelected({ ...selected, [p.id]: !selected[p.id] })}
                      />
                      <Cover src={p.artwork} size={52} />
                      <span style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
                        <span style={{ fontSize: 15, fontWeight: 600 }}>{p.name}</span>
                        <span className={ui.muted} style={{ fontSize: 13 }}>
                          {fmt(p.total)} canciones
                        </span>
                      </span>
                      <span
                        className={s.tag}
                        style={p.inDestination ? { background: 'var(--selected)', color: 'var(--missing)' } : { background: 'var(--accent-tint)', color: 'var(--accent)' }}
                      >
                        {p.inDestination ? `Existe en ${toName} · se actualiza` : `Nueva en ${toName}`}
                      </span>
                    </label>
                  </li>
                ))}
              </ul>
              {visible.length === 0 && <p className={ui.muted}>Ninguna playlist se llama así.</p>}
            </section>
          )}

          {step === 3 && (
            <section className={s.section} style={{ gap: 28 }}>
              <div className={s.heading}>
                <h1 className={ui.pageTitle}>Opciones</h1>
                <p className={ui.muted}>Podés cambiarlas después en Ajustes.</p>
              </div>

              <fieldset style={{ margin: 0, padding: 0, border: 0, minWidth: 0 }}>
                <legend className={s.legend}>Si la playlist ya existe en {toName}</legend>
                <div className={s.grid}>
                  {[
                    { id: 'update' as const, title: 'Actualizarla', desc: `Agrega y quita canciones para que quede igual que en ${fromName}.` },
                    { id: 'copy' as const, title: 'Crear una copia nueva', desc: 'Deja la existente como está y crea otra al lado.' }
                  ].map((o) => (
                    <label key={o.id} className={ui.optionCard}>
                      <input type="radio" name="exists" className={ui.radio} style={{ marginTop: 1 }} checked={ifExists === o.id} onChange={() => setIfExists(o.id)} />
                      <span style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                        <span style={{ fontSize: 15, fontWeight: 600 }}>{o.title}</span>
                        <span className={ui.muted} style={{ fontSize: 14, lineHeight: 1.45 }}>
                          {o.desc}
                        </span>
                      </span>
                    </label>
                  ))}
                </div>
              </fieldset>

              <div style={{ display: 'flex', flexDirection: 'column', gap: 12, alignItems: 'flex-start' }}>
                <span id="prec-label" className={s.legend} style={{ margin: 0 }}>
                  Precisión de las coincidencias
                </span>
                <Segmented labelledBy="prec-label" options={PRECISION_OPTIONS} value={precision} onChange={setPrecision} />
                <p className={ui.muted} style={{ maxWidth: '64ch', fontSize: 14, lineHeight: 1.45 }}>
                  {PRECISION_HELP[precision]}
                </p>
              </div>

              <div className={ui.listCard}>
                <SwitchRow title="Mantener el orden de las canciones" description="Respeta el orden original de cada playlist." checked={keepOrder} onChange={setKeepOrder} />
                <SwitchRow
                  title="Omitir canciones duplicadas"
                  description="Si una canción ya está en la playlist de destino, no se agrega otra vez."
                  checked={skipDupes}
                  onChange={setSkipDupes}
                />
                <SwitchRow
                  title={`Repetir todos los días a las ${settings.hour}`}
                  description="Las próximas veces solo se copian los cambios."
                  checked={daily}
                  onChange={setDaily}
                />
              </div>
            </section>
          )}
        </div>
      </PanelScroll>
    </AppShell>
  )
}
