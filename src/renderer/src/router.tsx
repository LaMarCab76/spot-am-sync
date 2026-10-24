import { createContext, useCallback, useContext, useEffect, useState, type AnchorHTMLAttributes, type ReactNode } from 'react'

export type Route =
  | { name: 'conectar' }
  | { name: 'inicio' }
  | { name: 'playlist'; id: string }
  | { name: 'nueva' }
  | { name: 'revisar' }
  | { name: 'historial' }
  | { name: 'ajustes'; section?: string }

export function routePath(route: Route): string {
  switch (route.name) {
    case 'playlist':
      return `/playlist/${route.id}`
    case 'ajustes':
      return route.section ? `/ajustes/${route.section}` : '/ajustes'
    default:
      return `/${route.name}`
  }
}

export function parseRoute(hash: string, fallback: Route): Route {
  const [name, arg] = hash.replace(/^#\/?/, '').split('/')
  switch (name) {
    case 'conectar':
    case 'inicio':
    case 'nueva':
    case 'revisar':
    case 'historial':
      return { name }
    case 'playlist':
      return arg ? { name: 'playlist', id: arg } : fallback
    case 'ajustes':
      return { name: 'ajustes', section: arg || undefined }
    default:
      return fallback
  }
}

interface RouterValue {
  route: Route
  navigate: (route: Route) => void
}

const RouterContext = createContext<RouterValue | null>(null)

export function RouterProvider({ fallback, children }: { fallback: Route; children: ReactNode }) {
  const [route, setRoute] = useState<Route>(() => parseRoute(window.location.hash, fallback))

  useEffect(() => {
    const onHash = () => setRoute(parseRoute(window.location.hash, fallback))
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [fallback])

  const navigate = useCallback((next: Route) => {
    window.location.hash = routePath(next)
  }, [])

  return <RouterContext.Provider value={{ route, navigate }}>{children}</RouterContext.Provider>
}

export function useRouter(): RouterValue {
  const value = useContext(RouterContext)
  if (!value) throw new Error('useRouter must be used inside <RouterProvider>')
  return value
}

type LinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href'> & { to: Route }

export function Link({ to, ...rest }: LinkProps) {
  return <a href={`#${routePath(to)}`} {...rest} />
}
