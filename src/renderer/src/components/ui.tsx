import type { ButtonHTMLAttributes, CSSProperties, ReactNode } from 'react'
import { Icon, type IconName } from './Icon'
import s from './ui.module.css'

export const cx = (...parts: Array<string | false | null | undefined>): string => parts.filter(Boolean).join(' ')

type Variant = 'primary' | 'secondary' | 'tonal' | 'ghost' | 'danger'

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant
  size?: 'sm' | 'md' | 'lg'
  icon?: IconName
  block?: boolean
}

export function buttonClass(variant: Variant = 'secondary', size: 'sm' | 'md' | 'lg' = 'md', withIcon = false, block = false) {
  return cx(s.button, s[variant], size !== 'md' && s[size], withIcon && s.withIcon, block && s.block)
}

export function Button({ variant = 'secondary', size = 'md', icon, block, className, children, type = 'button', ...rest }: ButtonProps) {
  return (
    <button type={type} className={cx(buttonClass(variant, size, !!icon, block), className)} {...rest}>
      {icon && <Icon name={icon} size={size === 'lg' ? 20 : 18} strokeWidth={2.4} />}
      {children}
    </button>
  )
}

interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  icon: IconName
  label: string
  filled?: boolean
  active?: boolean
}

export function IconButton({ icon, label, filled, active, className, type = 'button', ...rest }: IconButtonProps) {
  return (
    <button type={type} aria-label={label} className={cx(s.iconButton, filled && s.filled, active && s.active, className)} {...rest}>
      <Icon name={icon} />
    </button>
  )
}

export function iconButtonClass(filled = false, active = false) {
  return cx(s.iconButton, filled && s.filled, active && s.active)
}

interface ChipGroupProps<T extends string> {
  label: string
  options: Array<{ id: T; label: string }>
  value: T
  onChange: (id: T) => void
  className?: string
}

export function ChipGroup<T extends string>({ label, options, value, onChange, className }: ChipGroupProps<T>) {
  return (
    <div role="group" aria-label={label} className={cx(s.chipRow, className)}>
      {options.map((o) => (
        <button key={o.id} type="button" className={s.chip} aria-pressed={value === o.id} onClick={() => onChange(o.id)}>
          {o.label}
        </button>
      ))}
    </div>
  )
}

interface SegmentedProps<T extends string> {
  labelledBy: string
  options: Array<{ id: T; label: string }>
  value: T
  onChange: (id: T) => void
}

export function Segmented<T extends string>({ labelledBy, options, value, onChange }: SegmentedProps<T>) {
  return (
    <div role="group" aria-labelledby={labelledBy} className={s.segmented}>
      {options.map((o) => (
        <button key={o.id} type="button" className={s.segment} aria-pressed={value === o.id} onClick={() => onChange(o.id)}>
          {o.label}
        </button>
      ))}
    </div>
  )
}

export function SwitchVisual({ on }: { on: boolean }) {
  return (
    <span aria-hidden="true" className={cx(s.switch, on && s.switchOn)}>
      <span className={s.switchTrack}>
        <span className={s.switchKnob} />
      </span>
    </span>
  )
}

interface SwitchRowProps {
  title: string
  description?: string
  checked: boolean
  onChange: (next: boolean) => void
}

/** A full-width settings row that toggles on click. */
export function SwitchRow({ title, description, checked, onChange }: SwitchRowProps) {
  return (
    <button type="button" role="switch" aria-checked={checked} className={s.switchRow} onClick={() => onChange(!checked)}>
      <span style={{ flex: '1 1 auto', display: 'flex', flexDirection: 'column', gap: 3 }}>
        <span style={{ fontSize: 15, fontWeight: 600 }}>{title}</span>
        {description && <span style={{ fontSize: 13, color: 'var(--text-3)' }}>{description}</span>}
      </span>
      <SwitchVisual on={checked} />
    </button>
  )
}

export function ProgressBar({ value, label, max = 100 }: { value: number; label: string; max?: number }) {
  const pct = max === 0 ? 0 : Math.min(100, Math.round((value / max) * 100))
  return (
    <div role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={max} aria-valuenow={value} className={s.progress}>
      <div className={s.progressFill} style={{ width: `${pct}%` }} />
    </div>
  )
}

export function Dot({ color, style }: { color: string; style?: CSSProperties }) {
  return <span aria-hidden="true" className={s.dot} style={{ background: color, ...style }} />
}

export function ServiceDot({ service }: { service: 'spotify' | 'apple' }) {
  return <Dot color={service === 'spotify' ? 'var(--spotify)' : 'var(--apple)'} />
}

export function Cover({ src, size, radius = 8, style }: { src: string; size: number; radius?: number; style?: CSSProperties }) {
  return <img src={src} alt="" className={s.cover} style={{ width: size, height: size, borderRadius: radius, ...style }} />
}

export function Badge({ tone, children }: { tone: 'ok' | 'warn' | 'fail' | 'neutral'; children: ReactNode }) {
  const tones = {
    ok: { background: 'var(--accent-tint)', color: 'var(--accent)' },
    warn: { background: 'var(--review-tint)', color: 'var(--review)' },
    fail: { background: 'rgba(255,107,107,0.14)', color: 'var(--danger)' },
    neutral: { background: 'var(--raised)', color: 'var(--text)' }
  }
  return (
    <span className={s.badge} style={tones[tone]}>
      {children}
    </span>
  )
}

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className={s.kbd}>{children}</kbd>
}

export const ui = s
