import type { Direction, ServiceId } from '../store/types'

const numbers = new Intl.NumberFormat('es-AR')

export const fmt = (n: number): string => numbers.format(n)

export const serviceName = (id: ServiceId): string => (id === 'spotify' ? 'Spotify' : 'Apple Music')

export function directionEnds(direction: Direction): { from: ServiceId; to: ServiceId } {
  return direction === 'a2s' ? { from: 'apple', to: 'spotify' } : { from: 'spotify', to: 'apple' }
}

export function directionLabel(direction: Direction): string {
  if (direction === 'both') return 'Spotify ⇄ Apple Music'
  const { from, to } = directionEnds(direction)
  return `${serviceName(from)} → ${serviceName(to)}`
}

export const songs = (n: number): string => `${fmt(n)} ${n === 1 ? 'canción' : 'canciones'}`

export function clockTime(date: Date): string {
  return date.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', hour12: false })
}
