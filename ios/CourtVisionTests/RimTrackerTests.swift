import XCTest
@testable import CourtVision

final class RimTrackerTests: XCTestCase {
    private let hoopA = CGRect(x: 0.15, y: 0.20, width: 0.10, height: 0.06)
    private let hoopB = CGRect(x: 0.75, y: 0.22, width: 0.10, height: 0.06)
    private let sideHoop = CGRect(x: 0.45, y: 0.15, width: 0.10, height: 0.06)

    func testTapsAssignEndsAndSideHoopNeverSteals() {
        var t = RimTracker()
        t.update(candidates: [hoopA, sideHoop, hoopB], pts: 0)
        XCTAssertTrue(t.rims.isEmpty)                            // nothing locked until a tap
        XCTAssertEqual(t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 1), "A")   // first tap → end A
        XCTAssertEqual(t.designate(at: CGPoint(x: 0.8, y: 0.25), pts: 2), "B")   // second → end B
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX, accuracy: 1e-9)
        XCTAssertEqual(t.rims["B"]?.midX ?? 0, hoopB.midX, accuracy: 1e-9)
        t.update(candidates: [sideHoop], pts: 3)                 // only the side hoop visible
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX, accuracy: 1e-9)
        XCTAssertEqual(t.rims["B"]?.midX ?? 0, hoopB.midX, accuracy: 1e-9)
        // A tap near an existing end re-designates that end (moves it), no third end.
        XCTAssertEqual(t.designate(at: CGPoint(x: 0.22, y: 0.24), pts: 4), "A")
        XCTAssertEqual(t.rims.count, 2)
    }

    func testEachEndTracksOccludesAndReacquiresIndependently() {
        var t = RimTracker()
        t.update(candidates: [hoopA, hoopB], pts: 0)
        _ = t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 0)
        _ = t.designate(at: CGPoint(x: 0.8, y: 0.25), pts: 0)
        for s in 1...4 { t.update(candidates: [hoopB], pts: Double(s)) }        // A occluded 4 s: tolerated
        XCTAssertEqual(t.state(of: "A"), .tracking)
        t.update(candidates: [hoopB], pts: 4.5)
        XCTAssertEqual(t.state(of: "A"), .reacquiring)
        XCTAssertEqual(t.state(of: "B"), .tracking)
        XCTAssertEqual(t.lastReacquirePts, 4.5)
        XCTAssertEqual(t.trackedEnds, ["B"])                                    // A dropped from rims while lost
        t.update(candidates: [hoopA, hoopB], pts: 5)                             // A back near its anchor
        t.update(candidates: [hoopA, hoopB], pts: 6)
        XCTAssertEqual(t.state(of: "A"), .tracking)
        XCTAssertEqual(Set(t.trackedEnds), ["A", "B"])
    }

    func testBigJumpTriggersReacquireForThatEndOnly() {
        var t = RimTracker()
        t.update(candidates: [hoopA, hoopB], pts: 0)
        _ = t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 0)
        _ = t.designate(at: CGPoint(x: 0.8, y: 0.25), pts: 0)
        // Inside the 0.2 gate, beyond the 0.15 jump threshold: camera panning near A.
        t.update(candidates: [hoopA.offsetBy(dx: 0.18, dy: 0), hoopB], pts: 1)
        XCTAssertEqual(t.state(of: "A"), .reacquiring)
        XCTAssertEqual(t.state(of: "B"), .tracking)
    }

    func testNoAnchorNoLock() {
        // Untapped: candidates are remembered for a tap, never auto-locked
        // (side baskets would win otherwise).
        var t = RimTracker()
        t.update(candidates: [sideHoop], pts: 0)
        XCTAssertTrue(t.rims.isEmpty)
        XCTAssertEqual(t.lastCandidates, [sideHoop])
    }
}
