import { describe, expect, it } from 'vitest'
import { isThree, zoneFor } from './court'

describe('isThree', () => {
  it('uses the straight corner lines at 14 ft or less', () => {
    expect(isThree(2, 8)).toBe(true)
    expect(isThree(3, 10)).toBe(true) // on the corner line
    expect(isThree(48, 8)).toBe(true)
    expect(isThree(4, 10)).toBe(false) // inside the line, short of the arc
  })

  it('uses the 23.75 ft arc above 14 ft', () => {
    expect(isThree(25, 29)).toBe(true) // exactly 23.75 ft from the rim
    expect(isThree(25, 28.9)).toBe(false)
  })
})

describe('zoneFor', () => {
  it('classifies the simulator reference shots (tools/simulate_session.py)', () => {
    expect(zoneFor(25, 7)).toBe('paint')
    expect(zoneFor(12, 10)).toBe('mid_left')
    expect(zoneFor(38, 10)).toBe('mid_right')
    expect(zoneFor(25, 21)).toBe('top_key')
    expect(zoneFor(2, 8)).toBe('left_corner_3')
    expect(zoneFor(48, 8)).toBe('right_corner_3')
    expect(zoneFor(6, 24)).toBe('left_wing_3')
    expect(zoneFor(43, 22)).toBe('right_wing_3')
    expect(zoneFor(25, 30)).toBe('top_arc_3')
  })

  it('free-throw mode wins over position', () => {
    expect(zoneFor(25, 19, true)).toBe('ft_line')
    expect(zoneFor(2, 8, true)).toBe('ft_line')
  })

  it('handles boundary lines per the contract rule order', () => {
    expect(zoneFor(33, 19)).toBe('paint') // paint edges inclusive
    expect(zoneFor(33, 19.01)).toBe('top_key')
    expect(zoneFor(33.01, 10)).toBe('mid_right')
    expect(zoneFor(34, 29)).toBe('top_arc_3') // |x - 25| = 9 inclusive
    expect(zoneFor(34.2, 29.5)).toBe('right_wing_3')
  })
})
