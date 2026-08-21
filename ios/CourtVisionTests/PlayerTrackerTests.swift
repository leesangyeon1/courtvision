import XCTest
@testable import CourtVision

final class PlayerTrackerTests: XCTestCase {
    private func det(_ x: CGFloat, _ y: CGFloat = 0.4, w: CGFloat = 0.06, h: CGFloat = 0.22) -> Detection {
        Detection(box: CGRect(x: x, y: y, width: w, height: h), label: "player", confidence: 0.8)
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

    func testFastMoverStaysOnItsTrackWithoutOverlap() {
        // A sprinting player moves half a body height between ticks: IoU 0,
        // center distance small relative to his size → same id (no churn).
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        XCTAssertEqual(tracker.update(with: [det(0.47)]).map(\.id), [1])     // moved 0.07 > width, IoU 0
        XCTAssertEqual(tracker.update(with: [det(0.54)]).map(\.id), [1])
        // Too far for one tick (> 0.75 × body height): a different player
        // (track 1 stays alive, unmatched, for its tolerance window).
        let out = tracker.update(with: [det(0.80)])
        XCTAssertEqual(out.first { $0.box.minX == 0.80 }?.id, 2)
        XCTAssertEqual(out.first { $0.id == 1 }?.missedTicks, 1)
    }

    func testLostTrackResurrectsNearbyWithItsNumber() {
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        for _ in 0..<3 { tracker.assign(numbers: [(point: CGPoint(x: 0.43, y: 0.5), digits: "23")]) }
        // Occluded for 2 s (track dies)…
        for _ in 0..<tracker.maxMissedTicks { _ = tracker.update(with: []) }
        XCTAssertTrue(tracker.tracks.isEmpty)
        // …then a detection reappears close to where he was: SAME id, number intact.
        let back = tracker.update(with: [det(0.44)])
        XCTAssertEqual(back.map(\.id), [1])
        XCTAssertEqual(back[0].number, "23")
        // Far from any lost track → new id.
        XCTAssertEqual(tracker.update(with: [det(0.44), det(0.90)]).map(\.id).sorted(), [1, 2])
    }

    func testTrackDiesForGoodAfterResurrectWindow() {
        var tracker = PlayerTracker()
        tracker.tickSeconds = 1.0 / 6                                          // 6 Hz
        _ = tracker.update(with: [det(0.40)])
        let gone = tracker.maxMissedTicks + Int(tracker.resurrectSeconds * 6) + 1
        for _ in 0..<gone { _ = tracker.update(with: []) }
        XCTAssertEqual(tracker.update(with: [det(0.40)]).map(\.id), [2])    // too long ago: a new identity
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
