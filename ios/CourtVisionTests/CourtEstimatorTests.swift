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
}
