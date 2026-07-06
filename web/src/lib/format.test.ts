import { describe, expect, it } from 'vitest'
import { fmtDate, fmtPct } from './format'

describe('fmtPct', () => {
  it('formats a ratio to one decimal with a % sign', () => {
    expect(fmtPct(0.5102)).toBe('51.0%')
    expect(fmtPct(0)).toBe('0.0%')
    expect(fmtPct(1)).toBe('100.0%')
    expect(fmtPct(0.4444)).toBe('44.4%')
  })
})

describe('fmtDate', () => {
  it('renders a non-empty locale date for an ISO timestamp', () => {
    expect(fmtDate('2026-07-05T15:00:00Z').length).toBeGreaterThan(0)
  })
})
