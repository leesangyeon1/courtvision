import XCTest
@testable import CourtVision

final class DetectionTests: XCTestCase {
    func testFromVisionFlipsYAndKeepsLabelConfidence() {
        // Vision box: bottom-left origin. y=0.1, h=0.2 → top-left y = 1-0.1-0.2 = 0.7
        let d = Detection.fromVision(label: "rim", confidence: 0.83,
                                     visionBox: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.2))
        XCTAssertEqual(d.label, "rim")
        XCTAssertEqual(d.confidence, 0.83)
        XCTAssertEqual(d.box, CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.2))
    }
}
