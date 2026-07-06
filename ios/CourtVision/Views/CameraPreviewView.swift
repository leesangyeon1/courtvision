import AVFoundation
import SwiftUI

/// Shared handle to the live AVCaptureVideoPreviewLayer so SwiftUI views can
/// convert between view (layer) points and buffer (capture-device) normalized
/// coordinates. Published so overlays re-render once the layer exists.
final class PreviewLayerHolder: ObservableObject {
    weak var layer: AVCaptureVideoPreviewLayer? {
        didSet { objectWillChange.send() }
    }
}

/// Hosts the AVCaptureVideoPreviewLayer for the calibration/record screens.
///
/// Coordinate note: the portrait-locked UI shows a landscape sensor buffer
/// through .resizeAspectFill, so raw view fractions do NOT match buffer
/// coordinates. Taps and overlays must round-trip through the preview layer
/// (captureDevicePointConverted / layerPointConverted) via `holder`.
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService
    let holder: PreviewLayerHolder

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = camera.captureSession
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        let layer = view.videoPreviewLayer
        DispatchQueue.main.async { holder.layer = layer }  // publish outside the view update
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
