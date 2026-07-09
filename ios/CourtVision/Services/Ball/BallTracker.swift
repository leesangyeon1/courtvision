import CoreGraphics
import CoreMedia
import Foundation
import Vision

/// One incremental update for a ball trajectory Vision is tracking.
struct TrajectoryUpdate {
    /// Stable per Vision trajectory observation — the same physical ball flight
    /// keeps the same id as more points are appended.
    let id: UUID
    /// Normalized image coordinates with a TOP-LEFT origin (UIKit-style), so
    /// increasing y means the ball is falling.
    let points: [CGPoint]
    /// Per-point timestamps (seconds, capture clock), linearly spread across
    /// the observation's timeRange (Vision does not expose per-point stamps).
    let timestamps: [TimeInterval]
    /// Parabola coefficients y = a·x² + b·x + c in Vision's native normalized
    /// space (BOTTOM-LEFT origin, y up). Used for the release angle.
    let a: Double
    let b: Double
    let c: Double
    let confidence: Double
}

/// Wrapper around VNDetectTrajectoriesRequest.
///
/// IMPORTANT: VNDetectTrajectoriesRequest assumes a STATIONARY camera — mount
/// the phone on a tripod. A moving background produces phantom trajectories.
final class BallTracker {
    /// Called on the vision processing queue for every trajectory update.
    var onUpdate: ((TrajectoryUpdate) -> Void)?

    private lazy var request: VNDetectTrajectoriesRequest = {
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                                  trajectoryLength: 6) { [weak self] req, _ in
            self?.handle(req)
        }
        // Bound the target size to basketball-like blobs.
        request.objectMinimumNormalizedRadius = 0.004
        request.objectMaximumNormalizedRadius = 0.08
        return request
    }()

    /// Feed frames in capture order (one persistent request across frames).
    func process(_ sampleBuffer: CMSampleBuffer) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        try? handler.perform([request])
    }

    private func handle(_ req: VNRequest) {
        guard let observations = req.results as? [VNTrajectoryObservation] else { return }
        for obs in observations where obs.confidence > 0.5 {
            let detected = obs.detectedPoints
            guard detected.count >= 2 else { continue }

            // Convert Vision bottom-left normalized points to top-left origin.
            let points = detected.map { CGPoint(x: $0.x, y: 1 - $0.y) }

            let start = obs.timeRange.start.seconds
            let duration = obs.timeRange.duration.seconds
            let n = points.count
            let timestamps = (0..<n).map { i in
                start + (n > 1 ? duration * Double(i) / Double(n - 1) : 0)
            }

            let coeff = obs.equationCoefficients
            onUpdate?(TrajectoryUpdate(id: obs.uuid,
                                       points: points,
                                       timestamps: timestamps,
                                       a: Double(coeff.x),
                                       b: Double(coeff.y),
                                       c: Double(coeff.z),
                                       confidence: Double(obs.confidence)))
        }
    }
}
