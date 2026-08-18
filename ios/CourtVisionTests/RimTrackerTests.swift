import XCTest
@testable import CourtVision

final class RimTrackerTests: XCTestCase {
    private let hoop = CGRect(x: 0.45, y: 0.20, width: 0.10, height: 0.06)
    private let sideHoop = CGRect(x: 0.05, y: 0.15, width: 0.10, height: 0.06)

    func testAnchorGateKeepsTheDesignatedHoop() {
        var t = RimTracker()
        t.update(candidates: [sideHoop, hoop], attackingTeam: "A", pts: 0)   // no anchor → first
        XCTAssertEqual(t.rim?.midX ?? 0, sideHoop.midX, accuracy: 1e-9)
        t.designate(at: CGPoint(x: 0.5, y: 0.23), attackingTeam: "A", pts: 1) // snaps to hoop
        XCTAssertEqual(t.rim?.midX ?? 0, hoop.midX, accuracy: 1e-9)
        XCTAssertEqual(t.anchors["A"], CGPoint(x: 0.5, y: 0.23))
        t.update(candidates: [sideHoop], attackingTeam: "A", pts: 2)          // side hoop alone must not steal
        XCTAssertEqual(t.rim?.midX ?? 0, hoop.midX, accuracy: 1e-9)
        XCTAssertEqual(t.state, .tracking)
    }

    func testOcclusionToleranceThenReacquireAndRelock() {
        var t = RimTracker()
        t.update(candidates: [hoop], attackingTeam: "A", pts: 0)
        for s in 1...4 { t.update(candidates: [], attackingTeam: "A", pts: Double(s)) }
        XCTAssertEqual(t.state, .tracking)          // 4.0 s of occlusion is tolerated
        t.update(candidates: [], attackingTeam: "A", pts: 4.5)
        XCTAssertEqual(t.state, .reacquiring)
        XCTAssertEqual(t.lastReacquirePts, 4.5)
        t.update(candidates: [hoop], attackingTeam: "A", pts: 5)
        XCTAssertEqual(t.state, .reacquiring)       // one steady tick
        t.update(candidates: [hoop], attackingTeam: "A", pts: 6)
        XCTAssertEqual(t.state, .tracking)          // two → locked again
    }

    func testBigJumpTriggersReacquire() {
        var t = RimTracker()
        t.update(candidates: [hoop], attackingTeam: "A", pts: 0)
        // Inside the 0.2 continuity gate but beyond the 0.15 jump threshold: camera panning.
        t.update(candidates: [hoop.offsetBy(dx: 0.18, dy: 0)], attackingTeam: "A", pts: 1)
        XCTAssertEqual(t.state, .reacquiring)
    }
}
