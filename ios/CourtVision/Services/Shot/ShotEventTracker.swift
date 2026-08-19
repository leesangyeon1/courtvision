import CoreGraphics

/// One shot attempt, derived from Moments. The same value is emitted twice:
/// as `.attempt` when it opens and as `.made` / `.missed` when it resolves.
struct ShotEvent: Equatable, Codable {
    enum Kind: String, Codable { case attempt, made, missed }
    var kind: Kind
    /// Attempt-start pts (same value on the attempt and its resolution).
    let pts: Double
    var resolvedPts: Double?
    let trackId: Int
    /// `.jumpShot` or `.layupDunk`.
    let action: PlayerAction
    /// Ground-contact point at attempt start, image space (normalized, top-left).
    let feet: CGPoint
    /// `feet` through the homography at attempt start, court feet. Nil = no fix yet.
    let court: CGPoint?
    /// Confidence of the shooting-state detection that opened the attempt.
    let confidence: Float
    /// Which hoop ("A"/"B"): for a make, the rim the ball entered; otherwise
    /// the rim nearest the shooter at the attempt. Nil with no rim locked.
    var end: String?
}

/// roboflow/sports' ShotEventTracker on our Moments: consecutive
/// shooting-state ticks on one track open an attempt; `ball-in-basket` at a
/// locked rim inside the window resolves it MADE (and names the hoop);
/// window expiry resolves it MISSED; a fresh start ≥ `minGapSec` after an
/// open one supersedes it (the early set-position start becomes a miss and
/// the real shot opens); a short cooldown follows every resolution.
struct ShotEventTracker: Equatable {
    /// Consecutive shooting-state ticks needed to open (2 ≈ 0.33 s at 6 Hz).
    var minStartTicks = 2
    /// Seconds after the start in which ball-in-basket counts as this attempt.
    var windowSec: Double = 3.0
    /// A new start this long after an open one replaces it (reference: 0.5 s).
    var minGapSec: Double = 0.5
    /// Seconds after a resolution before a new attempt can open (reference: 0.5 s).
    var cooldownSec: Double = 0.5
    /// ball-in-basket counts only within `rimReach` × rim width of a rim center.
    var rimReach: CGFloat = 1.5

    private var streak: [Int: Int] = [:]
    private var open: ShotEvent?
    private var lastResolvedPts: Double = -.infinity

    mutating func update(_ m: Moment) -> [ShotEvent] {
        var out: [ShotEvent] = []
        if var attempt = open {
            if let end = Self.ballInBasketEnd(m, rimReach: rimReach) {
                attempt.kind = .made
                attempt.end = end
            } else if m.pts - attempt.pts > windowSec {
                attempt.kind = .missed
            } else if let fresh = openingAttempt(m), m.pts - attempt.pts >= minGapSec {
                attempt.kind = .missed                       // superseded by a real start
                attempt.resolvedPts = m.pts
                out.append(attempt)
                open = fresh
                out.append(fresh)
                return out
            } else {
                return out
            }
            attempt.resolvedPts = m.pts
            out.append(attempt)
            open = nil
            lastResolvedPts = m.pts
            streak = [:]
            return out
        }
        guard m.pts - lastResolvedPts >= cooldownSec else { return out }
        if let fresh = openingAttempt(m) {
            open = fresh
            out.append(fresh)
        }
        return out
    }

    /// Advances the per-track shooting streaks; returns an attempt the tick
    /// a streak crosses `minStartTicks` (exactly — a held state never
    /// re-triggers).
    private mutating func openingAttempt(_ m: Moment) -> ShotEvent? {
        var live = Set<Int>()
        var opened: ShotEvent?
        for p in m.players where p.action == .jumpShot || p.action == .layupDunk {
            live.insert(p.trackId)
            streak[p.trackId, default: 0] += 1
            if streak[p.trackId] == minStartTicks, opened == nil {
                opened = ShotEvent(kind: .attempt, pts: m.pts, resolvedPts: nil,
                                   trackId: p.trackId, action: p.action, feet: p.feet,
                                   court: m.h.map { $0.apply(p.feet) },
                                   confidence: p.actionConfidence,
                                   end: Self.nearestEnd(to: p.feet, in: m))
            }
        }
        streak = streak.filter { live.contains($0.key) }     // a broken streak starts over
        return opened
    }

    /// The end whose rim the ball is sitting in (`ball-in-basket` within reach).
    static func ballInBasketEnd(_ m: Moment, rimReach: CGFloat) -> String? {
        guard let ball = m.ball, ball.label == "ball-in-basket" else { return nil }
        return m.rims.min { a, b in
            hypot(ball.box.midX - a.value.midX, ball.box.midY - a.value.midY)
                < hypot(ball.box.midX - b.value.midX, ball.box.midY - b.value.midY)
        }.flatMap { end, rim in
            hypot(ball.box.midX - rim.midX, ball.box.midY - rim.midY) <= rimReach * rim.width ? end : nil
        }
    }

    static func nearestEnd(to point: CGPoint, in m: Moment) -> String? {
        m.rims.min { hypot($0.value.midX - point.x, $0.value.midY - point.y)
                   < hypot($1.value.midX - point.x, $1.value.midY - point.y) }?.key
    }
}
