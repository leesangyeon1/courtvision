import CoreGraphics

extension PlayerAction {
    /// Model state-class label → action. Unknown labels are `none`.
    init(label: String) {
        switch label {
        case "player-in-possession": self = .possession
        case "player-jump-shot":     self = .jumpShot
        case "player-layup-dunk":    self = .layupDunk
        case "player-shot-block":    self = .shotBlock
        default:                     self = .none
        }
    }

    /// Overlay badge text.
    var short: String {
        switch self {
        case .none: ""
        case .possession: "POS"
        case .jumpShot: "SHOT"
        case .layupDunk: "LAYUP"
        case .shotBlock: "BLOCK"
        }
    }
}

/// Layer 3: state-class detections ANNOTATE tracked players — they never
/// create objects of their own.
enum ActionClassifier {
    /// Each state box lands on the best-IoU track at or above `iouThreshold`
    /// (state boxes cover the same player the base box covers, so the dedupe
    /// constant 0.45 is the right floor). An orphan state box matches no
    /// track and is dropped.
    static func classify(states: [Detection], tracks: [TrackedPlayer],
                         iouThreshold: CGFloat = 0.45) -> [TrackedPlayer] {
        var out = tracks
        for state in states {
            var bestIndex: Int?
            var bestIoU = iouThreshold
            for (i, track) in out.enumerated() {
                let s = PlayerFinder.iou(track.box, state.box)
                if s > bestIoU { bestIoU = s; bestIndex = i }
            }
            if let i = bestIndex { out[i].action = PlayerAction(label: state.label) }
        }
        return out
    }
}
