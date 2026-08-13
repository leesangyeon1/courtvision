import XCTest
@testable import CourtVision

final class PlayerTrackerTests: XCTestCase {
    private func det(_ x: CGFloat, _ y: CGFloat = 0.4) -> Detection {
        Detection(box: CGRect(x: x, y: y, width: 0.06, height: 0.22),
                  label: "player", confidence: 0.8)
    }

    func testStableIDsAcrossTicks() {
        var tracker = PlayerTracker()
        let first = tracker.update(with: [det(0.40), det(0.70)])
        XCTAssertEqual(first.map(\.id), [1, 2])
        // Both players drift slightly — IDs must not swap or churn.
        let second = tracker.update(with: [det(0.71), det(0.41)])
        XCTAssertEqual(Set(second.map(\.id)), [1, 2])
        XCTAssertEqual(second.first { $0.id == 1 }?.box.minX ?? 0, 0.41, accuracy: 1e-9)
    }

    func testTrackDiesAfterMaxMissedTicks() {
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        for _ in 0..<4 { _ = tracker.update(with: []) }   // maxMissedTicks = 4
        XCTAssertTrue(tracker.tracks.isEmpty)
        // A returning player is a NEW identity.
        XCTAssertEqual(tracker.update(with: [det(0.40)]).map(\.id), [2])
    }

    func testNumberMajorityVotePersists() {
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        let read = { (d: String) in [(point: CGPoint(x: 0.43, y: 0.5), digits: d)] }
        tracker.assign(numbers: read("23"))
        tracker.assign(numbers: read("28"))   // one misread
        tracker.assign(numbers: read("23"))
        XCTAssertEqual(tracker.tracks[0].number, "23")
        // Jersey turns away — no reads — the number persists with the track.
        _ = tracker.update(with: [det(0.41)])
        XCTAssertEqual(tracker.tracks[0].number, "23")
        // A read landing on no track is dropped (scoreboard digit).
        tracker.assign(numbers: [(point: CGPoint(x: 0.95, y: 0.05), digits: "7")])
        XCTAssertEqual(tracker.tracks[0].number, "23")
    }
}
