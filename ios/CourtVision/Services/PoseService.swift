import CoreGraphics
import CoreMedia
import Foundation
import Vision

/// One body-pose measurement used for shot location + release detection.
struct PoseSample {
    let timestamp: TimeInterval
    /// Midpoint of the two ankles (or the single visible ankle), normalized
    /// image coordinates with TOP-LEFT origin. This is the shooter's floor
    /// position fed through the homography.
    let ankleMidpoint: CGPoint?
    /// Highest visible wrist, measured as normalized height from the BOTTOM of
    /// the frame (0 = bottom, 1 = top). Supports release detection.
    let wristHeight: Double?
}

/// VNDetectHumanBodyPoseRequest wrapper. Keeps a short ring buffer of samples
/// so the shot detector can look up the pose nearest to a release timestamp.
final class PoseService {
    private let request = VNDetectHumanBodyPoseRequest()
    private var samples: [PoseSample] = []
    private let maxSamples = 240
    private let lock = NSLock()

    /// Process one camera frame (call from the vision queue).
    func process(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return }
        let sample = Self.sample(from: observation, at: timestamp)
        lock.lock()
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        lock.unlock()
    }

    static func sample(from observation: VNHumanBodyPoseObservation,
                       at timestamp: TimeInterval) -> PoseSample {
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? observation.recognizedPoint(joint), p.confidence > 0.3 else {
                return nil
            }
            return CGPoint(x: p.location.x, y: 1 - p.location.y)  // → top-left origin
        }

        let ankleMidpoint: CGPoint?
        if let l = point(.leftAnkle), let r = point(.rightAnkle) {
            ankleMidpoint = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        } else {
            ankleMidpoint = point(.leftAnkle) ?? point(.rightAnkle)
        }

        let wristHeight = [point(.leftWrist), point(.rightWrist)]
            .compactMap { $0 }
            .map { 1 - Double($0.y) }   // back to height-from-bottom
            .max()

        return PoseSample(timestamp: timestamp,
                          ankleMidpoint: ankleMidpoint,
                          wristHeight: wristHeight)
    }

    /// The sample closest to `timestamp`, or nil when nothing is within
    /// `tolerance` seconds (e.g. the shooter left the frame).
    func sample(nearest timestamp: TimeInterval,
                tolerance: TimeInterval = 0.5) -> PoseSample? {
        lock.lock()
        defer { lock.unlock() }
        guard let best = samples.min(by: {
            abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp)
        }) else { return nil }
        return abs(best.timestamp - timestamp) <= tolerance ? best : nil
    }
}
