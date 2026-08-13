import CoreGraphics
import CoreVideo
import Foundation

/// A player on the floor: detection box plus the jersey number when the
/// number region was detected and OCR'd.
struct DetectedPlayer: Equatable {
    var box: CGRect          // normalized, TOP-LEFT origin
    var number: String?
}

/// Player acquisition (PLAYER MODULE) — trained YOLO detection with quality
/// passes the raw model output needs on real courts:
/// 1. LOW confidence floor so nobody on the floor is missed…
/// 2. …then shape/size/position filters kill the non-person false positives
///    a low floor lets in (scoreboards, bags, crowd fragments),
/// 3. cross-class dedupe: the model's NMS is per-class, so one player seen
///    as both "player" and "player-jump-shot" arrives as two boxes.
/// Refs are excluded — they don't shoot.
enum PlayerFinder {
    static let playerLabels: Set<String> = [
        "Player", "player", "player-in-possession",
        "player-jump-shot", "player-layup-dunk", "player-shot-block",
    ]

    static func detectPlayers(in pixelBuffer: CVPixelBuffer, maxCount: Int = 14) -> [CGRect] {
        let raw = ObjectDetector.player?.detect(labels: playerLabels, in: pixelBuffer,
                                                maxCount: 24, minConfidence: 0.30)
            .map(\.box) ?? []
        return Array(dedupe(shapeFiltered(raw)).prefix(maxCount))
    }

    /// Person plausibility: upright-ish (crouching allowed), not a speck,
    /// not the whole frame, feet not floating in the scoreboard zone.
    static func shapeFiltered(_ boxes: [CGRect]) -> [CGRect] {
        boxes.filter { b in
            b.height > b.width * 0.9
                && b.height > 0.05 && b.height < 0.9
                && b.width > 0.015
                && b.maxY > 0.2
        }
    }

    /// Cross-class NMS. Boxes arrive confidence-sorted, so the best box of
    /// an overlapping pair survives.
    static func dedupe(_ boxes: [CGRect], iouThreshold: CGFloat = 0.45) -> [CGRect] {
        var kept: [CGRect] = []
        for box in boxes where !kept.contains(where: { iou($0, box) > iouThreshold }) {
            kept.append(box)
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

    /// Attach OCR'd jersey numbers to players: a number belongs to the
    /// player whose box contains its center (nearest wins on overlap).
    static func assign(numbers: [(point: CGPoint, digits: String)],
                       to boxes: [CGRect]) -> [DetectedPlayer] {
        var players = boxes.map { DetectedPlayer(box: $0, number: nil) }
        for number in numbers {
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (i, player) in players.enumerated() where player.box.contains(number.point) {
                let d = hypot(player.box.midX - number.point.x,
                              player.box.midY - number.point.y)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            if let i = bestIndex, players[i].number == nil {
                players[i].number = number.digits
            }
        }
        return players
    }
}
