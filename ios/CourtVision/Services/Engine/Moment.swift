import CoreGraphics

/// One tick of the pipeline on the frame clock. Everything downstream — the
/// overlay, the shot tracker, the session buffer, post-processing — reads
/// Moments; nothing downstream reads a detector directly.
struct Moment: Equatable, Codable {
    struct PlayerState: Equatable, Codable {
        let trackId: Int
        /// "A" / "B" once the team assigner runs (P3); nil until then.
        var team: String?
        /// Normalized image box, TOP-LEFT origin.
        var box: CGRect
        /// Ground-contact estimate in image space: pose ankles when the
        /// player was on the floor recently (P1), else the box bottom-center.
        var feet: CGPoint
        /// `feet` through the homography, court feet. Nil without a court fix.
        var xFt: Double?
        var yFt: Double?
        var action: PlayerAction
        /// Confidence of the state detection that set `action` (0 for `.none`).
        var actionConfidence: Float
        var number: String?
        /// 0 = seen this tick; 1–2 = not seen, box is the last one (draw
        /// grace so a flicker doesn't blink — never more than that).
        var missedTicks: Int = 0
    }

    struct BallState: Equatable, Codable {
        var box: CGRect
        /// "ball" or "ball-in-basket" — the state rides the track.
        var label: String
        /// Ground projection of the ball center through the homography (the
        /// ball is in the air; this is where it is *over* the floor).
        var xFt: Double?
        var yFt: Double?
    }

    /// Frame presentation time, seconds — the one clock.
    let pts: Double
    var h: Homography?
    /// Locked rims by end ("A"/"B" = the hoop that team attacks).
    var rims: [String: CGRect]
    var players: [PlayerState]
    var ball: BallState?
    /// Referee boxes (drawn black; not tracked, never a player).
    var referees: [CGRect] = []
    /// True when `h` maps to the full 94-ft court (both rims locked);
    /// `farEnds` are the ends whose hoop sits in the far half — shots at
    /// them are mirrored into the near half for the contract.
    var fullCourt = false
    var farEnds: Set<String> = []
}
