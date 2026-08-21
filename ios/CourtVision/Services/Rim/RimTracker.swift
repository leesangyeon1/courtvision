import CoreGraphics

/// Rim positions (RIM MODULE) for a FIXED camera, up to two ends "A" and "B"
/// (the hoops those teams attack). Nothing locks without a tap — practice
/// gyms hang side baskets and "most confident" would pick one. Once tapped a
/// rim is permanent: detections within a small gate refine it, occlusion
/// changes nothing (the camera doesn't move, so neither does the rim), and
/// there is no reacquire state. Only `invalidate` (tripod bump) or a re-tap
/// moves an end.
struct RimTracker: Equatable {
    struct End: Equatable {
        var anchor: CGPoint
        /// Locked rim (normalized, top-left origin, padded 15%).
        var rim: CGRect
    }

    static let endIds = ["A", "B"]

    private(set) var ends: [String: End] = [:]
    /// Candidates from the last tick — a tap snaps to the nearest one.
    private(set) var lastCandidates: [CGRect] = []
    /// The tripod was bumped: rims are wrong until the user re-taps. Shots
    /// resolved before this instant keep their fix; later ones wait.
    private(set) var stale = false
    private(set) var staleSincePts: Double?
    /// pts of the most recent bump, never cleared: an attempt from before it
    /// must not be located with a fit solved after it (different image space).
    private(set) var lastInvalidatedPts: Double?

    /// Detections farther than this from the locked rim can't refine it.
    var refineGate: CGFloat = 0.1

    /// Seed from a previous session / calibration (`ManualRimDetector`).
    init(rims: [String: CGRect] = [:], anchors: [String: CGPoint] = [:], pts: Double = 0) {
        for id in Self.endIds {
            if let rim = rims[id] {
                ends[id] = End(anchor: anchors[id] ?? CGPoint(x: rim.midX, y: rim.midY), rim: rim)
            }
        }
    }

    /// Locked rims by end (empty while stale — no fake rims after a bump).
    var rims: [String: CGRect] {
        stale ? [:] : ends.mapValues(\.rim)
    }
    var trackedEnds: [String] { Self.endIds.filter { rims[$0] != nil } }
    var anchors: [String: CGPoint] { ends.mapValues(\.anchor) }

    /// One rim tick (slow lane, ≈1 Hz): a candidate close to a locked rim
    /// refines it in place. That's all — the camera is fixed.
    mutating func update(candidates: [CGRect], pts: Double) {
        lastCandidates = candidates
        guard !stale else { return }
        for id in ends.keys {
            let center = CGPoint(x: ends[id]!.rim.midX, y: ends[id]!.rim.midY)
            if let r = RimFinder.pickRim(candidates: candidates, near: center, within: refineGate) {
                ends[id]!.rim = Self.pad(r)
            }
        }
    }

    /// Tap = "the hoop is HERE": snap to the nearest candidate within 12% of
    /// the frame (else a default box). The tap goes to the end whose anchor
    /// is within 0.25 of it (re-designate), else the first free end, else
    /// the nearest end. A tap also clears `stale` for that setup —
    /// re-tapping after a bump is the recalibration. Returns the end id.
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
        ends[id] = End(anchor: point, rim: rim)
        stale = false
        staleSincePts = nil
        return id
    }

    /// The tripod moved (gyro bump, manual recalibrate): every rim is wrong
    /// until the user re-taps. Anchors are kept only as tap hints.
    mutating func invalidate(pts: Double) {
        stale = true
        staleSincePts = pts
        lastInvalidatedPts = pts
    }

    static func pad(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
    }
}
