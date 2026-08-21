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
        var tickHz: Double = 6
        /// Rim + court every N ticks (≈1 Hz at 6 Hz).
        var slowEvery: Int = 6
        /// Jersey OCR every N ticks (≈2 Hz at 6 Hz).
        var numberEvery: Int = 3
        /// Second unified pass on the far band every N ticks (0 = off). The
        /// far court gets ~2× the pixels per player: +2 people/tick on the
        /// gym clip (docs/EVAL.md). One extra inference on those ticks.
        var farEvery: Int = 2
        /// Fallback far ROI until the court fit yields computed tiles
        /// (normalized, top-left origin).
        var farBand = CGRect(x: 0.15, y: 0.10, width: 0.70, height: 0.50)
        /// Computed tiles across the court length (spec open question: 2 vs
        /// 3; 3 = 0.75× scale on a 4K frame — decide from measurement).
        var tileCount = 3
        /// Ticks an unmatched track is still drawn at its last box.
        var drawGraceTicks = 2
    }

    /// Detector seam: real models in the app, synthetic closures in tests.
    struct Detectors {
        /// Unified model; a non-nil ROI runs it on that region only.
        var unified: (CVPixelBuffer, CGRect?) -> [Detection]
        var hoop: (CVPixelBuffer) -> [CGRect]
        var courtQuads: (CVPixelBuffer) -> [[CGPoint]]
        var numbers: ([CGRect], CVPixelBuffer) -> [(box: CGRect, digits: String)]
        var pose: (CVPixelBuffer, CGRect, Double) -> PoseReader.Sample?
        var torsoColor: (CVPixelBuffer, CGRect) -> SIMD3<Float>?

        static let live = Detectors(
            unified: { ObjectDetector.unified?.detectAll(in: $0, minConfidence: 0.25, roi: $1) ?? [] },
            hoop: { ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"], in: $0,
                                                maxCount: 4, minConfidence: 0.30).map(\.box) ?? [] },
            courtQuads: { CourtFinder.detectCourtQuadCandidates(in: $0) },
            numbers: { NumberReader.read(regions: $0, in: $1) },
            pose: { PoseReader.read(in: $0, roi: $1, pts: $2) },
            torsoColor: { TeamAssigner.torsoColor(in: $0, box: $1) })
    }

    var config: Config
    let detectors: Detectors
    let isGame: Bool
    /// Team attacking the hoop in frame; follows the single locked rim's end.
    var attackingTeam: String

    private(set) var rim: RimTracker
    private(set) var court: CourtEstimator
    /// Computed far-lane ROIs (from the court fit); empty → guessed band.
    private(set) var tiles: [CGRect] = []
    private var tileIndex = 0
    private var ballTrack = BallTrack()
    private var playerTracker = PlayerTracker()
    private var refereeTracker = PlayerTracker()
    private var feet = FeetHistory()
    private var teams = TeamAssigner()
    private var tickCount = 0
    private var lastTickPts: Double = -.infinity
    private(set) var lastMoment: Moment?
    /// True when the last `process` flipped `attackingTeam`.
    private(set) var flippedThisTick = false
    /// `process` runs on the frame loop, `designateRim` on the main actor.
    private let lock = NSLock()

    var ballTrail: [BallTrack.Sample] { lock.withLock { ballTrack.samples } }
    /// Flip which jersey cluster is team A (the ⇄ Teams button).
    var teamsSwapped: Bool {
        get { lock.withLock { teams.swapped } }
        set { lock.withLock { teams.swapped = newValue } }
    }
    /// Ticks a player track survives unmatched: 2 s at the tick rate.
    var playerMaxMissedTicks: Int { playerTracker.maxMissedTicks }

    init(config: Config = Config(), detectors: Detectors = .live,
         calibration: Calibration?, isGame: Bool, attackingTeam: String,
         rimAnchors: [String: CGPoint], initialRims: [String: CGRect]) {
        self.config = config
        self.detectors = detectors
        self.isGame = isGame
        self.attackingTeam = attackingTeam
        rim = RimTracker(rims: initialRims, anchors: rimAnchors)
        court = CourtEstimator(calibration: calibration)
        for keyPath in [\Engine.playerTracker, \Engine.refereeTracker] {
            self[keyPath: keyPath].maxMissedTicks = Int((2.0 * config.tickHz).rounded())
            self[keyPath: keyPath].tickSeconds = 1.0 / config.tickHz
        }
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

        var all = detectors.unified(pixelBuffer, nil)
        // ---- far lane: one computed tile per pass, round-robin (A→B→C…);
        // the guessed band until the court fit gives real tiles.
        if config.farEvery > 0, tickCount % config.farEvery == 1 || config.farEvery == 1 {
            let roi: CGRect
            if tiles.isEmpty {
                roi = config.farBand
            } else {
                roi = tiles[tileIndex % tiles.count]
                tileIndex += 1
            }
            all += detectors.unified(pixelBuffer, roi)
            all.sort { $0.confidence > $1.confidence }
        }

        // ---- slow lane: rim + court ------------------------------------
        if tickCount % config.slowEvery == 1 || config.slowEvery == 1 {
            let unifiedRims = all.filter { $0.label == "rim" && $0.confidence >= 0.30 }.map(\.box)
            var candidates = RimFinder.merge(hoop: detectors.hoop(pixelBuffer),
                                             unified: unifiedRims, maxCount: 4)
            if candidates.isEmpty {
                candidates = RimFinder.detectRimsByColor(in: pixelBuffer, maxCount: 4)
            }
            rim.update(candidates: candidates, pts: pts)
            court.update(quadCandidates: detectors.courtQuads(pixelBuffer),
                         rims: rim.trackedEnds.compactMap { rim.rims[$0] })
            // Tiles follow the fit's lifecycle: computed when locked, gone when not.
            if court.locked, let h = court.h, tiles.isEmpty {
                tiles = CourtEstimator.tiles(h: h, count: config.tileCount,
                                             lengthFt: court.fullCourt ? ZoneMapper.fullCourtLengthFt
                                                                       : ZoneMapper.courtDepthFt)
            } else if !court.locked {
                tiles = []
            }
            // Which end is in play: exactly one locked rim says so outright
            // (the camera is looking at that hoop). Both locked → per-shot.
            if rim.trackedEnds.count == 1, let only = rim.trackedEnds.first, only != attackingTeam {
                attackingTeam = only
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

        // ---- pose: only the ball handler / shooter, ROI only --------------
        for t in tracks where t.action == .possession || t.action == .jumpShot || t.action == .layupDunk {
            if let s = detectors.pose(pixelBuffer, t.box, pts) { feet.add(s, track: t.id, now: pts) }
        }
        feet.prune(keeping: Set(tracks.map(\.id)))

        // ---- teams: jersey color of every player seen this tick ------------
        let liveTracks = tracks.filter { $0.missedTicks == 0 }
        let drawnTracks = tracks.filter { $0.missedTicks <= config.drawGraceTicks }
        for t in liveTracks {
            if let c = detectors.torsoColor(pixelBuffer, t.box) { teams.observe(track: t.id, color: c) }
        }
        teams.forget(except: Set(tracks.map(\.id)))
        refereeTracker.update(with: PlayerFinder.dedupe(PlayerFinder.shapeFiltered(
            all.filter { $0.label == "referee" && $0.confidence >= 0.30 })))
        let referees = refereeTracker.tracks.filter { $0.missedTicks <= config.drawGraceTicks }.map(\.box)

        // ---- moment ------------------------------------------------------
        let h = court.h
        func toCourt(_ p: CGPoint) -> (Double?, Double?) {
            guard let h else { return (nil, nil) }
            let q = h.apply(p)
            return (Double(q.x), Double(q.y))
        }
        // Tracks seen this tick go out, plus a short draw grace (≤ 2 ticks at
        // the last box, marked `missedTicks`) so a one-tick flicker doesn't
        // blink; beyond that an unmatched track is not emitted (stale box).
        let rims = rim.rims
        var farEnds: Set<String> = []
        if court.fullCourt, let h {
            for (end, box) in rims where Double(h.apply(CGPoint(x: box.midX, y: box.midY)).y) > ZoneMapper.courtDepthFt {
                farEnds.insert(end)
            }
        }
        let moment = Moment(
            pts: pts, h: h, rims: rims,
            players: drawnTracks.map { t in
                let feet = self.feet.groundContact(track: t.id) ?? CGPoint(x: t.box.midX, y: t.box.maxY)
                let (x, y) = toCourt(feet)
                return Moment.PlayerState(trackId: t.id, team: teams.team(of: t.id), box: t.box, feet: feet,
                                          xFt: x, yFt: y, action: t.action,
                                          actionConfidence: t.actionConfidence, number: t.number,
                                          missedTicks: t.missedTicks)
            },
            ball: ballTrack.last.map { s in
                let (x, y) = toCourt(s.point)
                return Moment.BallState(box: s.box, label: s.label, xFt: x, yFt: y)
            },
            referees: referees, fullCourt: court.fullCourt, farEnds: farEnds)
        lastMoment = moment
        return moment
    }

    /// Tap on the preview = "track THIS hoop" (see `RimTracker.designate`).
    /// Returns the end the tap went to.
    @discardableResult
    func designateRim(at point: CGPoint) -> String {
        lock.withLock { rim.designate(at: point, pts: max(lastTickPts, 0)) }
    }
}
