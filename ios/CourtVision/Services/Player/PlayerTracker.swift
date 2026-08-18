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

/// Cross-frame player identity: greedy best-IoU association between the
/// previous tick's tracks and this tick's detections.
/// ponytail: greedy IoU at 2 Hz loses very fast movers — a center-distance
/// gate or Kalman prediction is the upgrade if ID churn shows in the field.
struct PlayerTracker {
    private(set) var tracks: [TrackedPlayer] = []
    private var nextID = 1
    /// Ticks a track survives unmatched (4 ≈ 2 s at the 2 Hz player cadence).
    var maxMissedTicks = 4
    /// Association floor: below this overlap a detection is a new player.
    var minIoU: CGFloat = 0.15

    @discardableResult
    mutating func update(with detections: [Detection]) -> [TrackedPlayer] {
        let boxes = detections.map(\.box)
        // All (track, box) pairs above the floor, best overlap first.
        var pairs: [(t: Int, b: Int, iou: CGFloat)] = []
        for (t, track) in tracks.enumerated() {
            for (b, box) in boxes.enumerated() {
                let s = PlayerFinder.iou(track.box, box)
                if s >= minIoU { pairs.append((t, b, s)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
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
        tracks.removeAll { $0.missedTicks >= maxMissedTicks }
        for (b, box) in boxes.enumerated() where !matchedBoxes.contains(b) {
            tracks.append(TrackedPlayer(id: nextID, box: box))
            nextID += 1
        }
        // Action is per-tick: reset here, Layer 3 re-annotates.
        for i in tracks.indices { tracks[i].action = .none; tracks[i].actionConfidence = 0 }
        return tracks
    }

    /// A jersey read lands on the track whose box contains the read's center
    /// (nearest center on overlap) and bumps that digit string's tally.
    /// A read landing on no track is dropped — scoreboard digits are not
    /// jersey numbers.
    mutating func assign(numbers: [(point: CGPoint, digits: String)]) {
        for number in numbers {
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (i, track) in tracks.enumerated() where track.box.contains(number.point) {
                let d = hypot(track.box.midX - number.point.x,
                              track.box.midY - number.point.y)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            if let i = bestIndex { tracks[i].numberTally[number.digits, default: 0] += 1 }
        }
    }
}
