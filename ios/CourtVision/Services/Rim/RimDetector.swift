import CoreGraphics
import CoreMedia
import CoreML
import Foundation
import Vision

/// V1 path: the user drags rim boxes during calibration; the boxes are
/// persisted across launches (tripod setups rarely move between sessions).
/// Practice/drill/free-throw sessions use one rim; game sessions use two.
final class ManualRimDetector: ObservableObject {
    static let shared = ManualRimDetector()
    private static let defaultsKey = "courtvision.manualRimRects"

    @Published var rimRects: [CGRect] = [] {
        didSet { persist() }
    }

    init() {
        if let stored = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[Double]] {
            rimRects = stored.compactMap { v in
                v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
            }
        }
    }

    /// Make sure exactly `count` boxes exist, keeping any the user already
    /// placed. New boxes start at sensible defaults (left/right thirds).
    func ensureCount(_ count: Int) {
        var rects = rimRects
        let starts = [CGRect(x: 0.20, y: 0.20, width: 0.12, height: 0.07),
                      CGRect(x: 0.68, y: 0.20, width: 0.12, height: 0.07)]
        while rects.count < count {
            rects.append(starts[min(rects.count, starts.count - 1)])
        }
        if rects.count > count { rects.removeLast(rects.count - count) }
        if rects != rimRects { rimRects = rects }
    }

    private func persist() {
        UserDefaults.standard.set(
            rimRects.map { [Double($0.origin.x), Double($0.origin.y),
                            Double($0.width), Double($0.height)] },
            forKey: Self.defaultsKey
        )
    }
}

/// Trained hoop detector: YOLOv8n ("Basketball" / "Basketball Hoop" classes,
/// exported to CoreML with NMS) compiled into the bundle as
/// `HoopDetector.mlmodelc`. Returns nil if the model is missing so the
/// heuristic fallback stays in charge — no fake detections, ever.
final class CoreMLRimDetector {
    private let model: VNCoreMLModel

    init?() {
        guard let url = Bundle.main.url(forResource: "HoopDetector", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        model = visionModel
    }

    /// Hoop boxes in one frame (normalized, TOP-LEFT origin), best-confidence
    /// first capped at `maxCount`, then sorted left → right (rim 1 = left).
    func detectHoops(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [CGRect] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        let hoops = (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { $0.labels.first?.identifier == "Basketball Hoop" && $0.confidence >= 0.35 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount)
            .map { obs -> CGRect in
                let b = obs.boundingBox  // Vision: bottom-left origin
                return CGRect(x: b.origin.x,
                              y: 1 - b.origin.y - b.height,
                              width: b.width,
                              height: b.height)
            }
        return hoops.sorted { $0.midX < $1.midX }
    }
}
