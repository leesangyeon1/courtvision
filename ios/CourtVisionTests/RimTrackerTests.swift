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
        // A tap near an existing end re-designates that end, no third end.
        XCTAssertEqual(t.designate(at: CGPoint(x: 0.22, y: 0.24), pts: 4), "A")
        XCTAssertEqual(t.rims.count, 2)
    }

    func testOcclusionNeverDropsARim() {
        // Fixed camera: the rim is where it was even when players hide it for
        // minutes. No reacquire state exists.
        var t = RimTracker()
        t.update(candidates: [hoopA], pts: 0)
        _ = t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 0)
        for s in 1...600 { t.update(candidates: [], pts: Double(s)) }   // 10 min occluded
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX, accuracy: 1e-9)
        // A detection drifting slightly refines it; a far candidate can't move it.
        t.update(candidates: [hoopA.offsetBy(dx: 0.01, dy: 0)], pts: 601)
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX + 0.01, accuracy: 1e-9)
        t.update(candidates: [sideHoop], pts: 602)
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX + 0.01, accuracy: 1e-9)
    }

    func testInvalidateMarksStaleUntilRetap() {
        var t = RimTracker()
        t.update(candidates: [hoopA], pts: 0)
        _ = t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 0)
        t.invalidate(pts: 5)                                     // tripod bump
        XCTAssertTrue(t.stale)
        XCTAssertEqual(t.staleSincePts, 5)
        XCTAssertTrue(t.rims.isEmpty)                            // stale rims are not served
        t.update(candidates: [hoopA], pts: 6)
        XCTAssertTrue(t.rims.isEmpty)                            // detections alone can't clear a bump
        t.update(candidates: [hoopA], pts: 7)
        _ = t.designate(at: CGPoint(x: 0.2, y: 0.23), pts: 7)    // user re-taps
        XCTAssertFalse(t.stale)
        XCTAssertEqual(t.lastInvalidatedPts, 5)                  // survives the re-tap
        XCTAssertEqual(t.rims["A"]?.midX ?? 0, hoopA.midX, accuracy: 1e-9)
    }

    func testNoAnchorNoLock() {
        var t = RimTracker()
        t.update(candidates: [sideHoop], pts: 0)
        XCTAssertTrue(t.rims.isEmpty)
        XCTAssertEqual(t.lastCandidates, [sideHoop])
    }
}
