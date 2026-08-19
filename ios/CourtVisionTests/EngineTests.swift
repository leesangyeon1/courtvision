import CoreVideo
import XCTest
@testable import CourtVision

final class EngineTests: XCTestCase {
    private func blank() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
    private func det(_ box: CGRect, _ label: String, _ conf: Float) -> Detection {
        Detection(box: box, label: label, confidence: conf)
    }
    // Same synthetic court as CourtEstimatorTests: feet at image (0.5, 0.5) → (25, 23.5) ft.
    private let quad = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.1),
                        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
    private let rim = CGRect(x: 0.16, y: 0.48, width: 0.06, height: 0.04)
    private let player = CGRect(x: 0.47, y: 0.28, width: 0.06, height: 0.22)   // bottom-center (0.5, 0.5)
    private let ball = CGRect(x: 0.6, y: 0.3, width: 0.03, height: 0.03)

    /// Reference box so a stored closure can count calls.
    private final class Counter { var n = 0 }

    private func engine(hoop counter: Counter = Counter(), isGame: Bool = false,
                        calibration: Calibration? = nil) -> Engine {
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(self.player, "player", 0.9),
                             self.det(self.ball, "ball", 0.8),
                             self.det(self.rim, "rim", 0.9)] },
            hoop: { _ in counter.n += 1; return [] },
            courtQuads: { _ in [self.quad] },
            numbers: { _, _ in [] },
            pose: { _, _, _ in nil },
            torsoColor: { _, _ in nil })
        // End A seeded from calibration (a rim never locks without an anchor).
        return Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                      calibration: calibration, isGame: isGame, attackingTeam: "A",
                      rimAnchors: [:], initialRims: ["A": rim])
    }

    func testOneTickBuildsMomentWithRimCourtBallAndProjectedFeet() {
        let e = engine()
        let m = e.process(blank(), pts: 0)
        XCTAssertEqual(m.pts, 0)
        XCTAssertNotNil(m.rims["A"])              // slow lane ran on tick 1: unified rim → end A
        XCTAssertNotNil(m.h)                       // quad scored against that rim
        XCTAssertEqual(m.players.count, 1)
        XCTAssertEqual(m.players[0].feet, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(m.players[0].xFt ?? 0, 25, accuracy: 0.5)
        XCTAssertEqual(m.players[0].yFt ?? 0, 23.5, accuracy: 0.5)
        XCTAssertEqual(m.ball?.label, "ball")
        XCTAssertEqual(e.lastMoment, m)
    }

    func testSlowLaneCadenceThrottleAndThermal() {
        let hoop = Counter()
        let e = engine(hoop: hoop)
        for i in 0..<16 { _ = e.process(blank(), pts: Double(i) / 8) }   // 2 s at 8 Hz
        XCTAssertEqual(hoop.n, 2)                                        // ticks 1 and 9
        // Last tick at 15/8 = 1.875 s.
        XCTAssertFalse(e.shouldTick(at: 1.9, thermal: .nominal))
        XCTAssertTrue(e.shouldTick(at: 2.0, thermal: .nominal))
        XCTAssertFalse(e.shouldTick(at: 2.0, thermal: .serious))         // halves to 4 Hz
        XCTAssertTrue(e.shouldTick(at: 2.125, thermal: .serious))
    }

    func testPlayerTrackToleranceScalesWithTickRate() {
        let e = engine()
        XCTAssertEqual(e.process(blank(), pts: 0).players[0].trackId, 1)
        XCTAssertEqual(e.playerMaxMissedTicks, 16)                       // 2 s × 8 Hz (was 4 ticks at 2 Hz)
    }

    func testAttackingEndFollowsTheSingleLockedRim() {
        // Only end B locked → team B's hoop is the one in frame.
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(self.rim, "rim", 0.9)] },
            hoop: { _ in [] }, courtQuads: { _ in [] }, numbers: { _, _ in [] },
            pose: { _, _, _ in nil }, torsoColor: { _, _ in nil })
        let e = Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                       calibration: nil, isGame: true, attackingTeam: "A", rimAnchors: [:],
                       initialRims: ["B": rim])
        _ = e.process(blank(), pts: 0)
        XCTAssertTrue(e.flippedThisTick)
        XCTAssertEqual(e.attackingTeam, "B")
        // A tap far from B opens end A (default box, no candidate there) → both
        // locked → no single answer; the shot's end decides (ShotEventTracker).
        XCTAssertEqual(e.designateRim(at: CGPoint(x: 0.8, y: 0.5)), "A")
        XCTAssertEqual(e.rim.trackedEnds, ["A", "B"])
    }

    func testGhostTracksAreNotInMomentButKeepIdentity() {
        // Detection flickers off for one tick: the track survives inside the
        // tracker (same id afterwards) but a stale box is never emitted.
        var present = true
        let detectors = Engine.Detectors(
            unified: { _ in present ? [self.det(self.player, "player", 0.9)] : [] },
            hoop: { _ in [] }, courtQuads: { _ in [] }, numbers: { _, _ in [] }, pose: { _, _, _ in nil }, torsoColor: { _, _ in nil })
        let e = Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                       calibration: nil, isGame: false, attackingTeam: "A", rimAnchors: [:], initialRims: [:])
        XCTAssertEqual(e.process(blank(), pts: 0).players.map(\.trackId), [1])
        present = false
        XCTAssertTrue(e.process(blank(), pts: 0.125).players.isEmpty)
        present = true
        XCTAssertEqual(e.process(blank(), pts: 0.25).players.map(\.trackId), [1])
    }

    func testDesignateRimSnapsAndAnchors() {
        let e = engine()
        _ = e.process(blank(), pts: 0)
        XCTAssertEqual(e.designateRim(at: CGPoint(x: 0.2, y: 0.5)), "A")   // near end A's anchor → re-designates A
        XCTAssertEqual(e.rim.rims["A"]?.midX ?? 0, rim.midX, accuracy: 1e-9) // snapped to the unified rim
        XCTAssertEqual(e.rim.anchors["A"], CGPoint(x: 0.2, y: 0.5))
        XCTAssertEqual(e.designateRim(at: CGPoint(x: 0.8, y: 0.5)), "B")   // far from A → end B
        XCTAssertEqual(e.rim.trackedEnds, ["A", "B"])
    }

    func testTeamsFromJerseyColorAndSwap() {
        // Two players, white vs black chest; a referee box comes out separately.
        let p1 = CGRect(x: 0.20, y: 0.28, width: 0.06, height: 0.22)
        let p2 = CGRect(x: 0.70, y: 0.28, width: 0.06, height: 0.22)
        let ref = CGRect(x: 0.45, y: 0.30, width: 0.06, height: 0.22)
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(p1, "player", 0.9), self.det(p2, "player", 0.9), self.det(ref, "referee", 0.9)] },
            hoop: { _ in [] }, courtQuads: { _ in [] }, numbers: { _, _ in [] }, pose: { _, _, _ in nil },
            torsoColor: { _, box in box.minX < 0.5 ? SIMD3(0.9, 0.9, 0.9) : SIMD3(0.1, 0.1, 0.1) })
        let e = Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                       calibration: nil, isGame: false, attackingTeam: "A", rimAnchors: [:], initialRims: [:])
        var m = e.process(blank(), pts: 0)
        for i in 1..<8 { m = e.process(blank(), pts: Double(i) / 8) }
        XCTAssertEqual(m.players.map(\.team), ["A", "B"])          // white → A, black → B
        XCTAssertEqual(m.referees, [ref])
        e.teamsSwapped = true
        XCTAssertEqual(e.process(blank(), pts: 1).players.map(\.team), ["B", "A"])
    }
}
