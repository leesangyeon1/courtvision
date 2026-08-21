import CoreGraphics
import Foundation

/// Roster lookup for game sessions: jersey number → `players.id`, restricted
/// to the session's team. Non-game sessions attribute every shot to the
/// session player (see `RecordModel.emit`).
enum RosterMap {
    static func build(players: [Player], teamId: UUID?) -> [String: UUID] {
        var map: [String: UUID] = [:]
        for p in players where p.teamId == teamId {
            if let n = p.jerseyNumber { map[String(n)] = p.id }
        }
        return map
    }
}

/// A resolved shot with a court location → one row of the existing event
/// contract. Category / zone math is `ZoneMapper` (shared with the web and
/// simulate_session.py); nothing is reimplemented here.
enum ShotEventMapper {
    /// `sessionStartPts` is the first engine tick's pts; `ts` is ms since then.
    /// `mirror`: the shot targeted the far hoop of a full-court fit — fold it
    /// into the attacked hoop's half (contract: coords relative to that half).
    static func eventRow(_ e: ShotEvent, court: CGPoint, session: Session, sessionStartPts: Double,
                         playerId: UUID?, team: String?, mirror: Bool = false) -> EventRow? {
        guard e.kind != .attempt else { return nil }
        var x = Double(court.x), y = Double(court.y)
        if mirror { x = ZoneMapper.courtWidthFt - x; y = ZoneMapper.fullCourtLengthFt - y }
        let freeThrow = session.mode == .freethrow
        let n = ZoneMapper.normalized(xFt: x, yFt: y)
        return EventRow(
            id: UUID(),
            sessionId: session.id,
            userId: nil,
            ts: max(0, Int(((e.pts - sessionStartPts) * 1000).rounded())),
            wallClock: nil,
            playerId: playerId,
            confidence: Double(e.confidence),
            made: e.kind == .made,
            // ponytail: the model's one class covers layup AND dunk — never claim dunk.
            category: ZoneMapper.category(xFt: x, yFt: y, freeThrowMode: freeThrow, releaseAtRim: false),
            zone: ZoneMapper.zone(xFt: x, yFt: y, freeThrow: freeThrow),
            courtX: n.x,
            courtY: n.y,
            releaseAngleDeg: nil,
            releaseTimeMs: nil,
            team: team)
    }
}
