import CoreGraphics
import Foundation

/// 3×3 planar homography estimated from exactly 4 point correspondences via the
/// Direct Linear Transform, solved with Gaussian elimination (partial pivoting).
/// Pure Swift — no Accelerate/OpenCV dependency.
///
/// Used to map normalized camera-view points onto half-court feet coordinates
/// from the 4 calibration landmarks (baseline corners + FT-line corners).
struct Homography: Hashable {
    /// Row-major 3×3 matrix with h33 normalized to 1.
    let m: [Double]

    init?(matrix: [Double]) {
        guard matrix.count == 9 else { return nil }
        m = matrix
    }

    /// Builds H such that H · src[i] ≈ dst[i] for the 4 pairs.
    /// Returns nil when the points are degenerate (collinear / duplicated).
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4 else { return nil }

        // DLT: for each pair (x,y) → (u,v), two rows of the 8×8 system A·h = b
        // with unknowns h = (h11…h32) and h33 fixed to 1. Stored augmented.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
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

    /// Projective transform of a point (homogeneous divide).
    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return .zero }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }
}
