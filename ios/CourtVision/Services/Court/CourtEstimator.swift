import CoreGraphics

/// Court fit (COURT MODULE) for a FIXED camera: solve once from rectangle
/// candidates scored against the locked rims, then hold the fit and only
/// drift-check it (project the rims through the stored H; three consecutive
/// bad checks = the tripod moved → drop the fit and re-solve). A stale fit
/// is never used — no fake coordinates. One rim → half-court fit; two rims
/// → full-court fit (both hoops score).
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
    /// True once a fit is accepted; drift-checks may clear it.
    private(set) var locked = false
    private var driftStrikes = 0

    /// Accept a fit only when the rims project within this many feet of the hoops.
    var maxFitFt: Double = 15
    /// Drift check: a projected rim farther than this from its hoop is a strike.
    var driftFt: Double = 20
    /// Consecutive strikes before the fit is dropped (occlusion ≠ drift).
    var driftStrikeLimit = 3

    init(calibration: Calibration?) {
        h = calibration.flatMap { Homography(matrix: $0.homography) }
        quad = calibration?.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        } ?? []
    }

    /// Solved-once fit is stale (tripod bump, manual recalibrate): drop it.
    mutating func invalidate() {
        locked = false
        driftStrikes = 0
        h = nil
        fitFt = nil
    }

    /// Returns true when a new fit was accepted this tick. While locked this
    /// only drift-checks — the camera is fixed, the fit doesn't change.
    @discardableResult
    mutating func update(quadCandidates: [[CGPoint]], rims: [CGRect]) -> Bool {
        guard !rims.isEmpty else { return false }
        if locked {
            driftCheck(rims: rims)
            return false
        }
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
        locked = true
        driftStrikes = 0
        return true
    }

    /// Project the tracked rims through the stored fit: they must still land
    /// near a hoop. `driftStrikeLimit` consecutive misses = camera moved.
    private mutating func driftCheck(rims: [CGRect]) {
        guard let h else { return }
        let d = fullCourt ? ZoneMapper.fullCourtLengthFt : ZoneMapper.courtDepthFt
        let hoops = fullCourt
            ? [CGPoint(x: ZoneMapper.rimXFt, y: ZoneMapper.rimYFt),
               CGPoint(x: ZoneMapper.rimXFt, y: d - ZoneMapper.rimYFt)]
            : [CGPoint(x: ZoneMapper.rimXFt, y: ZoneMapper.rimYFt)]
        let worst = rims.map { rim -> Double in
            let p = h.apply(CGPoint(x: rim.midX, y: rim.midY))
            return hoops.map { hypot(Double(p.x - $0.x), Double(p.y - $0.y)) }.min() ?? .infinity
        }.max() ?? 0
        if worst > driftFt {
            driftStrikes += 1
            if driftStrikes >= driftStrikeLimit { invalidate() }
        } else {
            driftStrikes = 0
        }
    }

    // ------------------------------------------------------------- tiles

    /// ROI tiles for the far-detail lane, computed from the fit: split the
    /// court length into `count` zones in FEET, project each zone's corners
    /// back to image space (H⁻¹), pad 10 %, clamp to frame. Empty when the
    /// fit can't be inverted (caller falls back to the guessed band).
    static func tiles(h: Homography, count: Int, lengthFt: Double,
                      widthFt: Double = ZoneMapper.courtWidthFt) -> [CGRect] {
        guard count > 0, let inv = h.inverted() else { return [] }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        var out: [CGRect] = []
        for i in 0..<count {
            let y0 = lengthFt * Double(i) / Double(count)
            let y1 = lengthFt * Double(i + 1) / Double(count)
            let corners = [CGPoint(x: 0, y: y0), CGPoint(x: widthFt, y: y0),
                           CGPoint(x: 0, y: y1), CGPoint(x: widthFt, y: y1)].map(inv.apply)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            var tile = CGRect(x: xs.min()!, y: ys.min()!,
                              width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            tile = tile.insetBy(dx: -tile.width * 0.1, dy: -tile.height * 0.1).intersection(frame)
            guard !tile.isEmpty, tile.width > 0.01, tile.height > 0.01 else { return [] }
            out.append(tile)
        }
        return out.sorted { $0.midX < $1.midX }
    }
}
