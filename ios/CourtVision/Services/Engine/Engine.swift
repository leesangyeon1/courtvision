import CoreGraphics
import CoreVideo
import Foundation

/// The single-clock pipeline: ONE unified inference per tick keyed to the
/// frame's presentation time; the rim / ball / player / court modules are fed
/// from it and one `Moment` comes out. No module owns a loop or a clock.
///
/// Lanes: every tick → ball + players (+ numbers every `numberEvery` ticks);
/// every `slowEvery` ticks → HoopDetector ∪ unified rim, court rectangles.
/// Rims and courts don't move — the camera does.
final class Engine {
    struct Config {
        /// Ticks per second. Set from the P0 cost table (docs/EVAL.md); a
        /// serious/critical thermal state halves it.
        var tickHz: Double = 8
        /// Rim + court every N ticks (≈1 Hz at 8 Hz).
        var slowEvery: Int = 8
        /// Jersey OCR every N ticks (≈2 Hz at 8 Hz).
        var numberEvery: Int = 4
    }

    /// Detector seam: real models in the app, synthetic closures in tests.
    struct Detectors {
        var unified: (CVPixelBuffer) -> [Detection]
        var hoop: (CVPixelBuffer) -> [CGRect]
        var courtQuads: (CVPixelBuffer) -> [[CGPoint]]
        var numbers: ([CGRect], CVPixelBuffer) -> [(point: CGPoint, digits: String)]

        static let live = Detectors(
            unified: { ObjectDetector.unified?.detectAll(in: $0, minConfidence: 0.25) ?? [] },
            hoop: { ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"], in: $0,
                                                maxCount: 4, minConfidence: 0.30).map(\.box) ?? [] },
            courtQuads: { CourtFinder.detectCourtQuadCandidates(in: $0) },
            numbers: { NumberReader.read(regions: $0, in: $1) })
    }

    var config: Config
    let detectors: Detectors
    let isGame: Bool
    /// Team attacking the hoop in frame; flips on a far court jump (game mode).
    var attackingTeam: String

    private(set) var rim: RimTracker
    private(set) var court: CourtEstimator
    private var ballTrack = BallTrack()
    private var playerTracker = PlayerTracker()
    private var tickCount = 0
    private var lastTickPts: Double = -.infinity
    private(set) var lastMoment: Moment?
    /// True when the last `process` flipped `attackingTeam`.
    private(set) var flippedThisTick = false
    /// `process` runs on the frame loop, `designateRim` on the main actor.
    private let lock = NSLock()

    var ballTrail: [BallTrack.Sample] { lock.withLock { ballTrack.samples } }
    /// Ticks a player track survives unmatched: 2 s at the tick rate.
    var playerMaxMissedTicks: Int { playerTracker.maxMissedTicks }

    init(config: Config = Config(), detectors: Detectors = .live,
         calibration: Calibration?, isGame: Bool, attackingTeam: String,
         rimAnchors: [String: CGPoint], initialRim: CGRect?) {
        self.config = config
        self.detectors = detectors
        self.isGame = isGame
        self.attackingTeam = attackingTeam
        rim = RimTracker(rim: initialRim, anchors: rimAnchors)
        court = CourtEstimator(calibration: calibration)
        playerTracker.maxMissedTicks = Int((2.0 * config.tickHz).rounded())
    }

    /// Whether a frame at `pts` is due: throttle to `tickHz`, halved when the
    /// device is hot (modules are never dropped, only the rate).
    func shouldTick(at pts: Double,
                    thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Bool {
        let hz = (thermal == .serious || thermal == .critical) ? config.tickHz / 2 : config.tickHz
        return pts - lastTickPts >= 1.0 / hz - 1e-6
    }

    /// One tick. Call only when `shouldTick` said so.
    func process(_ pixelBuffer: CVPixelBuffer, pts: Double) -> Moment {
        lock.lock(); defer { lock.unlock() }
        lastTickPts = pts
        tickCount += 1
        flippedThisTick = false

        let all = detectors.unified(pixelBuffer)

        // ---- slow lane: rim + court ------------------------------------
        if tickCount % config.slowEvery == 1 || config.slowEvery == 1 {
            let unifiedRims = all.filter { $0.label == "rim" && $0.confidence >= 0.30 }.map(\.box)
            var candidates = RimFinder.merge(hoop: detectors.hoop(pixelBuffer),
                                             unified: unifiedRims, maxCount: 4)
            if candidates.isEmpty {
                candidates = RimFinder.detectRimsByColor(in: pixelBuffer, maxCount: 4)
            }
            rim.update(candidates: candidates, attackingTeam: attackingTeam, pts: pts)
            if court.update(quadCandidates: detectors.courtQuads(pixelBuffer), rim: rim.rim,
                            isGame: isGame, pts: pts) {
                attackingTeam = attackingTeam == "A" ? "B" : "A"
                flippedThisTick = true
            }
        }

        // ---- ball: continuity gate scales with the gap since last sighting
        let anchor = ballTrack.last?.point
        let gap = ballTrack.last.map { pts - $0.at.timeIntervalSinceReferenceDate } ?? .infinity
        let reach: CGFloat? = anchor == nil ? nil : min(0.15 + 0.35 * gap, 0.5)
        let chosen = BallFinder.pickBall(candidates: BallFinder.balls(from: all), near: anchor, within: reach)
        ballTrack.update(with: chosen, at: Date(timeIntervalSinceReferenceDate: pts))

        // ---- players: detect → track → numbers → classify ---------------
        let family = PlayerFinder.playerFamily(from: all)
        playerTracker.update(with: PlayerFinder.corePlayers(family))
        if tickCount % config.numberEvery == 0 {
            let regions = all.filter { $0.label == "number" && $0.confidence >= 0.30 }.map(\.box)
            if !regions.isEmpty { playerTracker.assign(numbers: detectors.numbers(regions, pixelBuffer)) }
        }
        let tracks = ActionClassifier.classify(states: PlayerFinder.states(family),
                                               tracks: playerTracker.tracks)

        // ---- moment ------------------------------------------------------
        let h = court.h
        func toCourt(_ p: CGPoint) -> (Double?, Double?) {
            guard let h else { return (nil, nil) }
            let q = h.apply(p)
            return (Double(q.x), Double(q.y))
        }
        let moment = Moment(
            pts: pts, h: h, rim: rim.rim,
            players: tracks.map { t in
                let feet = CGPoint(x: t.box.midX, y: t.box.maxY)
                let (x, y) = toCourt(feet)
                return Moment.PlayerState(trackId: t.id, team: nil, box: t.box, feet: feet,
                                          xFt: x, yFt: y, action: t.action,
                                          actionConfidence: t.actionConfidence, number: t.number)
            },
            ball: ballTrack.last.map { s in
                let (x, y) = toCourt(s.point)
                return Moment.BallState(box: s.box, label: s.label, xFt: x, yFt: y)
            })
        lastMoment = moment
        return moment
    }

    /// Tap on the preview = "track THIS hoop" (see `RimTracker.designate`).
    func designateRim(at point: CGPoint) {
        lock.withLock {
            rim.designate(at: point, attackingTeam: attackingTeam, pts: max(lastTickPts, 0))
        }
    }
}
