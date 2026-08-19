import XCTest
@testable import CourtVision

final class TeamAssignerTests: XCTestCase {
    private let white = SIMD3<Float>(0.92, 0.92, 0.90)
    private let black = SIMD3<Float>(0.08, 0.07, 0.09)

    func testTwoJerseyColorsSplitIntoBrightAAndDarkB() {
        var t = TeamAssigner()
        // Not enough evidence yet → nil (never a guess).
        t.observe(track: 1, color: white)
        XCTAssertNil(t.team(of: 1))
        for i in 0..<6 { t.observe(track: 1 + (i % 2), color: i % 2 == 0 ? white : black) }
        for _ in 0..<3 { t.observe(track: 3, color: SIMD3(0.85, 0.88, 0.90)); t.observe(track: 4, color: SIMD3(0.12, 0.10, 0.10)) }
        XCTAssertEqual(t.team(of: 1), "A")      // white  → brighter cluster → A
        XCTAssertEqual(t.team(of: 2), "B")
        XCTAssertEqual(t.team(of: 3), "A")
        XCTAssertEqual(t.team(of: 4), "B")
    }

    func testMajorityVotePersistsAndSwapFlipsLabels() {
        var t = TeamAssigner()
        for _ in 0..<5 { t.observe(track: 1, color: white); t.observe(track: 2, color: black) }
        t.observe(track: 1, color: black)                       // one bad crop (occluder)
        XCTAssertEqual(t.team(of: 1), "A")
        t.swapped = true
        XCTAssertEqual(t.team(of: 1), "B")
        XCTAssertEqual(t.team(of: 2), "A")
    }

    func testForgetDropsDeadTracks() {
        var t = TeamAssigner()
        for _ in 0..<5 { t.observe(track: 1, color: white); t.observe(track: 2, color: black) }
        t.forget(except: [2])
        XCTAssertNil(t.team(of: 1))
        XCTAssertEqual(t.team(of: 2), "B")
    }
}
