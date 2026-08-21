import CoreGraphics

/// Continuous court estimate (COURT MODULE) on the engine clock: each slow
/// tick the rectangle candidates are scored against the locked rims and the
/// best fit replaces the homography. Never a hard lock — the camera pans all
/// game. One rim → half-court fit; two rims → full-court fit (both hoops
/// score). Which end is in play is the rim tracker's call, not the court's.
struct CourtEstimator {
    private(set) var h: Homography?
    /// Last accepted image quad [near-left, far-left, near-right, far-right].
    private(set) var quad: [CGPoint]
    /// Court-feet targets parallel to `quad` (for persisting the calibration).
    private(set) var courtPoints: [CGPoint] = []
    /// Mean rim-projection error of the accepted fit, feet (nil = seeded only).
    private(set) var fitFt: Double?
    /// True when the accepted fit maps to the full 94-ft court (two rims).
    private(set) var fullCourt = false

    /// Accept a fit only when the rims project within this many feet of the hoops.
    var maxFitFt: Double = 15

    init(calibration: Calibration?) {
        h = calibration.flatMap { Homography(matrix: $0.homography) }
        quad = calibration?.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        } ?? []
    }

    /// Returns true when a new fit was accepted this tick.
    @discardableResult
    mutating func update(quadCandidates: [[CGPoint]], rims: [CGRect]) -> Bool {
        guard !rims.isEmpty else { return false }
        let full = rims.count >= 2
        guard let best = CourtFinder.bestQuad(candidates: quadCandidates, rims: rims, fullCourt: full),
              best.score <= maxFitFt,
              let pick = CourtFinder.scoreCourtAssignments(quad: best.quad, rims: rims, fullCourt: full),
              let fit = Homography(from: best.quad, to: pick.courtPoints) else { return false }
        h = fit
        quad = best.quad
        courtPoints = pick.courtPoints
        fitFt = best.score
        fullCourt = full
        return true
    }
}
