import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Court acquisition (COURT MODULE): candidate quads from rectangle
/// detection, rim-consistency scoring (NEX patent style), and multi-frame
/// stability voting. The court is a continuously refreshed ESTIMATE during
/// recording — the camera pans all game, so nothing here is a physical lock.
enum CourtFinder {
    // All outputs are normalized buffer coordinates, TOP-LEFT origin.

    // ------------------------------------------------------------- court
    /// All candidate court quads in the frame, each ordered [near-left,
    /// far-left, near-right, far-right]. Busy gym floors produce several
    /// rectangles — the CALLER scores them against the detected rim
    /// (bestQuad) instead of trusting "biggest wins".
    static func detectCourtQuadCandidates(in pixelBuffer: CVPixelBuffer) -> [[CGPoint]] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.10   // sideline courts are very wide
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 45    // strong perspective skew is fine
        request.minimumSize = 0.15          // gyms: court often partly occluded
        request.minimumConfidence = 0.3
        request.maximumObservations = 6

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return (request.results ?? [])
            .sorted { area($0) > area($1) }
            .compactMap { quad in
                // Vision corners are bottom-left origin; flip to top-left.
                let corners = [quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight]
                    .map { CGPoint(x: $0.x, y: 1 - $0.y) }
                return orderCourtCorners(corners)
            }
    }

    /// Best candidate quad by rim-projection score (lower = better). Nil when
    /// no candidate passes the plausibility gate.
    static func bestQuad(candidates: [[CGPoint]], rims: [CGRect],
                         fullCourt: Bool) -> (quad: [CGPoint], score: Double)? {
        var best: (quad: [CGPoint], score: Double)?
        for quad in candidates {
            guard let pick = scoreCourtAssignments(quad: quad, rims: rims, fullCourt: fullCourt)
            else { continue }
            if best == nil || pick.score < best!.score { best = (quad, pick.score) }
        }
        return best
    }


    /// Orders 4 corners as [near-left, far-left, near-right, far-right]:
    /// the two lowest on screen (larger y) are the near-sideline pair.
    static func orderCourtCorners(_ corners: [CGPoint]) -> [CGPoint]? {
        guard corners.count == 4 else { return nil }
        let byY = corners.sorted { $0.y > $1.y }           // nearest first
        let near = byY[0...1].sorted { $0.x < $1.x }       // left, right
        let far = byY[2...3].sorted { $0.x < $1.x }
        return [near[0], far[0], near[1], far[1]]
    }

    private static func area(_ o: VNRectangleObservation) -> CGFloat {
        o.boundingBox.width * o.boundingBox.height
    }

    // ------------------------------------------------- stability + scoring
    /// Rolling-window vote: the last `need` quads must agree corner-wise
    /// within `tol` (normalized units). Returns the averaged quad, else nil.
    /// Locking on a single frame ships flicker; HomeCourt's patent refines
    /// continuously — this is the minimal on-device version.
    static func stableQuad(_ history: [[CGPoint]], need: Int = 3, tol: CGFloat = 0.02) -> [CGPoint]? {
        guard history.count >= need else { return nil }
        let recent = Array(history.suffix(need))
        guard recent.allSatisfy({ $0.count == 4 }) else { return nil }
        let base = recent[0]
        for quad in recent.dropFirst() {
            for i in 0..<4 where abs(quad[i].x - base[i].x) > tol || abs(quad[i].y - base[i].y) > tol {
                return nil
            }
        }
        return (0..<4).map { i in
            CGPoint(x: recent.map(\.[i].x).reduce(0, +) / CGFloat(recent.count),
                    y: recent.map(\.[i].y).reduce(0, +) / CGFloat(recent.count))
        }
    }

    /// NEX-patent-style candidate scoring (US11594029): the detected court
    /// quad has ambiguous orientation — which edge is a baseline? Try every
    /// corner→court assignment, project the DETECTED rims through each
    /// candidate homography, and keep the one that lands them nearest the
    /// real hoop positions. Returns nil when even the best fit is
    /// implausible (bad quad or bad rims — caller keeps scanning).
    ///
    /// `quad` is in landmark order [near-left, far-left, near-right,
    /// far-right]; the returned courtPoints array is parallel to it.
    /// Score is mean rim-projection error in feet. maxError is generous
    /// because the rim sits 10 ft above the floor plane, so its projection
    /// lands beyond the true hoop position.
    static func scoreCourtAssignments(quad: [CGPoint], rims: [CGRect], fullCourt: Bool,
                                      maxError: Double = 25) -> (courtPoints: [CGPoint], score: Double)? {
        guard quad.count == 4, !rims.isEmpty else { return nil }
        let w = ZoneMapper.courtWidthFt
        let d = fullCourt ? ZoneMapper.fullCourtLengthFt : ZoneMapper.courtDepthFt
        let hoops = fullCourt
            ? [CGPoint(x: 25, y: 5.25), CGPoint(x: 25, y: d - 5.25)]
            : [CGPoint(x: 25, y: 5.25)]
        // Corner→court candidates, parallel to [NL, FL, NR, FR]:
        // left / right / near / far edge as the (first) baseline.
        let candidates: [[CGPoint]] = [
            [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: d), CGPoint(x: w, y: d)],
            [CGPoint(x: 0, y: d), CGPoint(x: w, y: d), CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: d), CGPoint(x: w, y: 0), CGPoint(x: w, y: d)],
            [CGPoint(x: 0, y: d), CGPoint(x: 0, y: 0), CGPoint(x: w, y: d), CGPoint(x: w, y: 0)],
        ]
        var best: (courtPoints: [CGPoint], score: Double)?
        for cand in candidates {
            guard let h = Homography(from: quad, to: cand) else { continue }
            let errs = rims.map { rim -> Double in
                let p = h.apply(CGPoint(x: rim.midX, y: rim.midY))
                return hoops.map { hypot(Double(p.x - $0.x), Double(p.y - $0.y)) }.min() ?? .infinity
            }
            let score = errs.reduce(0, +) / Double(errs.count)
            if best == nil || score < best!.score { best = (cand, score) }
        }
        guard let best, best.score <= maxError else { return nil }
        return best
    }

}
