export interface Freshness {
  label: string
  tone: 'live' | 'stale' | 'final'
}

/**
 * Pure staleness logic for the freshness badge.
 * lastUpdatedAt = epoch ms of the last successful data receipt (0 = never).
 */
export function freshness(
  now: number,
  lastUpdatedAt: number,
  status?: string,
): Freshness {
  if (status === 'ended') return { label: 'FINAL', tone: 'final' }
  if (!lastUpdatedAt) return { label: 'connecting…', tone: 'stale' }
  const s = Math.max(0, Math.floor((now - lastUpdatedAt) / 1000))
  if (s > 20) return { label: `reconnecting… ${s}s since last update`, tone: 'stale' }
  return { label: `LIVE • updated ${s}s ago`, tone: 'live' }
}
