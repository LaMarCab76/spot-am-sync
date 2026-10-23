import { useState, type ReactNode } from 'react'
import { Sidebar } from './Sidebar'
import { SyncBar } from './SyncBar'
import { TopBar } from './TopBar'
import s from './shell.module.css'

interface AppShellProps {
  children: ReactNode
  /** Floating bar at the bottom of the panel. Defaults to the sync progress bar. */
  bar?: ReactNode
}

export function AppShell({ children, bar }: AppShellProps) {
  const [query, setQuery] = useState('')
  return (
    <div className={s.shell}>
      <TopBar query={query} onQuery={setQuery} />
      <div className={s.body}>
        <Sidebar query={query} />
        <main className={s.panel}>
          {children}
          {bar === undefined ? <SyncBar /> : bar}
        </main>
      </div>
    </div>
  )
}

export function PanelScroll({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={`scroll ${s.panelScroll} ${className ?? ''}`}>{children}</div>
}
