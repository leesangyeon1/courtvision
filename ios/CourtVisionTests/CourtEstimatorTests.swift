import XCTest
@testable import CourtVision

final class CourtEstimatorTests: XCTestCase {
    /// Image quad in landmark order [near-left, far-left, near-right, far-right].
    /// Under the "left edge is the baseline" assignment, image x spans court
    /// depth (0…47 ft) and image y (0.9→0.1) spans court width (0…50 ft).
    private let quad = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.1),
                        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
    /// Rim box whose center projects to the hoop (25, 5.25) under that assignment.
    private let rim = CGRect(x: 0.16, y: 0.48, width: 0.06, height: 0.04)

    func testAcceptsFitAndProjectsFeet() {
        var c = CourtEstimator(calibration: nil)
        XCTAssertNil(c.h)
        XCTAssertTrue(c.update(quadCandidates: [quad], rims: [rim]))
        XCTAssertNotNil(c.h)
        XCTAssertLessThan(c.fitFt ?? 99, 1)
        let feet = c.h!.apply(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(feet.x), 25, accuracy: 0.5)
        XCTAssertEqual(Double(feet.y), 23.5, accuracy: 0.5)
    }

    func testNoRimOrBadFitKeepsPreviousEstimate() {
        var c = CourtEstimator(calibration: nil)
        c.update(quadCandidates: [quad], rims: [rim])
        let h0 = c.h
        XCTAssertFalse(c.update(quadCandidates: [quad], rims: []))
        XCTAssertEqual(c.h, h0)
        // Rim far from any plausible hoop position → every assignment fails the 15 ft gate.
        XCTAssertFalse(c.update(quadCandidates: [quad], rims: [CGRect(x: 0.5, y: 0.5, width: 0.06, height: 0.04)]))
        XCTAssertEqual(c.h, h0)
    }

    func testSolveOnceLocksAndDriftUnlocks() {
        var c = CourtEstimator(calibration: nil)
        XCTAssertTrue(c.update(quadCandidates: [quad], rims: [rim]))
        XCTAssertTrue(c.locked)
        let h0 = c.h
        // Locked + rims where the fit predicts them → no re-solve, fit kept.
        XCTAssertFalse(c.update(quadCandidates: [], rims: [rim]))
        XCTAssertEqual(c.h, h0)
        // Rim far from where the fit predicts (camera bumped): drift, but a
        // single bad check is occlusion noise — needs 3 in a row.
        let moved = rim.offsetBy(dx: 0.4, dy: 0.2)     // ≈ 27 ft of projected error
        XCTAssertFalse(c.update(quadCandidates: [], rims: [moved]))
        XCTAssertTrue(c.locked)
        XCTAssertFalse(c.update(quadCandidates: [], rims: [moved]))
        _ = c.update(quadCandidates: [], rims: [moved])
        XCTAssertFalse(c.locked)                        // 3rd consecutive → unlocked, will re-solve
        XCTAssertNil(c.h)                                // stale fit is not used (no fake coords)
    }

    func testInvalidateForcesResolve() {
        var c = CourtEstimator(calibration: nil)
        _ = c.update(quadCandidates: [quad], rims: [rim])
        c.invalidate()
        XCTAssertFalse(c.locked)
        XCTAssertNil(c.h)
        XCTAssertTrue(c.update(quadCandidates: [quad], rims: [rim]))   // solves again
        XCTAssertTrue(c.locked)
    }

    func testComputedTilesCoverTheCourtLeftToRight() {
        // Full-court fit: image x spans the 94 ft length (same synthetic
        // geometry as above, doubled depth).
        let src = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.1),
                   CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
        let dst = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0),
                   CGPoint(x: 0, y: 94), CGPoint(x: 50, y: 94)]
        let h = Homography(from: src, to: dst)!
        let tiles = CourtEstimator.tiles(h: h, count: 3, lengthFt: 94)
        XCTAssertEqual(tiles.count, 3)
        for t in tiles {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(t))   // clamped
            XCTAssertGreaterThan(t.width, 0.2)                                    // ~a third + pad
        }
        // Zones tile the length: centers ordered along image x.
        XCTAssertLessThan(tiles[0].midX, tiles[1].midX)
        XCTAssertLessThan(tiles[1].midX, tiles[2].midX)
        // Degenerate H → no tiles (fall back to the guessed band).
        XCTAssertTrue(CourtEstimator.tiles(h: Homography(matrix: [1, 2, 3, 2, 4, 6, 0, 0, 1])!,
                                           count: 3, lengthFt: 94).isEmpty)
    }
}
