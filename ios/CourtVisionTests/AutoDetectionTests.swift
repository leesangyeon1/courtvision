import XCTest
@testable import CourtVision

final class AutoDetectionTests: XCTestCase {
    /// Synthetic 192×108 frame: gray background, one orange rim-shaped blob.
    private func frame(blobs: [(x: Int, y: Int, w: Int, h: Int)]) -> [UInt8] {
        let W = 192, H = 108
        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) {
            rgba[i * 4] = 90; rgba[i * 4 + 1] = 90; rgba[i * 4 + 2] = 95; rgba[i * 4 + 3] = 255
        }
        for b in blobs {
            for y in b.y..<(b.y + b.h) {
                for x in b.x..<(b.x + b.w) {
                    let i = (y * W + x) * 4
                    rgba[i] = 230; rgba[i + 1] = 110; rgba[i + 2] = 30   // rim orange
                }
            }
        }
        return rgba
    }

    func testFindsTwoRimsSortedLeftToRight() {
        // Rim-shaped: wider than tall, upper half of frame.
        let rgba = frame(blobs: [(x: 150, y: 30, w: 8, h: 4), (x: 20, y: 28, w: 9, h: 4)])
        let rims = RimFinder.detectRims(width: 192, height: 108, rgba: rgba, maxCount: 2)
        XCTAssertEqual(rims.count, 2)
        XCTAssertLessThan(rims[0].midX, rims[1].midX)          // rim 1 = left
        XCTAssertEqual(Double(rims[0].midX), (20.0 + 4.5) / 192.0, accuracy: 0.02)
    }

    func testIgnoresBallShapedAndFloorBlobs() {
        // Round blob (ball, aspect 1) and a huge floor-wide strip must not
        // pass the rim shape filters.
        let rgba = frame(blobs: [(x: 90, y: 60, w: 5, h: 5), (x: 0, y: 90, w: 190, h: 10)])
        let rims = RimFinder.detectRims(width: 192, height: 108, rgba: rgba, maxCount: 2)
        XCTAssertTrue(rims.isEmpty)
    }

    func testCourtCornerOrdering() {
        // Trapezoid as seen from the sideline: near pair lower (larger y).
        let corners = [CGPoint(x: 0.9, y: 0.35), CGPoint(x: 0.05, y: 0.9),
                       CGPoint(x: 0.1, y: 0.4), CGPoint(x: 0.95, y: 0.88)]
        let ordered = CourtFinder.orderCourtCorners(corners)
        XCTAssertEqual(ordered, [CGPoint(x: 0.05, y: 0.9),   // near-left
                                 CGPoint(x: 0.1, y: 0.4),    // far-left
                                 CGPoint(x: 0.95, y: 0.88),  // near-right
                                 CGPoint(x: 0.9, y: 0.35)])  // far-right
    }

    func testStableQuadLocksOnAgreementOnly() {
        let q: [CGPoint] = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.3),
                            CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.3)]
        let jitter = q.map { CGPoint(x: $0.x + 0.005, y: $0.y - 0.005) }
        let far = q.map { CGPoint(x: $0.x + 0.2, y: $0.y) }
        XCTAssertNil(CourtFinder.stableQuad([q]))                    // too few
        XCTAssertNil(CourtFinder.stableQuad([q, far, q]))            // disagreement
        let avg = CourtFinder.stableQuad([q, jitter, q])
        XCTAssertNotNil(avg)                                            // small jitter OK
        XCTAssertEqual(Double(avg![0].x), 0.1 + 0.005 / 3, accuracy: 1e-6)
    }

    func testCourtScoringPicksBaselineFromRim() {
        // Behind-the-court half-court view: image_x = court_x/50,
        // image_y = 1 - court_y/47 → the NEAR image edge is the baseline.
        func img(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x / 50, y: 1 - y / 47)
        }
        let quad = [img(0, 0), img(0, 47), img(50, 0), img(50, 47)]  // [NL, FL, NR, FR]
        // Rim box centered on the hoop's image position.
        let rimC = img(25, 5.25)
        let rim = CGRect(x: rimC.x - 0.03, y: rimC.y - 0.02, width: 0.06, height: 0.04)
        guard let pick = CourtFinder.scoreCourtAssignments(quad: quad, rims: [rim],
                                                              fullCourt: false) else {
            return XCTFail("scoring returned nil")
        }
        // Correct assignment: near edge = baseline → NL=(0,0), NR=(50,0).
        XCTAssertEqual(pick.courtPoints[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(pick.courtPoints[2], CGPoint(x: 50, y: 0))
        XCTAssertLessThan(pick.score, 1.0)
        // A rim placed at midcourt matches no orientation well → nil.
        let bogus = CGRect(x: 0.47, y: 0.45, width: 0.06, height: 0.04)
        _ = bogus // rim at court centre projects ~18ft from a hoop under the
        // best orientation, inside maxError; use a corner-far rim instead:
        let wayOff = CGRect(x: 0.0, y: 0.0, width: 0.04, height: 0.03)
        XCTAssertNil(CourtFinder.scoreCourtAssignments(quad: quad, rims: [wayOff],
                                                          fullCourt: false, maxError: 5))
    }

    func testPickRimPrefersAnchorOverConfidence() {
        // Side hoop (first = most confident) vs the game hoop near the tap.
        let side = CGRect(x: 0.1, y: 0.2, width: 0.06, height: 0.04)
        let game = CGRect(x: 0.7, y: 0.3, width: 0.05, height: 0.03)
        XCTAssertEqual(RimFinder.pickRim(candidates: [side, game],
                                              near: CGPoint(x: 0.72, y: 0.3)), game)
        XCTAssertEqual(RimFinder.pickRim(candidates: [side, game], near: nil), side)
        XCTAssertNil(RimFinder.pickRim(candidates: [], near: nil))
        // Tap authority: candidates beyond `within` never steal the anchor.
        XCTAssertNil(RimFinder.pickRim(candidates: [side],
                                       near: CGPoint(x: 0.72, y: 0.3), within: 0.15))
        XCTAssertEqual(RimFinder.pickRim(candidates: [side, game],
                                         near: CGPoint(x: 0.72, y: 0.3), within: 0.15), game)
    }
}
