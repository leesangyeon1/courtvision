import XCTest
@testable import CourtVision

/// The engine calls the unified model ONCE per tick; each module filters the
/// shared output. These are the filters.
final class TickFiltersTests: XCTestCase {
    private func det(_ label: String, _ conf: Float, x: CGFloat = 0.5) -> Detection {
        Detection(box: CGRect(x: x, y: 0.4, width: 0.06, height: 0.22), label: label, confidence: conf)
    }

    func testBallFilterKeepsBallFamilyAboveFloor() {
        let all = [det("ball", 0.9), det("ball-in-basket", 0.3), det("ball", 0.2), det("player", 0.9)]
        XCTAssertEqual(BallFinder.balls(from: all).map(\.label), ["ball", "ball-in-basket"])
    }

    func testPlayerFamilyFilterKeepsStatesDropsRefsAndLowConf() {
        let all = [det("player", 0.9), det("player-jump-shot", 0.5), det("referee", 0.9), det("player", 0.29)]
        XCTAssertEqual(PlayerFinder.playerFamily(from: all).map(\.label), ["player", "player-jump-shot"])
    }

    func testRimMergeUnionsNonOverlappingAndSortsLeftToRight() {
        let hoop = CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.06)
        let sameRim = CGRect(x: 0.61, y: 0.21, width: 0.1, height: 0.06)     // IoU > 0.3 → duplicate
        let sideHoop = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.06)
        let merged = RimFinder.merge(hoop: [hoop], unified: [sameRim, sideHoop], maxCount: 4)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], sideHoop)      // rim 1 = left
        XCTAssertEqual(merged[1], hoop)
    }
}
