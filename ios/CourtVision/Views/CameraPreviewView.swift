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
/// Coordinate note: raw view fractions do NOT match buffer coordinates
/// (aspect letterboxing + rotation). Taps and overlays must round-trip
/// through the preview layer (captureDevicePointConverted /
/// layerPointConverted) via `holder`.
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService
    let holder: PreviewLayerHolder

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = camera.captureSession
        // Fullscreen fill: the ultra-wide lens leaves plenty of margin, so the
        // slight edge crop of aspectFill never hides court corners in practice.
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        let layer = view.videoPreviewLayer
        DispatchQueue.main.async {
            // UI is locked to landscape-right = sensor-native orientation.
            if let conn = layer.connection, conn.isVideoRotationAngleSupported(0) {
                conn.videoRotationAngle = 0
            }
            holder.layer = layer  // publish outside the view update
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Session may attach its connection after makeUIView ran.
        if let conn = uiView.videoPreviewLayer.connection,
           conn.isVideoRotationAngleSupported(0), conn.videoRotationAngle != 0 {
            conn.videoRotationAngle = 0
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
