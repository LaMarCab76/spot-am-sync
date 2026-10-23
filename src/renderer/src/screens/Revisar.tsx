import { useCallback, useEffect, useMemo, useState } from 'react'
import { AppShell } from '../components/shell/AppShell'
import { Icon } from '../components/Icon'
import { Button, buttonClass, ChipGroup, cx, Cover, Dot, Kbd, ProgressBar, ui } from '../components/ui'
import { Link } from '../router'
import { useAppState, useDispatch } from '../store/StoreProvider'
import { playlistById, reviewTotals } from '../store/selectors'
import type { CandidateTone, ReviewItem } from '../store/types'
import s from './Revisar.module.css'

type Filter = 'all' | 'rev' | 'miss'

const TONE: Record<CandidateTone, string> = { ok: 'var(--accent)', neutral: 'var(--missing)', warn: 'var(--review)' }

export function Revisar() {
  const state = useAppState()
  const dispatch = useDispatch()
  const [filter, setFilter] = useState<Filter>('all')
  const [choice, setChoice] = useState<Record<string, number>>({})
  const [selectedId, setSelectedId] = useState<string | undefined>(() => state.review.find((r) => !state.resolutions[r.id])?.id)

  const totals = reviewTotals(state)
  const resolvedCount = Object.keys(state.resolutions).length
  const grandTotal = totals.all + resolvedCount
  const list = useMemo(() => state.review.filter((r) => filter === 'all' || r.kind === filter), [state.review, filter])
  const current = list.find((r) => r.id === selectedId) ?? list[0]
  const resolution = current ? state.resolutions[current.id] : undefined

  const nextOpen = useCallback(
    (fromId: string, resolved: Record<string, unknown>) => {
      const i = list.findIndex((r) => r.id === fromId)
      const ordered = [...list.slice(i + 1), ...list.slice(0, i)]
      return ordered.find((r) => !resolved[r.id])?.id ?? fromId
    },
    [list]
  )

  const use = useCallback(() => {
    if (!current || current.kind !== 'rev') return
    const candidate = choice[current.id] ?? 0
    dispatch({ type: 'review/resolve', id: current.id, resolution: { kind: 'used', candidate } })
    setSelectedId(nextOpen(current.id, { ...state.resolutions, [current.id]: true }))
  }, [current, choice, dispatch, nextOpen, state.resolutions])

  const skip = useCallback(() => {
    if (!current) return
    dispatch({ type: 'review/resolve', id: current.id, resolution: { kind: 'skipped' } })
    setSelectedId(nextOpen(current.id, { ...state.resolutions, [current.id]: true }))
  }, [current, dispatch, nextOpen, state.resolutions])

  const move = useCallback(
    (delta: number) => {
      if (!current || list.length === 0) return
      const i = list.findIndex((r) => r.id === current.id)
      setSelectedId(list[(i + delta + list.length) % list.length].id)
    },
    [current, list]
  )

  // Keyboard shortcuts shown in the action bar; ignored while typing.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key === 'ArrowDown') {
        e.preventDefault()
        move(1)
      } else if (e.key === 'ArrowUp') {
        e.preventDefault()
        move(-1)
      } else if (e.key === 'Enter' && !resolution) {
        e.preventDefault()
        use()
      } else if (e.key.toLowerCase() === 's' && !resolution) {
        e.preventDefault()
        skip()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [move, use, skip, resolution])

  const groups = useMemo(() => {
    const out: Array<{ playlistId: string; items: ReviewItem[] }> = []
    for (const item of list) {
      const g = out.find((x) => x.playlistId === item.playlistId)
      if (g) g.items.push(item)
      else out.push({ playlistId: item.playlistId, items: [item] })
    }
    return out
  }, [list])

  const shownTotal = filter === 'all' ? grandTotal : filter === 'rev' ? totals.rev : totals.miss
  const chips: Array<{ id: Filter; label: string }> = [
    { id: 'all', label: `Todas · ${totals.all}` },
    { id: 'rev', label: `Dudosas · ${totals.rev}` },
    { id: 'miss', label: `No encontradas · ${totals.miss}` }
  ]

  const bar = current && (
    <section aria-label="Acciones" className={ui.glassBar}>
      <span className={s.hints}>
        <span className={s.hint}>
          <Kbd>↑</Kbd>
          <Kbd>↓</Kbd> Moverse
        </span>
        <span className={s.hint}>
          <Kbd>↵</Kbd> Usar
        </span>
        <span className={s.hint}>
          <Kbd>S</Kbd> Omitir
        </span>
      </span>
      <div className={s.barActions}>
        {resolution ? (
          <>
            <Button variant="tonal" icon="undo" onClick={() => dispatch({ type: 'review/undo', id: current.id })}>
              Deshacer
            </Button>
            <Button variant="primary" onClick={() => move(1)}>
              Siguiente
              <Icon name="arrowRight" size={18} strokeWidth={2.4} />
            </Button>
          </>
        ) : (
          <>
            <Button variant="tonal" onClick={skip}>
              Omitir canción
            </Button>
            {current.kind === 'rev' ? (
              <Button variant="primary" icon="check" onClick={use}>
                Usar esta versión
              </Button>
            ) : (
              <Button variant="primary" onClick={() => move(1)}>
                Dejar pendiente
              </Button>
            )}
          </>
        )}
      </div>
    </section>
  )

  return (
    <AppShell bar={null}>
      <div className={s.split}>
        <section aria-label="Cola de revisión" className={s.queue}>
          <div className={s.queueHead}>
            <h1 className={ui.pageTitle}>Revisar</h1>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 13, color: 'var(--text-2)', fontVariantNumeric: 'tabular-nums' }}>
                {resolvedCount} de {grandTotal} resueltas
              </span>
              <ProgressBar value={resolvedCount} max={grandTotal} label="Canciones resueltas" />
            </div>
            <ChipGroup
              label="Filtrar"
              options={chips}
              value={filter}
              onChange={(id) => {
                setFilter(id)
                setSelectedId(state.review.find((r) => id === 'all' || r.kind === id)?.id)
              }}
            />
          </div>
          <div className={`scroll ${s.queueList}`}>
            {groups.map((g) => (
              <div key={g.playlistId}>
                <h2 className={cx(ui.eyebrow, s.groupTitle)}>{playlistById(state, g.playlistId)?.name}</h2>
                <ul style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                  {g.items.map((item) => {
                    const r = state.resolutions[item.id]
                    const label = r ? (r.kind === 'used' ? 'Resuelta' : 'Omitida') : item.kind === 'rev' ? 'Dudosa' : 'No está'
                    const color = r ? (r.kind === 'used' ? 'var(--accent)' : 'var(--text-4)') : item.kind === 'rev' ? 'var(--review)' : 'var(--missing)'
                    return (
                      <li key={item.id}>
                        <button type="button" className={s.item} aria-current={item.id === current?.id} onClick={() => setSelectedId(item.id)}>
                          <Cover src={item.artwork} size={44} radius={6} style={{ opacity: r ? 0.5 : 1 }} />
                          <span className={s.itemText}>
                            <span className={s.itemTitle} style={{ color: r ? 'var(--text-4)' : 'var(--text)' }}>
                              {item.title}
                            </span>
                            <span className={ui.muted} style={{ fontSize: 13 }}>
                              {item.artist}
                            </span>
                          </span>
                          <span className={s.itemState} style={{ color }}>
                            {label}
                          </span>
                        </button>
                      </li>
                    )
                  })}
                </ul>
              </div>
            ))}
            <p className={ui.muted} style={{ margin: '14px 12px 0', fontSize: 13 }}>
              Mostrando {list.length} de {shownTotal} · las demás se cargan al bajar
            </p>
          </div>
        </section>

        <section aria-labelledby="track-title" className={s.detail}>
          <div className={`scroll ${s.detailScroll}`}>
            {current ? (
              <div className={s.detailInner}>
                <div className={s.original}>
                  <Cover src={current.artwork} size={168} radius={12} style={{ boxShadow: '0 20px 44px rgba(0,0,0,0.5)' }} />
                  <div className={s.originalText}>
                    <span className={ui.eyebrow} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                      <Dot color="var(--spotify)" style={{ width: 7, height: 7 }} />
                      En Spotify · {playlistById(state, current.playlistId)?.name}
                    </span>
                    <h2 id="track-title" className={s.trackTitle}>
                      {current.title}
                    </h2>
                    <span className={s.artist}>{current.artist}</span>
                    <span className={ui.eyebrow} style={{ marginTop: 6, color: 'var(--text-2)' }}>
                      {current.album} · {current.duration}
                    </span>
                  </div>
                  <Button variant="secondary" icon="play">
                    Escuchar 30 s
                  </Button>
                </div>

                {resolution?.kind === 'used' && (
                  <div className={s.notice} style={{ background: 'var(--accent-tint)', color: 'var(--text)' }}>
                    <Icon name="checkCircle" strokeWidth={2.4} style={{ color: 'var(--accent)' }} />
                    Listo: se va a usar «{current.candidates[resolution.candidate]?.title}» de {current.candidates[resolution.candidate]?.album}.
                  </div>
                )}
                {resolution?.kind === 'skipped' && (
                  <div className={s.notice}>
                    <Icon name="minusCircle" strokeWidth={2.4} />
                    Omitida: no se va a agregar a la playlist en Apple Music.
                  </div>
                )}

                {!resolution && current.kind === 'rev' && (
                  <>
                    <div className={s.notice}>
                      <Icon name="alert" strokeWidth={2.4} style={{ color: 'var(--review)' }} />
                      Hay {current.candidates.length} versiones parecidas en Apple Music. Marcamos la más probable.
                    </div>
                    <fieldset className={s.candidates}>
                      <legend className={ui.eyebrow} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10, padding: 0 }}>
                        <Dot color="var(--apple)" style={{ width: 7, height: 7 }} />
                        Opciones en Apple Music
                      </legend>
                      {current.candidates.map((c, i) => (
                        <label key={`${c.title}-${c.album}`} className={cx(ui.optionCard, s.candidate)}>
                          <Cover src={c.artwork} size={56} />
                          <span style={{ flex: '1 1 auto', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
                            <span style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}>
                              <span style={{ fontSize: 15, fontWeight: 600 }}>{c.title}</span>
                              {i === 0 && <span className={s.recommended}>Recomendada</span>}
                            </span>
                            <span className={ui.muted} style={{ fontSize: 14 }}>
                              {c.album} · {c.duration}
                            </span>
                            <span style={{ fontSize: 13, fontWeight: 600, color: TONE[c.tone] }}>{c.reason}</span>
                          </span>
                          <input
                            type="radio"
                            name={`cand-${current.id}`}
                            className={ui.radio}
                            checked={(choice[current.id] ?? 0) === i}
                            onChange={() => setChoice({ ...choice, [current.id]: i })}
                          />
                        </label>
                      ))}
                    </fieldset>
                  </>
                )}

                {!resolution && current.kind === 'miss' && (
                  <>
                    <div className={s.notice}>
                      <Icon name="xCircle" strokeWidth={2.4} />
                      No encontramos esta canción en Apple Music. Probá buscarla con otro nombre o dejala fuera.
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                      <label htmlFor="manual" className={ui.eyebrow}>
                        Buscar en Apple Music
                      </label>
                      <div className={s.searchRow}>
                        <input id="manual" type="search" placeholder={`${current.title} ${current.artist}`} />
                        <Button variant="primary" size="lg">
                          Buscar
                        </Button>
                      </div>
                      <span className={ui.muted} style={{ fontSize: 13 }}>
                        Tip: probá solo con el nombre del artista o del álbum.
                      </span>
                    </div>
                  </>
                )}
              </div>
            ) : (
              <div className={s.done}>
                <h2 className={ui.sectionTitle}>No queda nada por revisar</h2>
                <p className={ui.muted}>Todas las canciones de este filtro ya tienen una decisión.</p>
                <Link to={{ name: 'inicio' }} className={buttonClass('secondary')}>
                  Volver al inicio
                </Link>
              </div>
            )}
          </div>
          {bar}
        </section>
      </div>
    </AppShell>
  )
}
