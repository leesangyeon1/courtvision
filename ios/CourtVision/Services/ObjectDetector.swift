import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// Trained YOLO detectors (CoreML with NMS) compiled into the bundle.
/// Two generations run side by side on purpose:
/// - `hoop` (HoopDetector.mlmodelc): the original weights — proven in the
///   field for the RIM; its ball class is weak.
/// - `ball` (BallDetector.mlmodelc): retrained on the eagle-eye dataset
///   (CC BY 4.0, basketball mAP50 0.92) — serves the BALL; its rim quality
///   is unverified, so the rim stays on `hoop`.
/// A missing model yields nil so heuristic fallbacks stay in charge — no
/// fake detections, ever.
final class ObjectDetector {
    static let hoop = ObjectDetector(resource: "HoopDetector")
    static let ball = ObjectDetector(resource: "BallDetector") ?? hoop
    /// Player model (basketball-players-fy4c2 retrain). No fallback — the
    /// other models have no person class; absent model = no player boxes.
    static let player = ObjectDetector(resource: "PlayerDetector")

    private let model: VNCoreMLModel

    init?(resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        model = visionModel
    }

    /// Boxes matching any of `labels` in one frame (normalized, TOP-LEFT
    /// origin), best-confidence first, capped at `maxCount`. Label SETS keep
    /// the code working across model generations (e.g. "Basketball Hoop" in
    /// the original weights vs "rim" in the eagle-eye retrain).
    func detect(labels: Set<String>, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [CGRect] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { obs in
                guard let id = obs.labels.first?.identifier else { return false }
                return labels.contains(id) && obs.confidence >= minConfidence
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount)
            .map { obs in
                let b = obs.boundingBox  // Vision: bottom-left origin
                return CGRect(x: b.origin.x,
                              y: 1 - b.origin.y - b.height,
                              width: b.width,
                              height: b.height)
            }
    }
}
