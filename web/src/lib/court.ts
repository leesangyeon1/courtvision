// Shared half-court geometry (feet). Must match the iOS app and the SQL contract.
// Half court: 50 wide x 47 deep, origin at the left end of the baseline,
// rim center at (25, 5.25). Normalized court_x = x/50, court_y = y/47.

import type { Zone } from '../types/contract'
import { ZONES } from '../types/contract'

export const COURT_W = 50
export const COURT_H = 47
export const RIM_X = 25
export const RIM_Y = 5.25
export const FT_LINE_Y = 19
export const FT_CIRCLE_R = 6
export const KEY_HALF_W = 8 // paint half-width
export const THREE_R = 23.75
export const CORNER_X = 3 // corner-three lines at x<=3 and x>=47
export const CORNER_MAX_Y = 14

export const distFromRim = (x: number, y: number): number =>
  Math.hypot(x - RIM_X, y - RIM_Y)

export function isThree(x: number, y: number): boolean {
  if (y <= CORNER_MAX_Y) return x <= CORNER_X || x >= COURT_W - CORNER_X
  return distFromRim(x, y) >= THREE_R
}

/** Zone classification per the shared contract. Coordinates in feet. */
export function zoneFor(x: number, y: number, isFreeThrow = false): Zone {
  if (isFreeThrow) return 'ft_line'
  if (isThree(x, y)) {
    if (y <= CORNER_MAX_Y) return x < RIM_X ? 'left_corner_3' : 'right_corner_3'
    if (Math.abs(x - RIM_X) <= 9) return 'top_arc_3'
    return x < RIM_X ? 'left_wing_3' : 'right_wing_3'
  }
  if (Math.abs(x - RIM_X) <= KEY_HALF_W) return y <= FT_LINE_Y ? 'paint' : 'top_key'
  return x < RIM_X ? 'mid_left' : 'mid_right'
}

export interface ZoneCell { x: number; y: number; w: number; h: number }

/**
 * The 10 zone regions as grid cells (feet), for the heatmap.
 * The 9 spatial zones tile the court; ft_line is a band on the FT line
 * (free-throw shots are classified by mode, not position) drawn on top.
 */
export function zoneRegions(step = 1): Record<Zone, ZoneCell[]> {
  const regions = Object.fromEntries(ZONES.map((z) => [z, []])) as Record<Zone, ZoneCell[]>
  for (let y = 0; y < COURT_H; y += step) {
    for (let x = 0; x < COURT_W; x += step) {
      regions[zoneFor(x + step / 2, y + step / 2)].push({ x, y, w: step, h: step })
    }
  }
  regions.ft_line.push({ x: RIM_X - FT_CIRCLE_R, y: FT_LINE_Y - 1, w: FT_CIRCLE_R * 2, h: 2 })
  return regions
}

/** y where the corner-three straight line meets the 23.75 ft arc. */
export const ARC_JOIN_Y =
  RIM_Y + Math.sqrt(THREE_R * THREE_R - (RIM_X - CORNER_X) * (RIM_X - CORNER_X))

/** SVG path for the court lines in a viewBox of 0 0 50 47 (y = depth from baseline). */
export const THREE_POINT_PATH =
  `M ${CORNER_X} 0 L ${CORNER_X} ${ARC_JOIN_Y} ` +
  `A ${THREE_R} ${THREE_R} 0 0 0 ${COURT_W - CORNER_X} ${ARC_JOIN_Y} ` +
  `L ${COURT_W - CORNER_X} 0`

/** Label anchor (feet) for each zone. */
export const ZONE_ANCHORS: Record<Zone, [number, number]> = {
  paint: [25, 11.5],
  top_key: [25, 22.5],
  mid_left: [11, 10],
  mid_right: [39, 10],
  left_corner_3: [1.5, 7],
  right_corner_3: [48.5, 7],
  left_wing_3: [7, 23],
  right_wing_3: [43, 23],
  top_arc_3: [25, 33],
  ft_line: [25, 17.8],
}
