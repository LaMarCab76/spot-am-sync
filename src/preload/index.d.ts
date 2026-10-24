export {}

declare global {
  interface Window {
    // Undefined when the renderer is opened in a regular browser.
    spotam?: {
      platform: string
    }
  }
}
