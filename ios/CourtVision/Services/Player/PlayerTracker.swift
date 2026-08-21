import CoreGraphics
import Foundation

/// What a tracked player is DOING this tick (Layer 3 annotates it; `none`
/// between annotations). Cases mirror the model's state classes.
enum PlayerAction: String, Codable, Equatable {
    case none, possession, jumpShot, layupDunk, shotBlock
}

/// A player with cross-frame identity (Layer 2 output).
struct TrackedPlayer: Identifiable, Equatable {
    let id: Int
    var box: CGRect
    var action: PlayerAction = .none
    /// Confidence of the state box that set `action` this tick (0 for `.none`).
    var actionConfidence: Float = 0
    var missedTicks = 0
    /// Every jersey-number OCR read that landed on this track.
    var numberTally: [String: Int] = [:]
    /// Majority-vote jersey number; ties break to the smaller string so the
    /// result is deterministic. Persists while the track lives — a jersey
    /// facing away no longer blanks the number.
    var number: String? {
        numberTally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key
    }
}

/// Cross-frame player identity. Association per tick: best IoU first, then
/// — for the pairs that don't overlap (fast movers, a flickered tick) —
/// center distance relative to body height. A track that dies keeps a short
/// "lost" memory: a detection appearing near where it vanished resumes the
/// SAME id (jersey number and team votes travel with it), so a box doesn't
/// become a stranger after one occlusion.
/// ponytail: no Kalman, no appearance model — upgrade if churn still shows
/// on field footage after this.
struct PlayerTracker {
    private(set) var tracks: [TrackedPlayer] = []
    /// Recently lost tracks, newest first: (track, ticks since lost).
    private(set) var lost: [(track: TrackedPlayer, age: Int)] = []
    private var nextID = 1
    /// Ticks a track survives unmatched (set from the tick rate: 2 s).
    var maxMissedTicks = 4
    /// Seconds a lost track can still be resumed by a nearby detection.
    var resurrectSeconds: Double = 3.0
    /// Seconds per tick — converts `resurrectSeconds` to ticks.
    var tickSeconds: Double = 0.5
    /// Association floor on overlap.
    var minIoU: CGFloat = 0.15
    /// Association reach without overlap: center distance ≤ this × box height.
    var reachHeights: CGFloat = 0.75
    /// Resume reach for a lost track: center distance ≤ this × box height.
    var resurrectHeights: CGFloat = 1.5

    private var resurrectTicks: Int { Int((resurrectSeconds / tickSeconds).rounded()) }

    @discardableResult
    mutating func update(with detections: [Detection]) -> [TrackedPlayer] {
        let boxes = detections.map(\.box)
        // All (track, box) pairs that can associate, best first: IoU pairs
        // rank above distance-only pairs; within each, closer wins.
        var pairs: [(t: Int, b: Int, cost: CGFloat)] = []
        for (t, track) in tracks.enumerated() {
            for (b, box) in boxes.enumerated() {
                let s = PlayerFinder.iou(track.box, box)
                if s >= minIoU {
                    pairs.append((t, b, 1 - s))                                 // 0…0.85
                } else {
                    let d = hypot(track.box.midX - box.midX, track.box.midY - box.midY)
                    let reach = reachHeights * max(track.box.height, box.height)
                    if d <= reach { pairs.append((t, b, 1 + d / reach)) }         // 1…2
                }
            }
        }
        pairs.sort { $0.cost < $1.cost }
        var matchedTracks = Set<Int>(), matchedBoxes = Set<Int>()
        for p in pairs where !matchedTracks.contains(p.t) && !matchedBoxes.contains(p.b) {
            matchedTracks.insert(p.t)
            matchedBoxes.insert(p.b)
            tracks[p.t].box = boxes[p.b]
            tracks[p.t].missedTicks = 0
        }
        for t in tracks.indices where !matchedTracks.contains(t) {
            tracks[t].missedTicks += 1
        }
        // Dying tracks move to the lost list (identity kept for a while).
        for t in tracks where t.missedTicks >= maxMissedTicks { lost.insert((t, 0), at: 0) }
        tracks.removeAll { $0.missedTicks >= maxMissedTicks }
        lost = lost.map { ($0.track, $0.age + 1) }.filter { $0.age <= resurrectTicks }

        // Unmatched detections: resume a lost track nearby, else a new id.
        for (b, box) in boxes.enumerated() where !matchedBoxes.contains(b) {
            if let i = lost.firstIndex(where: { l in
                hypot(l.track.box.midX - box.midX, l.track.box.midY - box.midY)
                    <= resurrectHeights * max(l.track.box.height, box.height)
            }) {
                var t = lost.remove(at: i).track
                t.box = box
                t.missedTicks = 0
                t.action = .none
                t.actionConfidence = 0
                tracks.append(t)
            } else {
                tracks.append(TrackedPlayer(id: nextID, box: box))
                nextID += 1
            }
        }
        // Action is per-tick: reset here, Layer 3 re-annotates.
        for i in tracks.indices { tracks[i].action = .none; tracks[i].actionConfidence = 0 }
        return tracks
    }

    /// A jersey read lands on the track whose box contains ≥ `numberIoS` of
    /// the number REGION (intersection over the region's area — ref 02's
    /// IoS matching, box edition; best containment wins, nearest center
    /// breaks ties) and bumps that digit string's tally. A region not inside
    /// any player box is dropped — scoreboard digits are not jersey numbers.
    var numberIoS: CGFloat = 0.9

    mutating func assign(numbers: [(box: CGRect, digits: String)]) {
        for number in numbers {
            var best: (index: Int, ios: CGFloat, d: CGFloat)?
            for (i, track) in tracks.enumerated() {
                let inter = track.box.intersection(number.box)
                guard !inter.isNull, number.box.width > 0, number.box.height > 0 else { continue }
                let ios = (inter.width * inter.height) / (number.box.width * number.box.height)
                guard ios >= numberIoS else { continue }
                let d = hypot(track.box.midX - number.box.midX, track.box.midY - number.box.midY)
                if best == nil || ios > best!.ios || (ios == best!.ios && d < best!.d) {
                    best = (i, ios, d)
                }
            }
            if let best { tracks[best.index].numberTally[number.digits, default: 0] += 1 }
        }
    }
}
