import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// The one trained detector shared by the Rim and Ball modules: YOLOv8n
/// ("Basketball" / "Basketball Hoop" classes, exported to CoreML with NMS)
/// compiled into the bundle as `HoopDetector.mlmodelc`. `shared` is nil if
/// the model is missing so heuristic fallbacks stay in charge — no fake
/// detections, ever.
final class ObjectDetector {
    static let shared = ObjectDetector()

    private let model: VNCoreMLModel

    init?() {
        guard let url = Bundle.main.url(forResource: "HoopDetector", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        model = visionModel
    }

    /// Boxes for one class in one frame (normalized, TOP-LEFT origin),
    /// best-confidence first, capped at `maxCount`.
    func detect(label: String, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [CGRect] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { $0.labels.first?.identifier == label && $0.confidence >= minConfidence }
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
