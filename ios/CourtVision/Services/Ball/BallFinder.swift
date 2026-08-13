import CoreGraphics
import CoreVideo
import Foundation

/// Ball acquisition (BALL MODULE) — same mechanism as the rim: the trained
/// YOLO detector finds candidates, and continuity gating (nearest-within an
/// anchor) keeps the track glued to THE game ball instead of jumping to
/// other balls, heads, or false positives.
///
/// Detection only for now — shot decisions come later, built on top of a
/// track proven good in the field (exactly how the rim was validated).
enum BallFinder {
    /// Labeled ball detections in one frame, best-confidence first. Lower
    /// confidence floor than the rim: the ball is small, fast, and often
    /// motion-blurred; the continuity gate does the filtering.
    /// `ball-in-basket` is a STATE of the ball — the label rides along so
    /// make/miss logic can read it from the track.
    static func detectBalls(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [Detection] {
        ObjectDetector.ball?.detect(labels: ["ball", "ball-in-basket", "Basketball", "basketball", "sports ball"],
                                      in: pixelBuffer,
                                      maxCount: maxCount, minConfidence: 0.25) ?? []
    }

    /// Which detected ball is THE ball: nearest to `anchor` (the last tracked
    /// position). No anchor → most confident (first). `within` caps the
    /// accepted distance so a second ball or a bald head across the frame
    /// can't steal the track. (Same rule as RimFinder.pickRim — duplicated
    /// on purpose: modules stay independently testable.)
    static func pickBall(candidates: [Detection], near anchor: CGPoint?,
                         within maxDistance: CGFloat? = nil) -> Detection? {
        guard let anchor else { return candidates.first }
        let nearest = candidates.min {
            hypot($0.box.midX - anchor.x, $0.box.midY - anchor.y)
                < hypot($1.box.midX - anchor.x, $1.box.midY - anchor.y)
        }
        if let maxDistance, let nearest,
           hypot(nearest.box.midX - anchor.x, nearest.box.midY - anchor.y) > maxDistance {
            return nil
        }
        return nearest
    }
}

/// Live ball track: recent positions with timestamps (the on-screen trail
/// and the raw material for the future shot pipeline).
struct BallTrack {
    struct Sample: Equatable {
        let point: CGPoint      // box center, normalized top-left
        let box: CGRect
        let label: String       // "ball" or "ball-in-basket" (state)
        let at: Date
    }

    private(set) var samples: [Sample] = []
    /// Seconds a track survives without a fresh detection before it resets —
    /// past that, a new detection is a new possession, not the same flight.
    var maxGap: TimeInterval = 1.0
    /// Trail length kept for drawing / analysis.
    var maxAge: TimeInterval = 1.5

    var last: Sample? { samples.last }

    /// Feed one detection (or nil when nothing was found this tick).
    mutating func update(with detection: Detection?, at now: Date = Date()) {
        if let lastAt = samples.last?.at, now.timeIntervalSince(lastAt) > maxGap {
            samples.removeAll()
        }
        if let detection {
            samples.append(Sample(point: CGPoint(x: detection.box.midX, y: detection.box.midY),
                                  box: detection.box, label: detection.label, at: now))
        }
        samples.removeAll { now.timeIntervalSince($0.at) > maxAge }
    }
}
