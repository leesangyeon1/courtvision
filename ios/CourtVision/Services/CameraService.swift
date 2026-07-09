import AVFoundation
import Foundation

enum CameraError: LocalizedError {
    case permissionDenied
    case noBackCamera
    case cannotConfigure

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera access was denied. Enable it in Settings."
        case .noBackCamera: return "No back camera is available on this device."
        case .cannotConfigure: return "The camera session could not be configured."
        }
    }
}

/// Back-camera capture at 1080p, 60 fps when the active format supports it.
/// Frames are exposed as an AsyncStream<CMSampleBuffer> (single consumer: the
/// record pipeline) and as an AVCaptureVideoPreviewLayer for the UI.
final class CameraService: NSObject {
    let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "courtvision.camera.frames")
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var configured = false

    private let latestLock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?
    /// Most recent camera frame — lets calibration run auto-detection on a
    /// snapshot without consuming the frames stream.
    var latestPixelBuffer: CVPixelBuffer? {
        latestLock.lock(); defer { latestLock.unlock() }
        return _latestPixelBuffer
    }

    /// Live camera frames. Buffers only the newest frames — vision processing
    /// that falls behind drops frames instead of building latency.
    private(set) lazy var frames: AsyncStream<CMSampleBuffer> = AsyncStream(
        bufferingPolicy: .bufferingNewest(2)
    ) { [weak self] continuation in
        self?.continuation = continuation
    }

    /// Requests permission and configures the session once. Safe to call again.
    func configureIfNeeded() async throws {
        guard !configured else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw CameraError.permissionDenied
        }
        try configure()
        configured = true
    }

    private func configure() throws {
        // Ultra-wide (0.5x) first so a whole court fits in frame from the
        // sideline; fall back to the wide camera on devices without one.
        let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device else {
            throw CameraError.noBackCamera
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw CameraError.cannotConfigure }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard captureSession.canAddOutput(videoOutput) else { throw CameraError.cannotConfigure }
        captureSession.addOutput(videoOutput)

        // 60 fps if the active format supports it; otherwise keep the default.
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 }) {
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            device.unlockForConfiguration()
        }
    }

    func start() {
        guard configured else { return }
        DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestLock.lock()
            _latestPixelBuffer = pb
            latestLock.unlock()
        }
        continuation?.yield(sampleBuffer)
    }
}
