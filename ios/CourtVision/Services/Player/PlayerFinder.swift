import CoreGraphics
import CoreVideo
import Foundation

/// Player acquisition (PLAYER MODULE) — trained YOLO detection with quality
/// passes the raw model output needs on real courts:
/// 1. LOW confidence floor so nobody on the floor is missed…
/// 2. …then shape/size/position filters kill the non-person false positives
///    a low floor lets in (scoreboards, bags, crowd fragments),
/// 3. cross-class dedupe: the model's NMS is per-class, so one player seen
///    as both "player" and "player-jump-shot" arrives as two boxes.
/// Refs are excluded — they don't shoot.
enum PlayerFinder {
    static let baseLabels: Set<String> = ["Player", "player"]
    /// Player STATES — still players, never separate objects. They feed the
    /// action layer (ActionClassifier), and their boxes count as player
    /// evidence in detection.
    static let stateLabels: Set<String> = [
        "player-in-possession", "player-jump-shot",
        "player-layup-dunk", "player-shot-block",
    ]
    static let playerLabels = baseLabels.union(stateLabels)

    /// Raw labeled player-family detections, one call per tick.
    static func detectAll(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        ObjectDetector.player?.detect(labels: playerLabels, in: pixelBuffer,
                                      maxCount: 24, minConfidence: 0.30) ?? []
    }

    /// Layer-1 output: one detection per physical player. Shape filter, then
    /// greedy dedupe with BASE `player` boxes ranked first, so an overlapping
    /// (player, player-jump-shot) pair survives as the base box.
    static func corePlayers(_ raw: [Detection], maxCount: Int = 14) -> [Detection] {
        let ranked = shapeFiltered(raw).sorted {
            let a = baseLabels.contains($0.label), b = baseLabels.contains($1.label)
            return a == b ? $0.confidence > $1.confidence : a
        }
        return Array(dedupe(ranked).prefix(maxCount))
    }

    /// Layer-3 input: this tick's state-class detections, unfiltered.
    static func states(_ raw: [Detection]) -> [Detection] {
        raw.filter { stateLabels.contains($0.label) }
    }

    /// Person plausibility: upright-ish (crouching allowed), not a speck,
    /// not the whole frame, feet not floating in the scoreboard zone.
    static func shapeFiltered(_ detections: [Detection]) -> [Detection] {
        detections.filter { d in
            d.box.height > d.box.width * 0.9
                && d.box.height > 0.05 && d.box.height < 0.9
                && d.box.width > 0.015
                && d.box.maxY > 0.2
        }
    }

    /// Cross-class NMS. Input arrives ranked (base first, then confidence),
    /// so the preferred detection of an overlapping pair survives.
    static func dedupe(_ detections: [Detection], iouThreshold: CGFloat = 0.45) -> [Detection] {
        var kept: [Detection] = []
        for d in detections where !kept.contains(where: { iou($0.box, d.box) > iouThreshold }) {
            kept.append(d)
        }
        return kept
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
