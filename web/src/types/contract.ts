// Row types mirroring supabase/migrations/0001_init.sql exactly
// (snake_case, as @supabase/supabase-js returns them).

export type Mode = 'game' | 'practice' | 'drill' | 'freethrow'
export type SessionStatus = 'live' | 'ended'
export type Source = 'on_device' | 'manual_correction'
export type Category = 'layup' | 'mid_range' | 'three' | 'free_throw' | 'floater' | 'dunk'

export const ZONES = [
  'paint', 'mid_left', 'mid_right', 'top_key',
  'left_corner_3', 'right_corner_3', 'left_wing_3', 'right_wing_3',
  'top_arc_3', 'ft_line',
] as const
export type Zone = (typeof ZONES)[number]

export interface Player {
  id: string
  user_id: string
  name: string
  jersey_number: number | null
  position: string | null
  created_at: string
}

export interface Session {
  id: string
  user_id: string
  player_id: string
  mode: Mode
  status: SessionStatus
  started_at: string
  ended_at: string | null
  calibration: Record<string, unknown> | null
}

export interface EventRow {
  id: string
  session_id: string
  user_id: string
  ts: number // ms since session start
  wall_clock: string
  player_id: string | null
  confidence: number
  source: Source
  type: 'shot'
  made: boolean
  category: Category
  zone: Zone
  court_x: number // 0..1 (x / 50 ft)
  court_y: number // 0..1 (y / 47 ft)
  release_angle_deg: number | null
  release_time_ms: number | null
}

// session_box_scores view row
export interface BoxScore {
  session_id: string
  player_id: string
  status: SessionStatus
  started_at: string
  fga: number
  fgm: number
  three_pa: number
  three_pm: number
  fta: number
  ftm: number
  pts: number
  fg_pct: number
  three_pct: number
  ft_pct: number
  efg_pct: number
  ts_pct: number
  updated_at: string | null
}

// session_zone_splits view row
export interface ZoneSplit {
  session_id: string
  zone: Zone
  made: number
  attempted: number
  pct: number
}

// player_trends view row
export interface TrendPoint {
  player_id: string
  session_id: string
  started_at: string
  fg_pct: number
  three_pct: number
  ft_pct: number
  efg_pct: number
  ts_pct: number
  pts: number
}
