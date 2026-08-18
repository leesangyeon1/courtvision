import XCTest
@testable import CourtVision

/// The whole pipeline over a real clip with the real models — the off-device
/// regression test. Also the ground-truth flow: set
/// TEST_RUNNER_COURTVISION_REPLAY_CLIP=/abs/path.mp4 to replay any clip and
/// get `<clip>.events.json` next to it for tools/eval_events.py.
final class EngineReplayTests: XCTestCase {
    private func write(_ events: [ShotEvent], to url: URL) throws {
        let data = try JSONEncoder().encode(events)
        try data.write(to: url)
        print("EVENTS_JSON=\(url.path)")
    }

    func testBundledClipProducesResolvedAttempts() async throws {
        let bundle = Bundle(for: EngineReplayTests.self)
        let clip = try XCTUnwrap(bundle.url(forResource: "freethrow", withExtension: "mp4"),
                                 "Fixtures/freethrow.mp4 missing from the test bundle")
        let result = try await EngineReplay.run(url: clip)
        XCTAssertGreaterThan(result.moments.count, 10)
        let resolved = result.events.filter { $0.kind != .attempt }
        XCTAssertGreaterThanOrEqual(resolved.count, 1, "no attempt resolved on the fixture clip")
        XCTAssertTrue(resolved.allSatisfy { $0.resolvedPts != nil })
        try write(result.events, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("freethrow.events.json"))
    }

    func testReplayClipFromEnvironment() async throws {
        guard let path = ProcessInfo.processInfo.environment["COURTVISION_REPLAY_CLIP"] else {
            throw XCTSkip("set TEST_RUNNER_COURTVISION_REPLAY_CLIP to replay a clip")
        }
        let clip = URL(fileURLWithPath: path)
        let result = try await EngineReplay.run(url: clip)
        try write(result.events, to: clip.deletingPathExtension().appendingPathExtension("events.json"))
    }
}
