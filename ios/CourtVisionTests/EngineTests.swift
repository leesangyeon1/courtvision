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
            pose: { _, _, _ in nil })
        return Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                      calibration: calibration, isGame: isGame, attackingTeam: "A",
                      rimAnchors: [:], initialRim: nil)
    }

    func testOneTickBuildsMomentWithRimCourtBallAndProjectedFeet() {
        let e = engine()
        let m = e.process(blank(), pts: 0)
        XCTAssertEqual(m.pts, 0)
        XCTAssertNotNil(m.rim)                     // slow lane ran on tick 1: unified rim → tracker
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

    func testCourtJumpFlipsAttackingTeamInGameMode() {
        let shifted = quad.map { CGPoint(x: $0.x, y: $0.y - 0.3) }
        let cal = Calibration(homography: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                              imagePoints: shifted.map { [Double($0.x), Double($0.y)] },
                              courtPoints: [])
        let e = engine(isGame: true, calibration: cal)
        _ = e.process(blank(), pts: 0)
        XCTAssertTrue(e.flippedThisTick)
        XCTAssertEqual(e.attackingTeam, "B")
    }

    func testFeetComeFromPoseGroundContactWhenShooting() {
        // Tick 1: possession on the floor (ankles low). Tick 2: jump shot in the air.
        var tick = 0
        let boxes = [CGRect(x: 0.47, y: 0.28, width: 0.06, height: 0.22),      // bottom 0.50
                     CGRect(x: 0.47, y: 0.20, width: 0.06, height: 0.22)]      // bottom 0.42 (airborne)
        let states = ["player-in-possession", "player-jump-shot"]
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(boxes[tick], "player", 0.9), self.det(boxes[tick], states[tick], 0.8)] },
            hoop: { _ in [] }, courtQuads: { _ in [] }, numbers: { _, _ in [] },
            pose: { _, box, pts in PoseReader.Sample(pts: pts, ankleMid: CGPoint(x: box.midX, y: box.maxY - 0.01)) })
        let e = Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                       calibration: nil, isGame: false, attackingTeam: "A", rimAnchors: [:], initialRim: nil)
        _ = e.process(blank(), pts: 0)
        tick = 1
        let m = e.process(blank(), pts: 0.125)
        XCTAssertEqual(m.players[0].action, .jumpShot)
        XCTAssertEqual(m.players[0].feet.y, 0.49, accuracy: 1e-6)     // the floor sample, not the airborne box
    }

    func testDesignateRimSnapsAndAnchors() {
        let e = engine()
        _ = e.process(blank(), pts: 0)
        e.designateRim(at: CGPoint(x: 0.2, y: 0.5))       // within 0.12 of the unified rim → snaps
        XCTAssertEqual(e.rim.rim?.midX ?? 0, rim.midX, accuracy: 1e-9)
        XCTAssertEqual(e.rim.anchors["A"], CGPoint(x: 0.2, y: 0.5))
    }
}
