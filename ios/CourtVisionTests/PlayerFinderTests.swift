import XCTest
@testable import CourtVision

final class PlayerFinderTests: XCTestCase {
    func testShapeFilterKillsNonPersonBoxes() {
        let person = CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.22)
        let scoreboard = CGRect(x: 0.3, y: 0.02, width: 0.4, height: 0.10)  // wide, top of frame
        let speck = CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.03)
        let kept = PlayerFinder.shapeFiltered([person, scoreboard, speck])
        XCTAssertEqual(kept, [person])
    }

    func testDedupeMergesCrossClassDoubles() {
        // Same player as "player" and "player-jump-shot" — heavy overlap.
        let a = CGRect(x: 0.40, y: 0.40, width: 0.06, height: 0.22)
        let b = CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22)
        let other = CGRect(x: 0.70, y: 0.45, width: 0.06, height: 0.20)
        XCTAssertEqual(PlayerFinder.dedupe([a, b, other]), [a, other])
    }

    func testNumberAssignment() {
        let shooter = CGRect(x: 0.40, y: 0.40, width: 0.08, height: 0.25)
        let defender = CGRect(x: 0.60, y: 0.42, width: 0.08, height: 0.24)
        let numbers = [(point: CGPoint(x: 0.44, y: 0.48), digits: "23"),
                       (point: CGPoint(x: 0.95, y: 0.10), digits: "7")]  // scoreboard digit, no player
        let players = PlayerFinder.assign(numbers: numbers, to: [shooter, defender])
        XCTAssertEqual(players[0].number, "23")
        XCTAssertNil(players[1].number)
    }
}
