import XCTest
@testable import CourtVision

final class PlayerFinderTests: XCTestCase {
    func testShapeFilterKillsNonPersonBoxes() {
        let person = Detection(box: CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.22),
                               label: "player", confidence: 0.8)
        let scoreboard = Detection(box: CGRect(x: 0.3, y: 0.02, width: 0.4, height: 0.10),
                                   label: "player", confidence: 0.7)  // wide, top of frame
        let speck = Detection(box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.03),
                              label: "player", confidence: 0.6)
        XCTAssertEqual(PlayerFinder.shapeFiltered([person, scoreboard, speck]), [person])
    }

    func testDedupeDropsContainedFragmentButKeepsOverlappingNeighbour() {
        // A near player often yields a whole-body box AND a torso/head
        // fragment inside it (IoU small, so IoU-only dedupe keeps both).
        let body = Detection(box: CGRect(x: 0.40, y: 0.30, width: 0.10, height: 0.40),
                             label: "player", confidence: 0.9)
        let fragment = Detection(box: CGRect(x: 0.42, y: 0.32, width: 0.06, height: 0.15),
                                 label: "player", confidence: 0.6)          // ~100% inside body, IoU ≈ 0.22
        let neighbour = Detection(box: CGRect(x: 0.47, y: 0.35, width: 0.06, height: 0.20),
                                  label: "player", confidence: 0.7)         // half inside body: a second person
        XCTAssertEqual(PlayerFinder.dedupe([body, fragment, neighbour]), [body, neighbour])
    }

    func testCorePlayersKeepBaseBoxOverStateBox() {
        // Same player seen as base "player" (lower conf) and "player-jump-shot"
        // (higher conf): the BASE box must survive the dedupe — state classes
        // are Layer-3 evidence, not extra players.
        let base = Detection(box: CGRect(x: 0.40, y: 0.40, width: 0.06, height: 0.22),
                             label: "player", confidence: 0.55)
        let state = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                              label: "player-jump-shot", confidence: 0.90)
        let other = Detection(box: CGRect(x: 0.70, y: 0.45, width: 0.06, height: 0.20),
                              label: "player", confidence: 0.8)
        // Output is confidence-ranked among survivors: other (0.8) first.
        XCTAssertEqual(PlayerFinder.corePlayers([state, base, other]), [other, base])
    }

    func testStatesFilterKeepsOnlyStateClasses() {
        let base = Detection(box: CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.22),
                             label: "player", confidence: 0.8)
        let shot = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                             label: "player-jump-shot", confidence: 0.9)
        XCTAssertEqual(PlayerFinder.states([base, shot]), [shot])
    }
}
