import CoreGraphics
import CoreVideo
import Vision

/// Body-pose evidence for ONE player box per tick (the possession / shooting
/// tracks only — never a full-frame pass). Feeds `FeetHistory` so the shot
/// location comes from the set point on the floor, not from a bbox bottom in
/// mid-air (ref 02's failure).
enum PoseReader {
    struct Sample: Equatable {
        let pts: Double
        /// Ankle midpoint (or the single visible ankle), normalized image
        /// coordinates, TOP-LEFT origin. Nil when no ankle is confident.
        let ankleMid: CGPoint?
    }

    /// Runs Vision body pose on `box` (normalized, top-left origin) only.
    static func read(in pixelBuffer: CVPixelBuffer, roi box: CGRect, pts: Double) -> Sample? {
        let padded = box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.1)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isEmpty else { return nil }
        // Vision ROI is bottom-left origin.
        let roi = CGRect(x: padded.origin.x, y: 1 - padded.origin.y - padded.height,
                         width: padded.width, height: padded.height)
        let request = VNDetectHumanBodyPoseRequest()
        request.regionOfInterest = roi
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }

        // Points come back normalized to the ROI (bottom-left origin); map to
        // the frame, then flip to top-left.
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 else { return nil }
            let f = toFrame(p.location, roi: roi)
            return CGPoint(x: f.x, y: 1 - f.y)
        }
        let l = point(.leftAnkle), r = point(.rightAnkle)
        let mid: CGPoint?
        if let l, let r { mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2) } else { mid = l ?? r }
        return Sample(pts: pts, ankleMid: mid)
    }

    /// ROI-relative normalized point → frame-normalized point (both Vision,
    /// bottom-left origin).
    static func toFrame(_ p: CGPoint, roi: CGRect) -> CGPoint {
        CGPoint(x: roi.origin.x + p.x * roi.width, y: roi.origin.y + p.y * roi.height)
    }
}

/// Per-track ring of pose samples. Answers "where were this player's feet
/// the last time they were on the floor" — the lowest ankle midpoint on
/// screen (max y) inside the window.
struct FeetHistory: Equatable {
    private var samples: [Int: [PoseReader.Sample]] = [:]
    /// Seconds of history kept per track (a jump shot's set point is < 1 s
    /// before the state class fires).
    var window: Double = 1.0

    mutating func add(_ s: PoseReader.Sample, track: Int, now pts: Double) {
        var list = samples[track, default: []]
        list.append(s)
        list.removeAll { pts - $0.pts > window }
        samples[track] = list
    }

    /// Drop history of tracks that no longer exist.
    mutating func prune(keeping live: Set<Int>) {
        samples = samples.filter { live.contains($0.key) }
    }

    func groundContact(track: Int) -> CGPoint? {
        samples[track]?.compactMap(\.ankleMid).max { $0.y < $1.y }
    }
}
