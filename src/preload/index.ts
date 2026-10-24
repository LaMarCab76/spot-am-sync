import { contextBridge } from 'electron'

// Keep this surface small: the renderer only needs to know where it runs so it
// can leave room for the native window controls.
const api = {
  platform: process.platform
}

contextBridge.exposeInMainWorld('spotam', api)

export type SpotAmApi = typeof api
