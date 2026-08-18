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

    static func run(url: URL, config: Engine.Config = Engine.Config(),
                    isGame: Bool = false) async throws -> Result {
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
                            attackingTeam: "A", rimAnchors: [:], initialRim: nil)
        var shots = ShotEventTracker()
        var result = Result()
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard engine.shouldTick(at: pts, thermal: .nominal),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let moment = engine.process(pixelBuffer, pts: pts)
            result.moments.append(moment)
            result.events.append(contentsOf: shots.update(moment))
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return result
    }
}
