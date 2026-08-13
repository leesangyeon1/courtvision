import XCTest
@testable import CourtVision

final class BallFinderTests: XCTestCase {
    private func ball(_ x: CGFloat, _ y: CGFloat, label: String = "ball",
                      conf: Float = 0.5) -> Detection {
        Detection(box: CGRect(x: x, y: y, width: 0.03, height: 0.03),
                  label: label, confidence: conf)
    }

    func testPickBallContinuityGate() {
        let far = ball(0.05, 0.1)    // other ball / head
        let near = ball(0.52, 0.42)  // the game ball
        let anchor = CGPoint(x: 0.5, y: 0.4)
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: anchor, within: 0.2), near)
        // Only a distant candidate → must not steal the track.
        XCTAssertNil(BallFinder.pickBall(candidates: [far], near: anchor, within: 0.2))
        // No anchor yet → most confident (first).
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: nil), far)
    }

    func testBallTrackTrailGapResetAndLabel() {
        var track = BallTrack()
        let t0 = Date()
        let det = { (x: CGFloat, label: String) in
            Detection(box: CGRect(x: x, y: 0.4, width: 0.03, height: 0.03),
                      label: label, confidence: 0.5)
        }
        track.update(with: det(0.10, "ball"), at: t0)
        track.update(with: det(0.15, "ball"), at: t0.addingTimeInterval(0.125))
        track.update(with: det(0.20, "ball-in-basket"), at: t0.addingTimeInterval(0.250))
        XCTAssertEqual(track.samples.count, 3)
        // The state label rides the sample — make/miss logic reads the track.
        XCTAssertEqual(track.last?.label, "ball-in-basket")
        // Gap since last sample (0.25s→1.7s = 1.45s) exceeds maxGap 1.0:
        // the track resets and the new sample starts a fresh flight.
        track.update(with: det(0.90, "ball"), at: t0.addingTimeInterval(1.7))
        XCTAssertEqual(track.samples.count, 1)
        XCTAssertEqual(track.last?.point.x ?? 0, 0.915, accuracy: 1e-9)
        // A nil update past maxGap clears everything.
        track.update(with: nil, at: t0.addingTimeInterval(3.0))
        XCTAssertTrue(track.samples.isEmpty)
    }
}
