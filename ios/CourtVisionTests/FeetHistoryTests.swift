import XCTest
@testable import CourtVision

final class FeetHistoryTests: XCTestCase {
    private func sample(_ pts: Double, y: CGFloat?) -> PoseReader.Sample {
        PoseReader.Sample(pts: pts, ankleMid: y.map { CGPoint(x: 0.5, y: $0) })
    }

    func testGroundContactIsLowestAnkleInWindow() {
        var f = FeetHistory()
        f.add(sample(0.0, y: 0.60), track: 3, now: 0.0)     // on the floor
        f.add(sample(0.3, y: 0.55), track: 3, now: 0.3)     // rising
        f.add(sample(0.5, y: 0.45), track: 3, now: 0.5)     // in the air
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.60))
        XCTAssertNil(f.groundContact(track: 9))
    }

    func testWindowAndPrune() {
        var f = FeetHistory()
        f.add(sample(0.0, y: 0.60), track: 3, now: 0.0)
        f.add(sample(1.5, y: 0.50), track: 3, now: 1.5)     // the 0.0 sample ages out (window 1 s)
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.50))
        f.add(sample(1.5, y: nil), track: 3, now: 1.5)      // no ankles seen: ignored for contact
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.50))
        f.prune(keeping: [4])
        XCTAssertNil(f.groundContact(track: 3))
    }

    func testRoiToFrameMapping() {
        let roi = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)              // Vision space
        let f = PoseReader.toFrame(CGPoint(x: 0.5, y: 0.5), roi: roi)
        XCTAssertEqual(f.x, 0.45, accuracy: 1e-9)
        XCTAssertEqual(f.y, 0.30, accuracy: 1e-9)
    }
}
