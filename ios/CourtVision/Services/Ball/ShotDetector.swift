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
    /// Index into ShotDetector.rimRects of the rim that decided this shot —
    /// game sessions use it for team attribution and half-court mirroring.
    let rimIndex: Int
}

/// Make/miss state machine over ball trajectories relative to the rim boxes
/// (one rim for practice/drill/free-throw, two for game sessions).
///
/// All geometry is in normalized image coordinates with a TOP-LEFT origin, so
/// downward motion means increasing y.
///
/// A trajectory only counts as a shot ATTEMPT at all when it descends into a
/// rim's neighbourhood from above AND passes close to the rim itself (within
/// 1.5x of the box) — balls that merely cross the wide neighbourhood in 2D
/// (passes, dribbles, airballs well off target) produce no event.
///
/// - MADE: the attempt later exits BELOW the rim box within its x-span.
/// - MISS: the attempt leaves the rim neighbourhood without a through-rim exit.
/// - Debounce: each Vision trajectory id is decided at most once, and after
///   any emitted event further decisions are suppressed for `cooldown`
///   seconds → one shot, one event.
final class ShotDetector {
    /// Current rim boxes (normalized, top-left origin). Set from the calibration.
    var rimRects: [CGRect] = []
    /// Called (on the vision queue) once per decided shot.
    var onShot: ((DetectedShot) -> Void)?
    var cooldown: TimeInterval = 1.5

    private var lastEmit: TimeInterval = -.greatestFiniteMagnitude
    private var decidedTrajectories: Set<UUID> = []

    func ingest(_ t: TrajectoryUpdate) {
        guard !rimRects.isEmpty,
              t.points.count >= 3,
              !decidedTrajectories.contains(t.id) else { return }
        let now = t.timestamps.last ?? 0
        guard now - lastEmit >= cooldown else { return }

        // A make at either rim wins; otherwise the first decided miss stands.
        var decision: (made: Bool, rimIndex: Int)?
        for (i, rim) in rimRects.enumerated() {
            switch Self.decide(t, rim: rim) {
            case .some(true): decision = (true, i)
            case .some(false): decision = decision ?? (false, i)
            case nil: break
            }
            if decision?.made == true { break }
        }
        guard let (made, rimIndex) = decision else { return }

        decidedTrajectories.insert(t.id)
        if decidedTrajectories.count > 128 { decidedTrajectories.removeAll() }
        lastEmit = now

        let release = t.points[0]
        let releaseAtRim = rimRects.contains {
            $0.insetBy(dx: -$0.width * 0.75, dy: -$0.height * 0.75).contains(release)
        }
        onShot?(DetectedShot(timestamp: t.timestamps.first ?? now,
                             made: made,
                             releasePoint: release,
                             releaseAtRim: releaseAtRim,
                             releaseAngleDeg: Self.releaseAngle(of: t),
                             releaseTimeMs: nil,
                             confidence: t.confidence,
                             rimIndex: rimIndex))
    }

    /// Make/miss/undecided for one trajectory against one rim.
    ///
    /// Gate insets have ABSOLUTE floors (fractions of the frame): the far
    /// hoop of a full court is tiny on screen, and purely proportional gates
    /// collapse below the trajectory point spacing — shots at the far rim
    /// would never register. Floors keep both rims detectable.
    static func decide(_ t: TrajectoryUpdate, rim: CGRect) -> Bool? {
        let expanded = rim.insetBy(dx: -max(rim.width * 0.75, 0.03),
                                   dy: -max(rim.height * 0.75, 0.02))
        // ponytail: "close" = within 1.5x of the rim box; a 3D depth check
        // needs a second camera or a learned model — this 2D gate is the V1
        // ceiling and kills the pass/dribble false positives.
        let near = rim.insetBy(dx: -max(rim.width * 0.25, 0.012),
                               dy: -max(rim.height * 0.25, 0.008))

        var enteredFromAbove = false
        var cameClose = false
        var madeExit = false

        for i in 0..<t.points.count {
            let p = t.points[i]
            if near.contains(p) { cameClose = true }

            if !enteredFromAbove, i > 0, expanded.contains(p) {
                let prev = t.points[i - 1]
                // downward velocity + came from above the region
                if p.y > prev.y, prev.y < expanded.midY {
                    enteredFromAbove = true
                }
            }

            if enteredFromAbove,
               p.y > rim.maxY,
               p.x >= rim.minX - max(rim.width * 0.25, 0.012),
               p.x <= rim.maxX + max(rim.width * 0.25, 0.012) {
                madeExit = true
            }
        }

        // Not an attempt unless it descended into the neighbourhood AND got
        // close to the rim itself.
        guard enteredFromAbove, cameClose else { return nil }

        if madeExit { return true }                             // through the rim
        let last = t.points[t.points.count - 1]
        if !expanded.contains(last) { return false }            // reached rim, left without a through-rim exit
        return nil                                              // still in flight — not decided yet
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
