import CoreGraphics

/// Continuous court estimate (COURT MODULE) on the engine clock: each slow
/// tick the rectangle candidates are scored against the tracked rim and the
/// best fit replaces the homography. Never a hard lock — the camera pans all
/// game. In game mode a far quad jump = the camera swung to the other hoop.
struct CourtEstimator {
    private(set) var h: Homography?
    /// Last accepted image quad [near-left, far-left, near-right, far-right].
    private(set) var quad: [CGPoint]
    /// Court-feet targets parallel to `quad` (for persisting the calibration).
    private(set) var courtPoints: [CGPoint] = []
    /// Mean rim-projection error of the accepted fit, feet (nil = seeded only).
    private(set) var fitFt: Double?
    private var lastFlipPts: Double = -.infinity

    /// Accept a fit only when the rim projects within this many feet of the hoop.
    var maxFitFt: Double = 15
    /// Mean corner move (fraction of frame) that counts as "swung to the other end".
    var jumpDelta: CGFloat = 0.2
    /// Seconds between flips while the pan settles.
    var flipCooldown: Double = 5

    init(calibration: Calibration?) {
        h = calibration.flatMap { Homography(matrix: $0.homography) }
        quad = calibration?.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        } ?? []
    }

    /// Returns true when the court jumped far enough to mean a possession
    /// switch (game mode only) — the caller flips the attacking team.
    mutating func update(quadCandidates: [[CGPoint]], rim: CGRect?, isGame: Bool, pts: Double) -> Bool {
        guard let rim,
              let best = CourtFinder.bestQuad(candidates: quadCandidates, rims: [rim], fullCourt: false),
              best.score <= maxFitFt,
              let pick = CourtFinder.scoreCourtAssignments(quad: best.quad, rims: [rim], fullCourt: false),
              let fit = Homography(from: best.quad, to: pick.courtPoints) else { return false }

        var flipped = false
        if isGame, !quad.isEmpty {
            let meanDelta = zip(best.quad, quad)
                .map { hypot($0.x - $1.x, $0.y - $1.y) }
                .reduce(0, +) / CGFloat(quad.count)
            if meanDelta > jumpDelta, pts - lastFlipPts > flipCooldown {
                flipped = true
                lastFlipPts = pts
            }
        }
        h = fit
        quad = best.quad
        courtPoints = pick.courtPoints
        fitFt = best.score
        return flipped
    }
}
