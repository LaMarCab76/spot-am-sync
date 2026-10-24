import { defineConfig } from 'electron-vite'
import react from '@vitejs/plugin-react'
import type { Plugin } from 'vite'

// The renderer ships with a strict Content-Security-Policy. During `npm run dev`
// the React refresh preamble is injected as an inline script and hot reload
// talks over a websocket, so the dev server relaxes the policy for that case only.
function devCsp(): Plugin {
  return {
    name: 'spot-am-dev-csp',
    apply: 'serve',
    transformIndexHtml(html) {
      return html
        .replace("script-src 'self'", "script-src 'self' 'unsafe-inline'")
        .replace("connect-src 'self'", "connect-src 'self' ws:")
    }
  }
}

export default defineConfig({
  main: {},
  preload: {},
  renderer: {
    base: './',
    build: { minify: true },
    plugins: [react(), devCsp()]
  }
})
