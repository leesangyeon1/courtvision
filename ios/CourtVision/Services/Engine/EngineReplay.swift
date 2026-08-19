import AVFoundation
import CoreImage
import CoreVideo

/// One replayed tick: the decoded frame plus what the engine made of it.
struct ReplayFrame {
    let pts: Double
    let image: CGImage
    let moment: Moment
    let events: [ShotEvent]
}

/// Runs the engine over a video file exactly as the live loop would (same
/// tick throttle, thermal ignored). Backs the Replay screen (iPhone / iPad /
/// Mac: import a clip, watch the engine's view, tap to lock rims) and the
/// headless `EngineReplay.run` used by tests and docs/EVAL.md.
final class ReplaySession {
    let url: URL
    let engine: Engine
    private var shots = ShotEventTracker()
    private let ciContext = CIContext(options: nil)
    /// Calibration stand-in when nobody taps: end A locks onto the first rim
    /// candidate seen (leftmost).
    var seedRim: Bool
    /// Stop decoding.
    var cancelled = false

    init(url: URL, config: Engine.Config = Engine.Config(), isGame: Bool = false, seedRim: Bool = true) {
        self.url = url
        self.seedRim = seedRim
        engine = Engine(config: config, calibration: nil, isGame: isGame,
                        attackingTeam: "A", rimAnchors: [:], initialRims: [:])
    }

    /// Decodes the clip and yields one `ReplayFrame` per engine tick.
    /// `paced` sleeps to real time (watch it like the live app); otherwise
    /// it runs as fast as the models allow.
    func frames(paced: Bool) -> AsyncThrowingStream<ReplayFrame, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) { [self] in
                do {
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
                    let wallStart = Date()
                    var firstPts: Double?
                    while !cancelled, let sample = output.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard engine.shouldTick(at: pts, thermal: .nominal),
                              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                        if paced {
                            let t0 = firstPts ?? pts
                            firstPts = t0
                            let due = wallStart.addingTimeInterval(pts - t0)
                            let wait = due.timeIntervalSinceNow
                            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                        }
                        var moment = engine.process(pixelBuffer, pts: pts)
                        if seedRim, engine.rim.rims.isEmpty, let c = engine.rim.lastCandidates.first {
                            engine.designateRim(at: CGPoint(x: c.midX, y: c.midY))
                            moment.rims = engine.rim.rims
                        }
                        let events = shots.update(moment)
                        guard let image = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer),
                                                                  from: CIImage(cvPixelBuffer: pixelBuffer).extent)
                        else { continue }
                        continuation.yield(ReplayFrame(pts: pts, image: image, moment: moment, events: events))
                    }
                    if reader.status == .failed, let error = reader.error { throw error }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum EngineReplay {
    struct Result {
        var moments: [Moment] = []
        var events: [ShotEvent] = []
    }

    /// Headless replay: everything the clip yields, as fast as possible.
    static func run(url: URL, config: Engine.Config = Engine.Config(),
                    isGame: Bool = false, seedRim: Bool = true) async throws -> Result {
        let session = ReplaySession(url: url, config: config, isGame: isGame, seedRim: seedRim)
        var result = Result()
        for try await frame in session.frames(paced: false) {
            result.moments.append(frame.moment)
            result.events.append(contentsOf: frame.events)
        }
        return result
    }
}
