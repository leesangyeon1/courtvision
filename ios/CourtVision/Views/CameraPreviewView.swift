import AVFoundation
import SwiftUI

/// Hosts the AVCaptureVideoPreviewLayer for the calibration/record screens.
///
/// V1 coordinate note: taps and overlays are normalized against the VIEW while
/// the preview uses .resizeAspectFill — with the phone framing the court in
/// landscape-ish 16:9 the difference is small; documented approximation.
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = camera.captureSession
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
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
