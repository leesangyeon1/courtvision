import Foundation

/// SHARED COURT GEOMETRY — must stay identical to the web dashboard and to
/// tools/simulate_session.py `classify()` (the reference implementation).
///
/// Half court: 50 ft wide × 47 ft deep, origin at the left end of the baseline,
/// rim center at (25, 5.25). Normalized: court_x = x/50, court_y = y/47.
/// Three-point line: 23.75 ft arc, corner lines at x ≤ 3 / x ≥ 47 for y ≤ 14.
enum ZoneMapper {
    static let courtWidthFt = 50.0
    static let courtDepthFt = 47.0
    static let rimXFt = 25.0
    static let rimYFt = 5.25
    static let threeRadiusFt = 23.75

    static func rimDistance(xFt x: Double, yFt y: Double) -> Double {
        hypot(x - rimXFt, y - rimYFt)
    }

    static func isThree(xFt x: Double, yFt y: Double) -> Bool {
        if y <= 14 && (x <= 3 || x >= 47) { return true }   // corner lines
        return rimDistance(xFt: x, yFt: y) >= threeRadiusFt // arc
    }

    /// Zone rule order mirrors simulate_session.py `classify()` exactly:
    /// freethrow-mode → ft_line; three & y ≤ 14 → corners; three & |x−25| ≤ 9 →
    /// top_arc_3 else wings; |x−25| ≤ 8 & y ≤ 19 → paint; |x−25| ≤ 8 → top_key;
    /// else mid_left / mid_right.
    static func zone(xFt x: Double, yFt y: Double, freeThrow: Bool) -> ShotZone {
        if freeThrow { return .ft_line }
        if isThree(xFt: x, yFt: y) {
            if y <= 14 { return x < 25 ? .left_corner_3 : .right_corner_3 }
            if abs(x - 25) <= 9 { return .top_arc_3 }
            return x < 25 ? .left_wing_3 : .right_wing_3
        }
        if abs(x - 25) <= 8 { return y <= 19 ? .paint : .top_key }
        return x < 25 ? .mid_left : .mid_right
    }

    /// Deterministic category heuristic, evaluated in this documented order:
    /// 1. freethrow-mode session                          → free_throw
    /// 2. behind the arc / corner line (isThree)          → three
    /// 3. rim distance ≤ 3 ft AND ball released at rim    → dunk
    /// 4. rim distance ≤ 6 ft                             → layup
    /// 5. rim distance ≤ 13 ft                            → floater
    /// 6. otherwise                                       → mid_range
    ///
    /// `releaseAtRim` comes from the shot detector: the release point of the
    /// trajectory was inside the expanded rim region (dunks release at the rim).
    static func category(xFt x: Double,
                         yFt y: Double,
                         freeThrowMode: Bool,
                         releaseAtRim: Bool = false) -> ShotCategory {
        if freeThrowMode { return .free_throw }
        if isThree(xFt: x, yFt: y) { return .three }
        let dist = rimDistance(xFt: x, yFt: y)
        if dist <= 3, releaseAtRim { return .dunk }
        if dist <= 6 { return .layup }
        if dist <= 13 { return .floater }
        return .mid_range
    }

    /// Feet → contract-normalized coordinates, clamped to 0…1.
    static func normalized(xFt: Double, yFt: Double) -> (x: Double, y: Double) {
        (min(max(xFt / courtWidthFt, 0), 1), min(max(yFt / courtDepthFt, 0), 1))
    }
}
