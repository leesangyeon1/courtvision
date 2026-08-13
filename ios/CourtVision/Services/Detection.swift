import CoreGraphics

/// One labeled detection (Layer 1 output). Box is normalized, TOP-LEFT
/// origin. Label and confidence survive the detector boundary so the
/// tracking and state-classification layers can tell classes apart.
struct Detection: Equatable {
    var box: CGRect
    var label: String
    var confidence: Float

    /// Vision boxes are bottom-left origin; flip to top-left here, once.
    static func fromVision(label: String, confidence: Float, visionBox b: CGRect) -> Detection {
        Detection(box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height,
                              width: b.width, height: b.height),
                  label: label, confidence: confidence)
    }
}
