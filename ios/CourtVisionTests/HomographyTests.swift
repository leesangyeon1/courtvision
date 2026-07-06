import CoreGraphics
import XCTest
@testable import CourtVision

final class HomographyTests: XCTestCase {
    func testIdentity() throws {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let h = try XCTUnwrap(Homography(from: corners, to: corners))

        // Matrix should be (close to) the identity.
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for (got, expected) in zip(h.m, identity) {
            XCTAssertEqual(got, expected, accuracy: 1e-9)
        }

        let p = CGPoint(x: 0.3, y: 0.7)
        let q = h.apply(p)
        XCTAssertEqual(q.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
    }

    func testKnownPerspectiveRoundTrip() throws {
        // A camera-like view of the court quad: convex, non-affine.
        let src = [CGPoint(x: 0.10, y: 0.90), CGPoint(x: 0.92, y: 0.88),
                   CGPoint(x: 0.30, y: 0.35), CGPoint(x: 0.72, y: 0.34)]
        // Baseline corners + FT-line corners of the key, in feet.
        let dst = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0),
                   CGPoint(x: 17, y: 19), CGPoint(x: 33, y: 19)]

        let forward = try XCTUnwrap(Homography(from: src, to: dst))
        let inverse = try XCTUnwrap(Homography(from: dst, to: src))

        // The 4 correspondences must map exactly (DLT constraints).
        for (s, d) in zip(src, dst) {
            let mapped = forward.apply(s)
            XCTAssertEqual(mapped.x, d.x, accuracy: 1e-6)
            XCTAssertEqual(mapped.y, d.y, accuracy: 1e-6)
        }

        // Round-trip of interior points through forward then inverse.
        for p in [CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.25, y: 0.75),
                  CGPoint(x: 0.65, y: 0.45)] {
            let back = inverse.apply(forward.apply(p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        }
    }

    func testDegeneratePointsReturnNil() {
        // Three collinear points cannot define a homography.
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5),
                   CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let dst = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0),
                   CGPoint(x: 17, y: 19), CGPoint(x: 33, y: 19)]
        XCTAssertNil(Homography(from: src, to: dst))
    }
}
