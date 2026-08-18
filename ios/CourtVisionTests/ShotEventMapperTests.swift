import XCTest
@testable import CourtVision

final class ShotEventMapperTests: XCTestCase {
    private func session(_ mode: SessionMode, teamId: UUID? = nil) -> Session {
        Session(id: UUID(), userId: nil, playerId: UUID(), mode: mode, status: .live,
                startedAt: nil, endedAt: nil, calibration: nil, teamA: nil, teamB: nil, teamId: teamId)
    }
    private func shot(_ kind: ShotEvent.Kind, action: PlayerAction = .jumpShot, pts: Double = 12.0) -> ShotEvent {
        ShotEvent(kind: kind, pts: pts, resolvedPts: pts + 1.5, trackId: 4, action: action,
                  feet: CGPoint(x: 0.5, y: 0.5), court: nil, confidence: 0.8)
    }

    func testThreeFromTopOfArc() {
        let s = session(.practice)
        let row = ShotEventMapper.eventRow(shot(.made), court: CGPoint(x: 25, y: 30), session: s,
                                           sessionStartPts: 2.0, playerId: s.playerId, team: nil)!
        XCTAssertEqual(row.sessionId, s.id)
        XCTAssertEqual(row.playerId, s.playerId)
        XCTAssertEqual(row.ts, 10_000)                       // (12.0 − 2.0) s → ms
        XCTAssertTrue(row.made)
        XCTAssertEqual(row.category, .three)
        XCTAssertEqual(row.zone, .top_arc_3)
        XCTAssertEqual(row.courtX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(row.courtY, 30.0 / 47.0, accuracy: 1e-9)
        XCTAssertEqual(row.confidence, 0.8, accuracy: 1e-6)
        XCTAssertNil(row.team)
        XCTAssertEqual(row.type, "shot")
    }

    func testLayupNeverClaimsDunkAndFreeThrowModeWins() {
        let layup = ShotEventMapper.eventRow(shot(.missed, action: .layupDunk), court: CGPoint(x: 25, y: 7),
                                             session: session(.game), sessionStartPts: 0, playerId: nil, team: "B")!
        XCTAssertEqual(layup.category, .layup)                // ponytail: model can't split layup from dunk
        XCTAssertEqual(layup.zone, .paint)
        XCTAssertFalse(layup.made)
        XCTAssertEqual(layup.team, "B")
        let ft = ShotEventMapper.eventRow(shot(.made), court: CGPoint(x: 25, y: 19),
                                          session: session(.freethrow), sessionStartPts: 0, playerId: nil, team: nil)!
        XCTAssertEqual(ft.category, .free_throw)
        XCTAssertEqual(ft.zone, .ft_line)
    }

    func testAttemptKindProducesNoRow() {
        XCTAssertNil(ShotEventMapper.eventRow(shot(.attempt), court: CGPoint(x: 25, y: 20),
                                              session: session(.practice), sessionStartPts: 0, playerId: nil, team: nil))
    }

    func testRosterMapIsTeamScopedByJerseyNumber() {
        let team = UUID(), other = UUID()
        let p = { (n: Int?, t: UUID?) in Player(id: UUID(), userId: nil, name: "p", jerseyNumber: n, position: nil, teamId: t, createdAt: nil) }
        let a = p(23, team), b = p(23, other), c = p(nil, team)
        let map = RosterMap.build(players: [a, b, c], teamId: team)
        XCTAssertEqual(map, ["23": a.id])
    }
}
