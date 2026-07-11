import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Rim acquisition (RIM MODULE): trained YOLO hoop CNN with an orange-blob
/// heuristic fallback, plus anchor-based selection for gyms with side hoops.
enum RimFinder {
    // ------------------------------------------------------------- rims

    /// Which detected rim is THE rim: nearest to `anchor` (a user tap or the
    /// previously tracked position). No anchor → most confident (first).
    /// Practice gyms hang 6+ side hoops; proximity beats confidence there.
    ///
    /// `within` caps the accepted distance from the anchor: a tap-designated
    /// rim must never be stolen by a detection elsewhere in the frame —
    /// when every candidate is farther than the cap, nil is returned and the
    /// caller keeps what the user set.
    static func pickRim(candidates: [CGRect], near anchor: CGPoint?,
                        within maxDistance: CGFloat? = nil) -> CGRect? {
        guard let anchor else { return candidates.first }
        let nearest = candidates.min {
            hypot($0.midX - anchor.x, $0.midY - anchor.y)
                < hypot($1.midX - anchor.x, $1.midY - anchor.y)
        }
        if let maxDistance, let nearest,
           hypot(nearest.midX - anchor.x, nearest.midY - anchor.y) > maxDistance {
            return nil
        }
        return nearest
    }

    /// Detects up to `maxCount` rims, sorted left → right (rim 1 = left).
    /// Trained CNN first; orange-blob heuristic as fallback (unusual rims,
    /// model miss). Empty when neither finds anything.
    static func detectRims(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [CGRect] {
        if let hoops = ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"],
                                                     in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.35),
           !hoops.isEmpty {
            return hoops.sorted { $0.midX < $1.midX }   // rim 1 = left
        }
        return detectRimsByColor(in: pixelBuffer, maxCount: maxCount)
    }

    /// Orange-blob fallback pass.
    static func detectRimsByColor(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [CGRect] {
        // Render a small RGBA bitmap — blob analysis needs no resolution.
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let srcW = ci.extent.width, srcH = ci.extent.height
        guard srcW > 0, srcH > 0 else { return [] }
        let w = 192
        let h = max(1, Int((CGFloat(w) * srcH / srcW).rounded()))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / srcW,
                                                          y: CGFloat(h) / srcH))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(scaled,
                       toBitmap: &rgba,
                       rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // CIContext bitmaps come out bottom-row-first; detect in that space
        // and flip y at the end.
        let flipped = detectRims(width: w, height: h, rgba: rgba, maxCount: maxCount)
        return flipped.map { CGRect(x: $0.origin.x, y: 1 - $0.origin.y - $0.height,
                                    width: $0.width, height: $0.height) }
    }

    /// Core blob pass on a raw RGBA bitmap (separated for testability).
    /// Returned rects are normalized to the bitmap's own coordinate space.
    static func detectRims(width w: Int, height h: Int, rgba: [UInt8], maxCount: Int) -> [CGRect] {
        guard rgba.count >= w * h * 4, maxCount > 0 else { return [] }

        // Orange mask: hue ≈ 5–40°, saturated, not too dark.
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(rgba[i * 4]) / 255
            let g = Double(rgba[i * 4 + 1]) / 255
            let b = Double(rgba[i * 4 + 2]) / 255
            let maxc = max(r, g, b), minc = min(r, g, b)
            let delta = maxc - minc
            guard maxc > 0.30, delta > 0.15, maxc == r else { continue }
            let hue = 60 * ((g - b) / delta)               // r is max: -60…60
            let sat = delta / maxc
            if hue >= 5, hue <= 40, sat >= 0.45 { mask[i] = true }
        }

        // Connected components (4-neighbour BFS) → bounding boxes.
        var visited = [Bool](repeating: false, count: w * h)
        var boxes: [(rect: CGRect, mass: Int)] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            visited[start] = true
            stack = [start]
            var minX = start % w, maxX = minX, minY = start / w, maxY = minY, mass = 0
            while let i = stack.popLast() {
                mass += 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for n in [i - 1, i + 1, i - w, i + w]
                where n >= 0 && n < w * h && mask[n] && !visited[n]
                    && abs((n % w) - x) <= 1 {
                    visited[n] = true
                    stack.append(n)
                }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            let aspect = Double(bw) / Double(bh)
            // Rim shape: wider than tall, 1.5–20% of frame width, in the
            // upper 75% of the frame (hoops are up), reasonably filled.
            guard mass >= 4,
                  aspect >= 1.2, aspect <= 6.0,
                  bw >= max(2, w * 15 / 1000), bw <= w / 5,
                  minY < h * 3 / 4,
                  Double(mass) / Double(bw * bh) >= 0.35 else { continue }
            boxes.append((CGRect(x: Double(minX) / Double(w),
                                 y: Double(minY) / Double(h),
                                 width: Double(bw) / Double(w),
                                 height: Double(bh) / Double(h)), mass))
        }

        return boxes.sorted { $0.mass > $1.mass }
            .prefix(maxCount)
            .map(\.rect)
            .sorted { $0.midX < $1.midX }                  // rim 1 = left
    }
}
