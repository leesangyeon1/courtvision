import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// The unified trained detector (CoreML with NMS) compiled into the bundle
/// as `BasketballDetector.mlmodelc`: user-trained YOLOv8s @ 960px
/// (mAP50 0.88), 10 classes — ball, ball-in-basket, number, player,
/// player-in-possession, player-jump-shot, player-layup-dunk,
/// player-shot-block, referee, rim. One model serves the Rim, Ball and
/// Player modules. A missing model yields nil so heuristic fallbacks stay
/// in charge — no fake detections, ever.
final class ObjectDetector {
    static let unified = ObjectDetector(resource: "BasketballDetector")
    /// Rim runs on the original HoopDetector — field-tested better for rims
    /// than the unified model; unified is the fallback.
    static let hoop = ObjectDetector(resource: "HoopDetector") ?? unified
    static let ball = unified
    static let player = unified

    private let model: VNCoreMLModel

    init?(resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        model = visionModel
    }

    /// Labeled detections matching any of `labels` in one frame (normalized,
    /// TOP-LEFT origin), best-confidence first, capped at `maxCount`. Label
    /// SETS keep the code working across model generations (e.g. "Basketball
    /// Hoop" in the original weights vs "rim" in the eagle-eye retrain).
    func detect(labels: Set<String>, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [Detection] {
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
                Detection.fromVision(label: obs.labels.first?.identifier ?? "",
                                     confidence: obs.confidence,
                                     visionBox: obs.boundingBox)
            }
    }
}
