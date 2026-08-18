import XCTest
@testable import CourtVision

final class ShotEventTrackerTests: XCTestCase {
    private let rim = CGRect(x: 0.45, y: 0.20, width: 0.10, height: 0.06)

    private func moment(_ pts: Double, action: PlayerAction, ball: String? = nil,
                        ballAtRim: Bool = true, h: Homography? = nil) -> Moment {
        let ballBox = ballAtRim ? CGRect(x: 0.485, y: 0.215, width: 0.03, height: 0.03)
                                : CGRect(x: 0.10, y: 0.80, width: 0.03, height: 0.03)
        let p = Moment.PlayerState(trackId: 7, team: nil,
                                   box: CGRect(x: 0.5, y: 0.4, width: 0.06, height: 0.22),
                                   feet: CGPoint(x: 0.53, y: 0.62), xFt: nil, yFt: nil,
                                   action: action, actionConfidence: 0.8, number: nil)
        return Moment(pts: pts, h: h, rim: rim, players: [p],
                      ball: ball.map { Moment.BallState(box: ballBox, label: $0, xFt: nil, yFt: nil) })
    }

    func testAttemptOpensAfterTwoShootingTicksAndIsMadeByBallInBasketAtRim() {
        var t = ShotEventTracker()
        XCTAssertTrue(t.update(moment(0.000, action: .jumpShot)).isEmpty)          // one tick: not yet
        let opened = t.update(moment(0.125, action: .jumpShot))
        XCTAssertEqual(opened.map(\.kind), [.attempt])
        XCTAssertEqual(opened[0].trackId, 7)
        XCTAssertEqual(opened[0].feet, CGPoint(x: 0.53, y: 0.62))
        XCTAssertNil(opened[0].court)                                              // no H
        XCTAssertTrue(t.update(moment(0.5, action: .none, ball: "ball")).isEmpty)
        let made = t.update(moment(1.0, action: .none, ball: "ball-in-basket"))
        XCTAssertEqual(made.map(\.kind), [.made])
        XCTAssertEqual(made[0].pts, 0.125)
        XCTAssertEqual(made[0].resolvedPts, 1.0)
    }

    func testMissedOnWindowExpiryAndBallInBasketFarFromRimDoesNotCount() {
        var t = ShotEventTracker()
        _ = t.update(moment(0.000, action: .layupDunk))
        _ = t.update(moment(0.125, action: .layupDunk))
        XCTAssertTrue(t.update(moment(1.0, action: .none, ball: "ball-in-basket", ballAtRim: false)).isEmpty)
        XCTAssertTrue(t.update(moment(3.0, action: .none)).isEmpty)                // window is 3.0 s, not yet >
        let missed = t.update(moment(3.2, action: .none))
        XCTAssertEqual(missed.map(\.kind), [.missed])
        XCTAssertEqual(missed[0].action, .layupDunk)
    }

    func testCooldownAndCourtProjection() {
        var t = ShotEventTracker()
        let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        _ = t.update(moment(0.000, action: .jumpShot, h: identity))
        let opened = t.update(moment(0.125, action: .jumpShot, h: identity))
        XCTAssertEqual(opened[0].court, CGPoint(x: 0.53, y: 0.62))               // feet through H
        _ = t.update(moment(0.5, action: .none, ball: "ball-in-basket"))          // made at 0.5
        _ = t.update(moment(1.0, action: .jumpShot))                              // inside 2 s cooldown
        XCTAssertTrue(t.update(moment(1.125, action: .jumpShot)).isEmpty)
        _ = t.update(moment(2.5, action: .jumpShot))
        XCTAssertEqual(t.update(moment(2.625, action: .jumpShot)).map(\.kind), [.attempt])
    }
}
