import CoreGraphics

/// Rim continuity (RIM MODULE) for up to two ends, "A" and "B" — the hoops
/// team A and team B attack. Each end has its own tap anchor and its own
/// occlusion / reacquire state; nothing locks without an anchor (practice
/// gyms hang side baskets, and "most confident" would happily pick one).
/// A tap is authoritative: detections refine a rim locally, never move it.
struct RimTracker: Equatable {
    enum State: Equatable { case tracking, reacquiring }

    struct End: Equatable {
        var anchor: CGPoint
        /// Locked rim (normalized, top-left origin, padded 15%). Nil while
        /// reacquiring — a lost rim is not drawn or used.
        var rim: CGRect?
        var state: State = .tracking
        var lastSeenPts: Double
        var stableTicks = 0
    }

    static let endIds = ["A", "B"]

    private(set) var ends: [String: End] = [:]
    /// Candidates from the last tick — a tap snaps to the nearest one.
    private(set) var lastCandidates: [CGRect] = []
    /// pts at which the most recent reacquire began (any end).
    private(set) var lastReacquirePts: Double?

    /// Seconds without a sighting before an end reacquires — players occlude
    /// the rim constantly, a contested possession must not drop the track.
    var occlusionTolerance: Double = 4.0
    /// Rim-center jump (fraction of frame) that means the camera is panning.
    var jumpThreshold: CGFloat = 0.15

    /// Seed from a previous session / calibration (`ManualRimDetector`).
    init(rims: [String: CGRect] = [:], anchors: [String: CGPoint] = [:], pts: Double = 0) {
        for id in Self.endIds {
            if let a = anchors[id] ?? rims[id].map({ CGPoint(x: $0.midX, y: $0.midY) }) {
                ends[id] = End(anchor: a, rim: rims[id], lastSeenPts: pts)
            }
        }
    }

    /// Locked rims by end (only ends currently tracking).
    var rims: [String: CGRect] {
        ends.compactMapValues { $0.state == .tracking ? $0.rim : nil }
    }
    var trackedEnds: [String] { Self.endIds.filter { rims[$0] != nil } }
    var anchors: [String: CGPoint] { ends.mapValues(\.anchor) }
    func state(of end: String) -> State? { ends[end]?.state }

    /// One rim tick (slow lane, ≈1 Hz) for every anchored end.
    mutating func update(candidates: [CGRect], pts: Double) {
        lastCandidates = candidates
        for id in ends.keys.sorted() {
            var e = ends[id]!
            switch e.state {
            case .tracking:
                let center = e.rim.map { CGPoint(x: $0.midX, y: $0.midY) } ?? e.anchor
                if let r = RimFinder.pickRim(candidates: candidates, near: center, within: 0.2) {
                    let padded = Self.pad(r)
                    if let current = e.rim,
                       hypot(padded.midX - current.midX, padded.midY - current.midY) > jumpThreshold {
                        e.state = .reacquiring; e.stableTicks = 0; e.rim = nil   // rim jumped — camera moving
                        lastReacquirePts = pts
                    } else {
                        e.lastSeenPts = pts
                        e.rim = padded
                    }
                } else if pts - e.lastSeenPts > occlusionTolerance {
                    e.state = .reacquiring; e.stableTicks = 0; e.rim = nil       // rim gone
                    lastReacquirePts = pts
                }
            case .reacquiring:
                if let r = RimFinder.pickRim(candidates: candidates, near: e.anchor, within: 0.25) {
                    e.lastSeenPts = pts
                    e.stableTicks += 1
                    if e.stableTicks >= 2 { e.state = .tracking; e.rim = Self.pad(r) }  // steady two ticks
                } else {
                    e.stableTicks = 0
                }
            }
            ends[id] = e
        }
    }

    /// Tap = "track THIS hoop": snap to the nearest candidate within 12% of
    /// the frame (else a default box). The tap goes to the end whose anchor
    /// is within 0.25 of it (re-designate), else the first free end, else
    /// the nearest end. Returns the end id.
    @discardableResult
    mutating func designate(at point: CGPoint, pts: Double) -> String {
        let snapped = RimFinder.pickRim(candidates: lastCandidates, near: point, within: 0.12)
        let rim = snapped.map(Self.pad)
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        let near = ends.min { hypot($0.value.anchor.x - point.x, $0.value.anchor.y - point.y)
                            < hypot($1.value.anchor.x - point.x, $1.value.anchor.y - point.y) }
        let id: String
        if let near, hypot(near.value.anchor.x - point.x, near.value.anchor.y - point.y) <= 0.25 {
            id = near.key
        } else if let free = Self.endIds.first(where: { ends[$0] == nil }) {
            id = free
        } else {
            id = near?.key ?? "A"
        }
        ends[id] = End(anchor: point, rim: rim, state: .tracking, lastSeenPts: pts, stableTicks: 0)
        return id
    }

    static func pad(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
    }
}
