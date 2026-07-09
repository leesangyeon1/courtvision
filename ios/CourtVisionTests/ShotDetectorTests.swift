import XCTest
@testable import CourtVision

/// The acquisition gate: only trajectories that descend into a rim's
/// neighbourhood AND pass close to the rim count as attempts at all.
final class ShotDetectorTests: XCTestCase {
    private let rim = CGRect(x: 0.45, y: 0.30, width: 0.10, height: 0.06)

    private func update(_ pts: [CGPoint]) -> TrajectoryUpdate {
        TrajectoryUpdate(id: UUID(),
                         points: pts,
                         timestamps: pts.indices.map { Double($0) * 0.05 },
                         a: -1, b: 1, c: 0, confidence: 0.9)
    }

    func testThroughRimIsMade() {
        // Descends into the rim from above, exits below within the x-span.
        let pts = [CGPoint(x: 0.50, y: 0.05), CGPoint(x: 0.50, y: 0.15),
                   CGPoint(x: 0.50, y: 0.25), CGPoint(x: 0.50, y: 0.33),
                   CGPoint(x: 0.50, y: 0.40), CGPoint(x: 0.50, y: 0.50)]
        XCTAssertEqual(ShotDetector.decide(update(pts), rim: rim), true)
    }

    func testRimBounceOutIsMiss() {
        // Descends onto the rim, then leaves sideways — never exits below.
        let pts = [CGPoint(x: 0.50, y: 0.05), CGPoint(x: 0.50, y: 0.18),
                   CGPoint(x: 0.50, y: 0.29), CGPoint(x: 0.62, y: 0.24),
                   CGPoint(x: 0.75, y: 0.20)]
        XCTAssertEqual(ShotDetector.decide(update(pts), rim: rim), false)
    }

    func testFlatPassAcrossFrameIsNoEvent() {
        // Crosses the frame at rim height but never descends into the region
        // from above — the old detector counted this as a shot.
        let pts = [CGPoint(x: 0.10, y: 0.32), CGPoint(x: 0.30, y: 0.32),
                   CGPoint(x: 0.50, y: 0.32), CGPoint(x: 0.70, y: 0.32),
                   CGPoint(x: 0.90, y: 0.33)]
        XCTAssertNil(ShotDetector.decide(update(pts), rim: rim))
    }

    func testDescentFarFromRimIsNoEvent() {
        // Arcs down well away from the rim (airball / pass) — not close, no event.
        let pts = [CGPoint(x: 0.15, y: 0.05), CGPoint(x: 0.18, y: 0.20),
                   CGPoint(x: 0.21, y: 0.40), CGPoint(x: 0.24, y: 0.60)]
        XCTAssertNil(ShotDetector.decide(update(pts), rim: rim))
    }

    func testTinyFarRimStillDetects() {
        // Far hoop on a full-court view: rim box only ~2.4% of frame width.
        // Proportional gates would collapse below trajectory point spacing;
        // the absolute floors must keep this decidable as a make.
        let farRim = CGRect(x: 0.80, y: 0.32, width: 0.024, height: 0.015)
        let pts = [CGPoint(x: 0.812, y: 0.24), CGPoint(x: 0.812, y: 0.29),
                   CGPoint(x: 0.812, y: 0.33), CGPoint(x: 0.812, y: 0.37),
                   CGPoint(x: 0.812, y: 0.42)]
        XCTAssertEqual(ShotDetector.decide(update(pts), rim: farRim), true)
    }
}
