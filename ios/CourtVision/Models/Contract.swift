import Foundation

// Codable mirrors of supabase/migrations/0001_init.sql — the single source of
// truth for the metric contract. Explicit snake_case CodingKeys everywhere; no
// global key strategy so wire names are visible at the definition site.

enum SessionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case game, practice, drill, freethrow
}

enum SessionStatus: String, Codable, Hashable, Sendable {
    case live, ended
}

enum ShotCategory: String, Codable, Hashable, Sendable {
    case layup, mid_range, three, free_throw, floater, dunk
}

enum ShotZone: String, Codable, Hashable, Sendable {
    case paint, mid_left, mid_right, top_key
    case left_corner_3, right_corner_3, left_wing_3, right_wing_3
    case top_arc_3, ft_line
}

struct Player: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var userId: UUID?
    var name: String
    var jerseyNumber: Int?
    var position: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case jerseyNumber = "jersey_number"
        case position
        case createdAt = "created_at"
    }
}

/// Mirrors sessions.calibration jsonb:
/// {"homography": [9 floats, row-major 3x3], "imagePoints": [[x,y]...], "courtPoints": [[x,y]...]}
struct Calibration: Codable, Hashable, Sendable {
    var homography: [Double]
    var imagePoints: [[Double]]   // buffer-space (capture-device) normalized coords, top-left origin
    var courtPoints: [[Double]]   // feet on the standard half court
}

struct Session: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var userId: UUID?
    var playerId: UUID
    var mode: SessionMode
    var status: SessionStatus
    var startedAt: Date?
    var endedAt: Date?
    var calibration: Calibration?
    /// Team names for game sessions (nil otherwise). Team A attacks rim 1 by
    /// default; the calibration screen can swap sides.
    var teamA: String?
    var teamB: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case playerId = "player_id"
        case mode
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case calibration
        case teamA = "team_a"
        case teamB = "team_b"
    }
}

/// One row per detected shot. `id` is client-generated so offline-queue replays
/// are idempotent (upsert on id, ignore duplicates). Optional fields are omitted
/// from the payload when nil so DB defaults (user_id, wall_clock) apply.
struct EventRow: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var sessionId: UUID
    var userId: UUID?
    var ts: Int                    // ms since session start
    var wallClock: Date?
    var playerId: UUID?
    var confidence: Double         // 0..1
    var source: String = "on_device"
    var type: String = "shot"
    var made: Bool
    var category: ShotCategory
    var zone: ShotZone
    var courtX: Double             // 0..1, relative to the attacked hoop's half
    var courtY: Double             // 0..1, relative to the attacked hoop's half
    var releaseAngleDeg: Double?
    var releaseTimeMs: Double?
    /// "A"/"B" in game sessions (which team attacked the rim); nil otherwise.
    var team: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case userId = "user_id"
        case ts
        case wallClock = "wall_clock"
        case playerId = "player_id"
        case confidence, source, type, made, category, zone
        case courtX = "court_x"
        case courtY = "court_y"
        case releaseAngleDeg = "release_angle_deg"
        case releaseTimeMs = "release_time_ms"
        case team
    }
}

/// Row of the server-derived session_box_scores view (dashboard math lives in
/// SQL, never reimplemented client-side).
struct BoxScoreRow: Codable, Hashable, Sendable {
    var sessionId: UUID
    var playerId: UUID
    var status: SessionStatus
    var startedAt: Date?
    var fga: Int
    var fgm: Int
    var threePa: Int
    var threePm: Int
    var fta: Int
    var ftm: Int
    var pts: Int
    var fgPct: Double
    var threePct: Double
    var ftPct: Double
    var efgPct: Double
    var tsPct: Double
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case playerId = "player_id"
        case status
        case startedAt = "started_at"
        case fga, fgm
        case threePa = "three_pa"
        case threePm = "three_pm"
        case fta, ftm, pts
        case fgPct = "fg_pct"
        case threePct = "three_pct"
        case ftPct = "ft_pct"
        case efgPct = "efg_pct"
        case tsPct = "ts_pct"
        case updatedAt = "updated_at"
    }
}

/// Row of the server-derived session_zone_splits view.
struct ZoneSplitRow: Codable, Hashable, Sendable {
    var sessionId: UUID
    var zone: ShotZone
    var made: Int
    var attempted: Int
    var pct: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case zone, made, attempted, pct
    }
}
