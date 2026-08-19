import XCTest
@testable import CourtVision

final class ShotEventTrackerTests: XCTestCase {
    private let rimA = CGRect(x: 0.10, y: 0.20, width: 0.10, height: 0.06)
    private let rimB = CGRect(x: 0.80, y: 0.22, width: 0.10, height: 0.06)

    /// One shooter (track 7) near end A. `ball` = label at the given rim.
    private func moment(_ pts: Double, action: PlayerAction, ball: String? = nil, ballAt: String = "A",
                        h: Homography? = nil, rims: [String]? = nil, shooterX: CGFloat = 0.25) -> Moment {
        let all = ["A": rimA, "B": rimB]
        let ends = rims ?? ["A", "B"]
        let ballRim = all[ballAt]!
        let ballBox = CGRect(x: ballRim.midX - 0.015, y: ballRim.midY - 0.015, width: 0.03, height: 0.03)
        let p = Moment.PlayerState(trackId: 7, team: nil,
                                   box: CGRect(x: shooterX, y: 0.4, width: 0.06, height: 0.22),
                                   feet: CGPoint(x: shooterX + 0.03, y: 0.62), xFt: nil, yFt: nil,
                                   action: action, actionConfidence: 0.8, number: nil)
        return Moment(pts: pts, h: h, rims: all.filter { ends.contains($0.key) }, players: [p],
                      ball: ball.map { Moment.BallState(box: ballBox, label: $0, xFt: nil, yFt: nil) })
    }

    func testAttemptOpensAfterTwoShootingTicksAndIsMadeAtTheRimTheBallEntered() {
        var t = ShotEventTracker()
        XCTAssertTrue(t.update(moment(0.000, action: .jumpShot)).isEmpty)          // one tick: not yet
        let opened = t.update(moment(0.125, action: .jumpShot))
        XCTAssertEqual(opened.map(\.kind), [.attempt])
        XCTAssertEqual(opened[0].trackId, 7)
        XCTAssertEqual(opened[0].feet, CGPoint(x: 0.28, y: 0.62))
        XCTAssertNil(opened[0].court)                                              // no H
        XCTAssertEqual(opened[0].end, "A")                                         // nearest rim to the shooter
        XCTAssertTrue(t.update(moment(0.5, action: .none, ball: "ball")).isEmpty)
        let made = t.update(moment(1.0, action: .none, ball: "ball-in-basket", ballAt: "B"))
        XCTAssertEqual(made.map(\.kind), [.made])
        XCTAssertEqual(made[0].end, "B")                                           // the ball told us which hoop
        XCTAssertEqual(made[0].pts, 0.125)
        XCTAssertEqual(made[0].resolvedPts, 1.0)
    }

    func testMissedOnWindowExpiryKeepsNearestEndAndFarBallDoesNotCount() {
        var t = ShotEventTracker()
        _ = t.update(moment(0.000, action: .layupDunk, shooterX: 0.70))
        _ = t.update(moment(0.125, action: .layupDunk, shooterX: 0.70))
        // ball-in-basket far from any rim (ball drawn at rim A but rim A not locked this tick)
        XCTAssertTrue(t.update(moment(1.0, action: .none, ball: "ball-in-basket", ballAt: "A", rims: ["B"])).isEmpty)
        XCTAssertTrue(t.update(moment(3.0, action: .none)).isEmpty)                // window 3.0 s, not yet >
        let missed = t.update(moment(3.2, action: .none))
        XCTAssertEqual(missed.map(\.kind), [.missed])
        XCTAssertEqual(missed[0].action, .layupDunk)
        XCTAssertEqual(missed[0].end, "B")
    }

    func testFreshStartSupersedesAnEarlyOneAndCooldownAfterResolution() {
        var t = ShotEventTracker()
        let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        _ = t.update(moment(0.000, action: .jumpShot, h: identity))
        let first = t.update(moment(0.125, action: .jumpShot, h: identity))          // early (set-position) start
        XCTAssertEqual(first[0].court, CGPoint(x: 0.28, y: 0.62))                    // feet through H
        _ = t.update(moment(0.5, action: .none))
        _ = t.update(moment(0.75, action: .jumpShot))                                // real shot 0.75 s later…
        let superseded = t.update(moment(0.875, action: .jumpShot))
        XCTAssertEqual(superseded.map(\.kind), [.missed, .attempt])                  // old closed as missed, new opened
        XCTAssertEqual(superseded[1].pts, 0.875)
        _ = t.update(moment(1.2, action: .none, ball: "ball-in-basket"))             // made at 1.2
        _ = t.update(moment(1.4, action: .jumpShot))                                 // inside the 0.5 s cooldown
        XCTAssertTrue(t.update(moment(1.5, action: .jumpShot)).isEmpty)
        _ = t.update(moment(1.8, action: .jumpShot))
        XCTAssertEqual(t.update(moment(1.9, action: .jumpShot)).map(\.kind), [.attempt])
    }
}
