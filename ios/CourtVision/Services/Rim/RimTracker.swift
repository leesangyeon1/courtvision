import CoreGraphics

/// Rim continuity state machine (RIM MODULE), extracted from the record
/// screen so it runs on the engine clock and under test. A tap per end
/// ("anchor") says "THIS hoop, not the side baskets"; detections may refine
/// the rim locally, never move it elsewhere.
struct RimTracker: Equatable {
    enum State: Equatable { case tracking, reacquiring }

    private(set) var state: State = .tracking
    /// Rim currently locked on (normalized, top-left origin, padded 15%).
    private(set) var rim: CGRect?
    /// Tap-designated rim spot per end, keyed by attacking team.
    var anchors: [String: CGPoint]
    /// Candidates from the last tick — a tap snaps to the nearest one.
    private(set) var lastCandidates: [CGRect] = []
    /// pts at which the last reacquire began (nil = never). Consumers use it
    /// to know whether a homography from before that instant still applies.
    private(set) var lastReacquirePts: Double?
    private var lastSeenPts: Double?
    private var stableTicks = 0

    /// Seconds without a sighting before reacquire — players occlude the rim
    /// constantly, a contested possession must not drop the track.
    var occlusionTolerance: Double = 4.0
    /// Rim-center jump (fraction of frame) that means the camera is panning.
    var jumpThreshold: CGFloat = 0.15

    init(rim: CGRect? = nil, anchors: [String: CGPoint] = [:]) {
        self.rim = rim
        self.anchors = anchors
    }

    /// One rim tick (≈1 Hz). `attackingTeam` selects the anchor.
    mutating func update(candidates: [CGRect], attackingTeam: String, pts: Double) {
        lastCandidates = candidates
        if lastSeenPts == nil { lastSeenPts = pts }
        switch state {
        case .tracking:
            let anchor = rim.map { CGPoint(x: $0.midX, y: $0.midY) } ?? anchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: candidates, near: anchor,
                                         within: anchor != nil ? 0.2 : nil) {
                let padded = Self.pad(r)
                if let current = rim,
                   hypot(padded.midX - current.midX, padded.midY - current.midY) > jumpThreshold {
                    beginReacquire(at: pts)          // rim jumped — camera moving
                } else {
                    lastSeenPts = pts
                    rim = padded
                }
            } else if pts - (lastSeenPts ?? pts) > occlusionTolerance {
                beginReacquire(at: pts)              // rim gone — camera swinging to other end
            }
        case .reacquiring:
            // Prefer the other end's anchor — that's the hoop we swing toward.
            let other = attackingTeam == "A" ? "B" : "A"
            let target = anchors[other] ?? anchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: candidates, near: target,
                                         within: target != nil ? 0.25 : nil) {
                lastSeenPts = pts
                rim = Self.pad(r)
                stableTicks += 1
                if stableTicks >= 2 { state = .tracking }   // steady two ticks → locked
            } else {
                stableTicks = 0
            }
        }
    }

    /// Tap = "track THIS hoop": snap to the nearest candidate within 12% of
    /// the frame, else a default box; remember the spot as this end's anchor;
    /// resume tracking on it immediately.
    mutating func designate(at point: CGPoint, attackingTeam: String, pts: Double) {
        let snapped = RimFinder.pickRim(candidates: lastCandidates, near: point, within: 0.12)
        rim = snapped.map(Self.pad)
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        anchors[attackingTeam] = point
        lastSeenPts = pts
        state = .tracking
        stableTicks = 0
    }

    private mutating func beginReacquire(at pts: Double) {
        state = .reacquiring
        stableTicks = 0
        lastReacquirePts = pts
    }

    static func pad(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
    }
}
