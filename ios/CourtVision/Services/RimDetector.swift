import CoreGraphics
import CoreMedia
import CoreML
import Foundation
import Vision

/// Anything that can tell us where the rim is on screen.
/// `rimRect` is a bounding box in normalized image coordinates, TOP-LEFT origin.
protocol RimDetecting {
    var rimRect: CGRect? { get }
}

/// V1 path: the user drags a rim box during calibration; the box is persisted
/// across launches (tripod setups rarely move between sessions).
final class ManualRimDetector: RimDetecting, ObservableObject {
    static let shared = ManualRimDetector()
    private static let defaultsKey = "courtvision.manualRimRect"

    @Published var rimRect: CGRect? {
        didSet { persist() }
    }

    init() {
        if let v = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Double],
           v.count == 4 {
            rimRect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
    }

    private func persist() {
        guard let r = rimRect else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        UserDefaults.standard.set(
            [Double(r.origin.x), Double(r.origin.y), Double(r.width), Double(r.height)],
            forKey: Self.defaultsKey
        )
    }
}

/// Guarded CoreML slot: activates only when a compiled `Rim.mlmodelc` ships in
/// the app bundle. The model is ABSENT in V1, so `CoreMLRimDetector()` returns
/// nil and the manual detector stays in charge — no fake detections, ever.
final class CoreMLRimDetector: RimDetecting {
    private(set) var rimRect: CGRect?
    private let model: VNCoreMLModel

    init?() {
        guard let url = Bundle.main.url(forResource: "Rim", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        model = visionModel
    }

    /// Runs the detector on one frame and keeps the highest-confidence box.
    func process(_ sampleBuffer: CMSampleBuffer) {
        let request = VNCoreMLRequest(model: model)
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        try? handler.perform([request])
        guard let best = (request.results as? [VNRecognizedObjectObservation])?
            .max(by: { $0.confidence < $1.confidence }) else { return }
        let b = best.boundingBox  // Vision: bottom-left origin
        rimRect = CGRect(x: b.origin.x,
                         y: 1 - b.origin.y - b.height,
                         width: b.width,
                         height: b.height)
    }
}
