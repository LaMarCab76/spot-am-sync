import { createContext, useContext, useEffect, useReducer, type Dispatch, type ReactNode } from 'react'
import { createInitialState } from '../data/mock'
import { reducer, type Action } from './reducer'
import type { AppState } from './types'

const STORAGE_KEY = 'spotam:prefs:v1'
const TICK_MS = 500

type Persisted = Pick<AppState, 'onboarded' | 'settings'> & { appleConnected: boolean }

function loadInitialState(): AppState {
  const state = createInitialState()
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return state
    const saved = JSON.parse(raw) as Partial<Persisted>
    return {
      ...state,
      onboarded: saved.onboarded ?? state.onboarded,
      settings: { ...state.settings, ...saved.settings },
      accounts: saved.appleConnected
        ? { ...state.accounts, apple: { ...state.accounts.apple, status: 'connected' } }
        : state.accounts
    }
  } catch {
    return state
  }
}

const StateContext = createContext<AppState | null>(null)
const DispatchContext = createContext<Dispatch<Action> | null>(null)

export function StoreProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, undefined, loadInitialState)

  // Simulated sync progress until the real services report it.
  const running = state.job?.state === 'running'
  useEffect(() => {
    if (!running) return
    const id = window.setInterval(() => dispatch({ type: 'sync/tick', now: new Date() }), TICK_MS)
    return () => window.clearInterval(id)
  }, [running])

  const appleConnected = state.accounts.apple.status === 'connected'
  useEffect(() => {
    const saved: Persisted = { onboarded: state.onboarded, settings: state.settings, appleConnected }
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(saved))
    } catch {
      // Storage can be unavailable (private mode); preferences then last for the session.
    }
  }, [state.onboarded, state.settings, appleConnected])

  return (
    <StateContext.Provider value={state}>
      <DispatchContext.Provider value={dispatch}>{children}</DispatchContext.Provider>
    </StateContext.Provider>
  )
}

export function useAppState(): AppState {
  const state = useContext(StateContext)
  if (!state) throw new Error('useAppState must be used inside <StoreProvider>')
  return state
}

export function useDispatch(): Dispatch<Action> {
  const dispatch = useContext(DispatchContext)
  if (!dispatch) throw new Error('useDispatch must be used inside <StoreProvider>')
  return dispatch
}
