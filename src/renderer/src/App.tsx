import { RouterProvider, useRouter, type Route } from './router'
import { useAppState } from './store/StoreProvider'
import { Ajustes } from './screens/Ajustes'
import { Conectar } from './screens/Conectar'
import { Historial } from './screens/Historial'
import { Inicio } from './screens/Inicio'
import { NuevaSync } from './screens/NuevaSync'
import { Playlist } from './screens/Playlist'
import { Revisar } from './screens/Revisar'

const START: Route = { name: 'inicio' }
const ONBOARDING: Route = { name: 'conectar' }

function Screen() {
  const { route } = useRouter()
  switch (route.name) {
    case 'conectar':
      return <Conectar />
    case 'inicio':
      return <Inicio />
    case 'playlist':
      return <Playlist key={route.id} id={route.id} />
    case 'nueva':
      return <NuevaSync />
    case 'revisar':
      return <Revisar />
    case 'historial':
      return <Historial />
    case 'ajustes':
      return <Ajustes section={route.section} />
  }
}

export function App() {
  const { onboarded } = useAppState()
  return (
    <RouterProvider fallback={onboarded ? START : ONBOARDING}>
      <Screen />
    </RouterProvider>
  )
}
