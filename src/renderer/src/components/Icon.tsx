import type { CSSProperties, ReactNode } from 'react'

const stroke = (paths: ReactNode) => ({ fill: false as const, paths })
const solid = (paths: ReactNode) => ({ fill: true as const, paths })

const ICONS = {
  sync: stroke(
    <>
      <path d="M20 11a8 8 0 0 0-14.9-3.9" />
      <path d="M4 4v4h4" />
      <path d="M4 13a8 8 0 0 0 14.9 3.9" />
      <path d="M20 20v-4h-4" />
    </>
  ),
  home: stroke(<path d="M4 11 12 4l8 7v9h-5v-6H9v6H4z" />),
  homeFilled: solid(<path d="M4 11 12 4l8 7v9h-5v-6H9v6H4z" />),
  search: stroke(
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.5-3.5" />
    </>
  ),
  user: stroke(
    <>
      <circle cx="12" cy="8" r="4" />
      <path d="M4 20c1.5-4 4.8-6 8-6s6.5 2 8 6" />
    </>
  ),
  plus: stroke(
    <>
      <path d="M12 5v14" />
      <path d="M5 12h14" />
    </>
  ),
  alert: stroke(
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7.5v5" />
      <path d="M12 16.2v.3" />
    </>
  ),
  history: stroke(
    <>
      <path d="M3.5 12a8.5 8.5 0 1 0 2.5-6" />
      <path d="M3 4v4h4" />
      <path d="M12 8v4l3 2" />
    </>
  ),
  chevronLeft: stroke(<path d="m15 18-6-6 6-6" />),
  chevronRight: stroke(<path d="m9 18 6-6-6-6" />),
  chevronDown: stroke(<path d="m6 9 6 6 6-6" />),
  share: stroke(
    <>
      <path d="M12 15V4" />
      <path d="m8 8 4-4 4 4" />
      <path d="M5 12v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6" />
    </>
  ),
  more: solid(
    <>
      <circle cx="5" cy="12" r="1.8" />
      <circle cx="12" cy="12" r="1.8" />
      <circle cx="19" cy="12" r="1.8" />
    </>
  ),
  swap: stroke(
    <>
      <path d="M4 8h15" />
      <path d="m15 4 4 4-4 4" />
      <path d="M20 16H5" />
      <path d="m9 20-4-4 4-4" />
    </>
  ),
  check: stroke(<path d="m5 12.5 4.5 4.5L19 7.5" />),
  checkCircle: stroke(
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m8 12.5 2.8 2.8L16.5 9.5" />
    </>
  ),
  x: stroke(
    <>
      <path d="M6 6l12 12" />
      <path d="M18 6 6 18" />
    </>
  ),
  xCircle: stroke(
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m9 9 6 6" />
      <path d="m15 9-6 6" />
    </>
  ),
  minusCircle: stroke(
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M8 12h8" />
    </>
  ),
  minus: stroke(<path d="M7 12h10" />),
  pause: solid(
    <>
      <rect x="6.5" y="5" width="4" height="14" rx="1.2" />
      <rect x="13.5" y="5" width="4" height="14" rx="1.2" />
    </>
  ),
  play: solid(<path d="M8 5.5v13l11-6.5z" />),
  queue: stroke(
    <>
      <path d="M4 6h12" />
      <path d="M4 12h12" />
      <path d="M4 18h7" />
      <path d="M17 15v6" />
      <path d="M14 18h6" />
    </>
  ),
  sliders: stroke(
    <>
      <path d="M4 7h9" />
      <path d="M18 7h2" />
      <path d="M4 17h3" />
      <path d="M12 17h8" />
      <circle cx="15.5" cy="7" r="2.5" />
      <circle cx="9.5" cy="17" r="2.5" />
    </>
  ),
  arrowRight: stroke(
    <>
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </>
  ),
  clock: stroke(
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </>
  ),
  download: stroke(
    <>
      <path d="M12 4v11" />
      <path d="m8 11 4 4 4-4" />
      <path d="M5 20h14" />
    </>
  ),
  undo: stroke(
    <>
      <path d="M9 14 4 9l5-5" />
      <path d="M4 9h10a6 6 0 0 1 0 12h-3" />
    </>
  ),
  lock: stroke(
    <>
      <rect x="5" y="11" width="14" height="10" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </>
  ),
  spinner: stroke(<path d="M12 3a9 9 0 1 0 9 9" />)
}

export type IconName = keyof typeof ICONS

interface IconProps {
  name: IconName
  size?: number
  strokeWidth?: number
  className?: string
  style?: CSSProperties
  /** Accessible name; without it the icon is decorative. */
  label?: string
}

export function Icon({ name, size = 20, strokeWidth = 2.2, className, style, label }: IconProps) {
  const icon = ICONS[name]
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={icon.fill ? 'currentColor' : 'none'}
      stroke={icon.fill ? 'none' : 'currentColor'}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={{ flex: 'none', ...style }}
      role={label ? 'img' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {icon.paths}
    </svg>
  )
}
