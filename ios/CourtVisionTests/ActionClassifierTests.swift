import XCTest
@testable import CourtVision

final class ActionClassifierTests: XCTestCase {
    private let shooter = TrackedPlayer(id: 1, box: CGRect(x: 0.40, y: 0.40, width: 0.06, height: 0.22))
    private let defender = TrackedPlayer(id: 2, box: CGRect(x: 0.70, y: 0.42, width: 0.06, height: 0.20))

    func testStateAnnotatesBestIoUTrack() {
        let state = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                              label: "player-jump-shot", confidence: 0.9)
        let out = ActionClassifier.classify(states: [state], tracks: [shooter, defender])
        XCTAssertEqual(out[0].action, .jumpShot)
        XCTAssertEqual(out[1].action, .none)
        XCTAssertEqual(out[0].actionConfidence, 0.9, accuracy: 1e-6)
        XCTAssertEqual(out[1].actionConfidence, 0)
    }

    func testOrphanStateBoxIsDropped() {
        // A state box overlapping no track is a detector mistake by
        // construction — states cannot exist without a player.
        let orphan = Detection(box: CGRect(x: 0.05, y: 0.05, width: 0.06, height: 0.22),
                               label: "player-layup-dunk", confidence: 0.9)
        let out = ActionClassifier.classify(states: [orphan], tracks: [shooter])
        XCTAssertEqual(out[0].action, .none)
    }

    func testLabelMapping() {
        XCTAssertEqual(PlayerAction(label: "player-in-possession"), .possession)
        XCTAssertEqual(PlayerAction(label: "player-jump-shot"), .jumpShot)
        XCTAssertEqual(PlayerAction(label: "player-layup-dunk"), .layupDunk)
        XCTAssertEqual(PlayerAction(label: "player-shot-block"), .shotBlock)
        XCTAssertEqual(PlayerAction(label: "referee"), .none)
    }
}
