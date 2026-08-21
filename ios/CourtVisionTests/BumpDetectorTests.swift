import XCTest
@testable import CourtVision

final class BumpDetectorTests: XCTestCase {
    func testSpikeFiresOncePerCooldownAndNoiseNever() {
        var d = BumpDetector()
        // Sensor noise / hand on the tripod head: under threshold.
        for i in 0..<50 { XCTAssertFalse(d.feed(rate: 0.03, at: Double(i) * 0.1)) }
        XCTAssertTrue(d.feed(rate: 0.5, at: 6.0))       // the bump
        XCTAssertFalse(d.feed(rate: 0.5, at: 6.1))      // still shaking: same event
        XCTAssertFalse(d.feed(rate: 0.02, at: 7.0))
        XCTAssertTrue(d.feed(rate: 0.4, at: 9.0))       // a second bump after the cooldown
    }
}
