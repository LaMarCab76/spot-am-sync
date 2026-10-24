import '@fontsource-variable/inter'
import './styles/global.css'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { StoreProvider } from './store/StoreProvider'

// Lets the CSS leave room for the native window controls of each platform.
document.documentElement.dataset.platform = window.spotam?.platform ?? 'web'

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <StoreProvider>
      <App />
    </StoreProvider>
  </StrictMode>
)
