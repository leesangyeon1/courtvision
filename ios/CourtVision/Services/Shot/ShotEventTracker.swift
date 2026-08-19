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
}

/// Ref 02's shot event tracker on our Moments: consecutive shooting-state
/// ticks on one track open an attempt; `ball-in-basket` near the tracked rim
/// inside the window resolves it MADE; window expiry resolves it MISSED; a
/// cooldown separates attempts (a putback is a new attempt).
struct ShotEventTracker: Equatable {
    /// Consecutive shooting-state ticks needed to open (2 ≈ 0.33 s at 6 Hz).
    var minStartTicks = 2
    /// Seconds after the start in which ball-in-basket counts as this attempt.
    var windowSec: Double = 3.0
    /// Seconds after a resolution before a new attempt can open.
    var cooldownSec: Double = 2.0
    /// ball-in-basket counts only within `rimReach` × rim width of the rim center.
    var rimReach: CGFloat = 1.5

    private var streak: [Int: Int] = [:]
    private var open: ShotEvent?
    private var lastResolvedPts: Double = -.infinity

    mutating func update(_ m: Moment) -> [ShotEvent] {
        if var attempt = open {
            if Self.ballInBasket(m, rimReach: rimReach) {
                attempt.kind = .made
            } else if m.pts - attempt.pts > windowSec {
                attempt.kind = .missed
            } else {
                return []
            }
            attempt.resolvedPts = m.pts
            open = nil
            lastResolvedPts = m.pts
            streak = [:]
            return [attempt]
        }
        guard m.pts - lastResolvedPts >= cooldownSec else { return [] }

        var live = Set<Int>()
        for p in m.players where p.action == .jumpShot || p.action == .layupDunk {
            live.insert(p.trackId)
            streak[p.trackId, default: 0] += 1
            if streak[p.trackId]! >= minStartTicks {
                let attempt = ShotEvent(kind: .attempt, pts: m.pts, resolvedPts: nil,
                                        trackId: p.trackId, action: p.action, feet: p.feet,
                                        court: m.h.map { $0.apply(p.feet) },
                                        confidence: p.actionConfidence)
                open = attempt
                streak = [:]
                return [attempt]
            }
        }
        streak = streak.filter { live.contains($0.key) }   // a broken streak starts over
        return []
    }

    static func ballInBasket(_ m: Moment, rimReach: CGFloat) -> Bool {
        guard let ball = m.ball, ball.label == "ball-in-basket", let rim = m.rim else { return false }
        return hypot(ball.box.midX - rim.midX, ball.box.midY - rim.midY) <= rimReach * rim.width
    }
}
