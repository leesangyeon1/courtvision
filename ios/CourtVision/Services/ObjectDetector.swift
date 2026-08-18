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

    /// Every labeled detection in one frame above `minConfidence`, best
    /// first. ONE call per engine tick — modules filter this list by label
    /// set instead of each running the model.
    func detectAll(in pixelBuffer: CVPixelBuffer, minConfidence: Float,
                   maxCount: Int = 64) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return Array((request.results as? [VNRecognizedObjectObservation] ?? [])
            .compactMap { obs -> Detection? in
                guard let id = obs.labels.first?.identifier, obs.confidence >= minConfidence else {
                    return nil
                }
                return Detection.fromVision(label: id, confidence: obs.confidence,
                                            visionBox: obs.boundingBox)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount))
    }

    /// Labeled detections matching any of `labels` — a filter over
    /// `detectAll` for callers outside the engine tick (calibration). Label
    /// SETS keep the code working across model generations (e.g. "Basketball
    /// Hoop" in the original weights vs "rim" in the eagle-eye retrain).
    func detect(labels: Set<String>, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [Detection] {
        Array(detectAll(in: pixelBuffer, minConfidence: minConfidence)
            .filter { labels.contains($0.label) }
            .prefix(maxCount))
    }
}
