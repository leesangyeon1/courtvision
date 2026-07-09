import CoreGraphics
import CoreVideo
import Foundation

/// Player acquisition (PLAYER MODULE) — same mechanism as rim and ball: a
/// trained YOLO detector (basketball-players-fy4c2, CC BY 4.0) finds people
/// on the floor. Players are many-at-once, so unlike rim/ball there is no
/// single-anchor continuity gate — the raw boxes feed the overlay and,
/// later, shooter identification (nearest player to the ball at release).
enum PlayerFinder {
    /// Player boxes in one frame (normalized, TOP-LEFT origin),
    /// best-confidence first. Refs are excluded — they don't shoot.
    /// Empty when the PlayerDetector model isn't in the bundle.
    static func detectPlayers(in pixelBuffer: CVPixelBuffer, maxCount: Int = 12) -> [CGRect] {
        ObjectDetector.player?.detect(labels: ["Player"], in: pixelBuffer,
                                      maxCount: maxCount, minConfidence: 0.4) ?? []
    }
}
