import AVFoundation
import CoreVideo

/// Runs the engine over a video file exactly as the live loop would (same
/// tick throttle, thermal ignored), collecting Moments and shot events. Used
/// by EngineReplayTests and the ground-truth eval flow (docs/EVAL.md).
enum EngineReplay {
    struct Result {
        var moments: [Moment] = []
        var events: [ShotEvent] = []
    }

    /// `seedRim`: the calibration screen's stand-in — with no tap available
    /// in a replay, end A locks onto the first rim candidate seen (leftmost).
    static func run(url: URL, config: Engine.Config = Engine.Config(),
                    isGame: Bool = false, seedRim: Bool = true) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let engine = Engine(config: config, calibration: nil, isGame: isGame,
                            attackingTeam: "A", rimAnchors: [:], initialRims: [:])
        var shots = ShotEventTracker()
        var result = Result()
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard engine.shouldTick(at: pts, thermal: .nominal),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var moment = engine.process(pixelBuffer, pts: pts)
            if seedRim, engine.rim.rims.isEmpty, let c = engine.rim.lastCandidates.first {
                engine.designateRim(at: CGPoint(x: c.midX, y: c.midY))
                moment.rims = engine.rim.rims
            }
            result.moments.append(moment)
            result.events.append(contentsOf: shots.update(moment))
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return result
    }
}
