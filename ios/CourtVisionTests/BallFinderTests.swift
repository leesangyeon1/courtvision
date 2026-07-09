import XCTest
@testable import CourtVision

final class BallFinderTests: XCTestCase {
    func testPickBallContinuityGate() {
        let far = CGRect(x: 0.05, y: 0.1, width: 0.03, height: 0.03)   // other ball / head
        let near = CGRect(x: 0.52, y: 0.42, width: 0.03, height: 0.03) // the game ball
        let anchor = CGPoint(x: 0.5, y: 0.4)
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: anchor, within: 0.2), near)
        // Only a distant candidate → must not steal the track.
        XCTAssertNil(BallFinder.pickBall(candidates: [far], near: anchor, within: 0.2))
        // No anchor yet → most confident (first).
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: nil), far)
    }

    func testBallTrackTrailAndGapReset() {
        var track = BallTrack()
        let t0 = Date()
        let box = { (x: CGFloat) in CGRect(x: x, y: 0.4, width: 0.03, height: 0.03) }
        track.update(with: box(0.10), at: t0)
        track.update(with: box(0.15), at: t0.addingTimeInterval(0.125))
        track.update(with: box(0.20), at: t0.addingTimeInterval(0.250))
        XCTAssertEqual(track.samples.count, 3)
        // Old samples fall off the trail (maxAge 1.5 s).
        track.update(with: box(0.90), at: t0.addingTimeInterval(1.7))
        XCTAssertEqual(track.samples.count, 1)   // gap 1.45s < maxGap? no —
        // gap since last sample (0.25s→1.7s = 1.45s) exceeds maxGap 1.0:
        // the track resets and the new sample starts a fresh flight.
        XCTAssertEqual(track.last?.point.x ?? 0, 0.915, accuracy: 1e-9)
        // A nil update past maxGap clears everything.
        track.update(with: nil, at: t0.addingTimeInterval(3.0))
        XCTAssertTrue(track.samples.isEmpty)
    }
}
