import XCTest
@testable import CourtVision

/// Fixtures mirror tools/simulate_session.py — the reference implementation of
/// the shared court geometry.
final class ZoneMapperTests: XCTestCase {
    func testCornerThree() {
        XCTAssertEqual(ZoneMapper.zone(xFt: 2, yFt: 8, freeThrow: false), .left_corner_3)
        XCTAssertEqual(ZoneMapper.zone(xFt: 48, yFt: 8, freeThrow: false), .right_corner_3)
        XCTAssertEqual(ZoneMapper.category(xFt: 2, yFt: 8, freeThrowMode: false), .three)
    }

    func testTopOfKeyAndArc() {
        XCTAssertEqual(ZoneMapper.zone(xFt: 25, yFt: 21, freeThrow: false), .top_key)
        XCTAssertEqual(ZoneMapper.zone(xFt: 23, yFt: 22, freeThrow: false), .top_key)
        XCTAssertEqual(ZoneMapper.zone(xFt: 25, yFt: 30, freeThrow: false), .top_arc_3)
        XCTAssertEqual(ZoneMapper.zone(xFt: 6, yFt: 24, freeThrow: false), .left_wing_3)
        XCTAssertEqual(ZoneMapper.zone(xFt: 44, yFt: 24, freeThrow: false), .right_wing_3)
    }

    func testPaintLayup() {
        XCTAssertEqual(ZoneMapper.zone(xFt: 25, yFt: 7, freeThrow: false), .paint)
        XCTAssertEqual(ZoneMapper.category(xFt: 25, yFt: 7, freeThrowMode: false), .layup)
        // Dunk requires the release-at-rim signal on top of distance ≤ 3 ft.
        XCTAssertEqual(ZoneMapper.category(xFt: 26, yFt: 7.5, freeThrowMode: false,
                                           releaseAtRim: true), .dunk)
        XCTAssertEqual(ZoneMapper.category(xFt: 26, yFt: 7.5, freeThrowMode: false,
                                           releaseAtRim: false), .layup)
        // Floater band and mid-range fall-through.
        XCTAssertEqual(ZoneMapper.category(xFt: 23, yFt: 15, freeThrowMode: false), .floater)
        XCTAssertEqual(ZoneMapper.category(xFt: 12, yFt: 10, freeThrowMode: false), .mid_range)
        XCTAssertEqual(ZoneMapper.zone(xFt: 12, yFt: 10, freeThrow: false), .mid_left)
        XCTAssertEqual(ZoneMapper.zone(xFt: 38, yFt: 10, freeThrow: false), .mid_right)
    }

    func testFreeThrow() {
        XCTAssertEqual(ZoneMapper.zone(xFt: 25, yFt: 19, freeThrow: true), .ft_line)
        XCTAssertEqual(ZoneMapper.category(xFt: 25, yFt: 19, freeThrowMode: true), .free_throw)
    }

    func testNormalizedClamps() {
        let n = ZoneMapper.normalized(xFt: 25, yFt: 19)
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 19.0 / 47.0, accuracy: 1e-9)
        XCTAssertEqual(ZoneMapper.normalized(xFt: -5, yFt: 60).x, 0)
        XCTAssertEqual(ZoneMapper.normalized(xFt: -5, yFt: 60).y, 1)
    }
}
