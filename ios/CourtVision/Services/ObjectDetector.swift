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
    /// Letterboxed (`.scaleFit`) — matches Ultralytics training. Measured on
    /// the fixture clip vs `.scaleFill`: near/large players found instead of
    /// missed, ball ticks 12 → 30, duplicates halved (docs/EVAL.md).
    static let unified = ObjectDetector(resource: "BasketballDetector", scale: .scaleFit)
    /// Rim runs on the original HoopDetector — field-tested better for rims
    /// than the unified model; unified is the fallback. Keeps `.scaleFill`
    /// (45 vs 44 rim ticks on the fixture; the field-tested setting).
    static let hoop = ObjectDetector(resource: "HoopDetector", scale: .scaleFill) ?? unified
    static let ball = unified
    static let player = unified

    private let model: VNCoreMLModel
    /// How a 16:9 frame becomes the model's square input: `.scaleFit`
    /// letterboxes (aspect kept), `.scaleFill` stretches.
    var scaleOption: VNImageCropAndScaleOption

    init?(resource: String, scale: VNImageCropAndScaleOption = .scaleFit) {
        scaleOption = scale
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
    /// `roi` (normalized, TOP-LEFT origin) restricts the pass to a region of
    /// the frame — the model then sees that region at full input resolution
    /// (a far-court band gets ~2× the pixels per player). Boxes come back in
    /// full-frame coordinates.
    func detectAll(in pixelBuffer: CVPixelBuffer, minConfidence: Float,
                   maxCount: Int = 64, roi: CGRect? = nil) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = scaleOption
        var visionROI: CGRect?
        if let roi {
            let r = CGRect(x: roi.origin.x, y: 1 - roi.origin.y - roi.height, width: roi.width, height: roi.height)
            request.regionOfInterest = r
            visionROI = r
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return Array((request.results as? [VNRecognizedObjectObservation] ?? [])
            .compactMap { obs -> Detection? in
                guard let id = obs.labels.first?.identifier, obs.confidence >= minConfidence else {
                    return nil
                }
                var box = obs.boundingBox                      // ROI-relative when an ROI was set
                if let r = visionROI {
                    box = CGRect(x: r.origin.x + box.origin.x * r.width, y: r.origin.y + box.origin.y * r.height,
                                 width: box.width * r.width, height: box.height * r.height)
                }
                return Detection.fromVision(label: id, confidence: obs.confidence, visionBox: box)
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
