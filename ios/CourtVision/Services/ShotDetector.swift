import CoreGraphics
import Foundation

/// A decided shot attempt, emitted exactly once per ball flight.
struct DetectedShot {
    /// Timestamp of the first trajectory point (≈ release), capture clock.
    let timestamp: TimeInterval
    let made: Bool
    /// Release point, normalized image coords, top-left origin.
    let releasePoint: CGPoint
    /// True when the ball was released inside the expanded rim region
    /// (dunk signal for the category heuristic).
    let releaseAtRim: Bool
    /// Launch angle in degrees above horizontal, from the trajectory parabola
    /// evaluated at the release point (positive = upward).
    let releaseAngleDeg: Double
    /// Not derivable in V1 (needs catch detection); always nil for now.
    let releaseTimeMs: Double?
    let confidence: Double
}

/// Make/miss state machine over ball trajectories relative to the rim box.
///
/// All geometry is in normalized image coordinates with a TOP-LEFT origin, so
/// downward motion means increasing y.
///
/// - MADE: the trajectory enters the expanded rim region from above with
///   downward velocity and later exits BELOW the rim box within its x-span.
/// - MISS: the trajectory reaches the rim/backboard neighbourhood but then
///   diverges (leaves the region sideways/upward), or passes it without a
///   through-the-rim exit.
/// - Debounce: each Vision trajectory id is decided at most once, and after
///   any emitted event further decisions are suppressed for `cooldown`
///   seconds → one shot, one event.
final class ShotDetector {
    /// Current rim box (normalized, top-left origin). Set from the calibration.
    var rimRect: CGRect?
    /// Called (on the vision queue) once per decided shot.
    var onShot: ((DetectedShot) -> Void)?
    var cooldown: TimeInterval = 1.5

    private var lastEmit: TimeInterval = -.greatestFiniteMagnitude
    private var decidedTrajectories: Set<UUID> = []

    func ingest(_ t: TrajectoryUpdate) {
        guard let rim = rimRect,
              t.points.count >= 3,
              !decidedTrajectories.contains(t.id) else { return }
        let now = t.timestamps.last ?? 0
        guard now - lastEmit >= cooldown else { return }

        let expanded = rim.insetBy(dx: -rim.width * 0.75, dy: -rim.height * 0.75)

        var enteredFromAbove = false
        var madeExit = false
        var wasInsideExpanded = false

        for i in 0..<t.points.count {
            let p = t.points[i]
            if expanded.contains(p) { wasInsideExpanded = true }

            if !enteredFromAbove, i > 0, expanded.contains(p) {
                let prev = t.points[i - 1]
                // downward velocity + came from above the region
                if p.y > prev.y, prev.y < expanded.midY {
                    enteredFromAbove = true
                }
            }

            if enteredFromAbove,
               p.y > rim.maxY,
               p.x >= rim.minX - rim.width * 0.25,
               p.x <= rim.maxX + rim.width * 0.25 {
                madeExit = true
            }
        }

        let last = t.points[t.points.count - 1]
        let lastOutside = !expanded.contains(last)

        let decision: Bool?
        if enteredFromAbove && madeExit {
            decision = true                                   // through the rim
        } else if wasInsideExpanded && lastOutside {
            decision = false                                  // reached rim area, left without a through-rim exit
        } else {
            decision = nil                                    // still in flight — not decided yet
        }
        guard let made = decision else { return }

        decidedTrajectories.insert(t.id)
        if decidedTrajectories.count > 128 { decidedTrajectories.removeAll() }
        lastEmit = now

        let release = t.points[0]
        onShot?(DetectedShot(timestamp: t.timestamps.first ?? now,
                             made: made,
                             releasePoint: release,
                             releaseAtRim: expanded.contains(release),
                             releaseAngleDeg: Self.releaseAngle(of: t),
                             releaseTimeMs: nil,
                             confidence: t.confidence))
    }

    /// Launch angle from the parabola y_up = a·x² + b·x + c (bottom-left space):
    /// slope at the release x is 2a·x + b; the sign is flipped when the ball
    /// travels in the −x direction so positive always means upward.
    static func releaseAngle(of t: TrajectoryUpdate) -> Double {
        let x0 = Double(t.points[0].x)
        let slope = 2 * t.a * x0 + t.b
        let dx = Double(t.points[1].x - t.points[0].x)
        let directed = dx >= 0 ? slope : -slope
        return atan(directed) * 180 / .pi
    }
}
