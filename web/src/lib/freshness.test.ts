import { describe, expect, it } from 'vitest'
import { freshness } from './freshness'

const T = 1_700_000_000_000

describe('freshness', () => {
  it('shows connecting before any data arrives', () => {
    expect(freshness(T, 0)).toEqual({ label: 'connecting…', tone: 'stale' })
  })

  it('ticks seconds while live', () => {
    expect(freshness(T + 5_000, T)).toEqual({
      label: 'LIVE • updated 5s ago',
      tone: 'live',
    })
    expect(freshness(T + 20_000, T).tone).toBe('live') // 20 s is still live
  })

  it('goes stale after more than 20 s without data', () => {
    const f = freshness(T + 21_000, T)
    expect(f.tone).toBe('stale')
    expect(f.label).toContain('reconnecting')
  })

  it('shows FINAL for ended sessions regardless of age', () => {
    expect(freshness(T + 999_000, T, 'ended')).toEqual({
      label: 'FINAL',
      tone: 'final',
    })
    expect(freshness(T, 0, 'ended').label).toBe('FINAL')
  })

  it('never shows negative seconds on clock skew', () => {
    expect(freshness(T - 3_000, T)).toEqual({
      label: 'LIVE • updated 0s ago',
      tone: 'live',
    })
  })
})
