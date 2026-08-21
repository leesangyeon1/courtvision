import CoreGraphics
import Foundation

/// 3×3 planar homography estimated from 4+ point correspondences via the
/// Direct Linear Transform — exact for 4 pairs, least-squares (normal
/// equations) for more; extra landmarks average out tap error. Solved with
/// Gaussian elimination (partial pivoting). Pure Swift — no Accelerate/OpenCV.
///
/// Used to map normalized camera-view points onto court feet coordinates
/// from the tapped calibration landmarks.
struct Homography: Hashable, Codable {
    /// Row-major 3×3 matrix with h33 normalized to 1.
    let m: [Double]

    init?(matrix: [Double]) {
        guard matrix.count == 9 else { return nil }
        m = matrix
    }

    /// Builds H such that H · src[i] ≈ dst[i] for all pairs (least squares).
    /// Returns nil when the points are degenerate (collinear / duplicated).
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        let n = src.count
        guard n >= 4, dst.count == n else { return nil }

        // DLT: each pair (x,y) → (u,v) gives two rows of A·h = b with
        // unknowns h = (h11…h32) and h33 fixed to 1. For n > 4 solve the
        // normal equations AᵀA·h = Aᵀb (8×8, stored augmented).
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<n {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            let rows = [([x, y, 1, 0, 0, 0, -u * x, -u * y], u),
                        ([0, 0, 0, x, y, 1, -v * x, -v * y], v)]
            for (row, rhs) in rows {
                for r in 0..<8 {
                    guard row[r] != 0 else { continue }
                    for c in 0..<8 { a[r][c] += row[r] * row[c] }
                    a[r][8] += row[r] * rhs
                }
            }
        }

        // Gauss-Jordan elimination with partial pivoting.
        for col in 0..<8 {
            var pivot = col
            for row in (col + 1)..<8 where abs(a[row][col]) > abs(a[pivot][col]) {
                pivot = row
            }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let factor = a[row][col] / a[col][col]
                guard factor != 0 else { continue }
                for c in col..<9 { a[row][c] -= factor * a[col][c] }
            }
        }

        var h = [Double](repeating: 0, count: 9)
        for i in 0..<8 { h[i] = a[i][8] / a[i][i] }
        h[8] = 1
        m = h
    }

    /// Inverse homography (court → image when self maps image → court), via
    /// the adjugate. Nil when the matrix is singular.
    func inverted() -> Homography? {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7]
        let c1 = a[5] * a[6] - a[3] * a[8]
        let c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-12 else { return nil }
        let inv = [
            c0 / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
            c1 / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
            c2 / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det,
        ]
        return Homography(matrix: inv)
    }

    /// Projective transform of a point (homogeneous divide).
    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return .zero }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }
}
