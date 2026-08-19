import CoreGraphics
import CoreVideo
import simd

/// Which team a tracked player is on, from jersey color — no training, no
/// roster (ref 02's SigLIP → UMAP → K-means idea, reduced to what a phone
/// needs: mean chest color → online 2-means → per-track majority vote).
/// Label rule: the brighter cluster is "A" (`swapped` flips it — the ⇄
/// button in the record screen). Never guesses: nil until there is
/// evidence for two clusters and a vote for the track.
struct TeamAssigner: Equatable {
    /// Samples needed before the two cluster centers are seeded.
    var warmup = 6
    /// Center update rate (EMA) per new sample.
    var alpha: Float = 0.05
    /// Flip which cluster is "A" (user override).
    var swapped = false

    private var samples: [SIMD3<Float>] = []
    private var centers: [SIMD3<Float>]?          // [0], [1] once seeded
    private var votes: [Int: [Int]] = [:]         // track → [votes for 0, votes for 1]

    mutating func observe(track: Int, color: SIMD3<Float>) {
        if centers == nil {
            samples.append(color)
            guard samples.count >= warmup else { return }
            // Seed with the farthest pair — the two jerseys.
            var best = (0, 1, Float(-1))
            for i in 0..<samples.count { for j in (i + 1)..<samples.count {
                let d = simd_distance_squared(samples[i], samples[j])
                if d > best.2 { best = (i, j, d) }
            } }
            centers = [samples[best.0], samples[best.1]]
            for s in samples { _ = assign(s) }
            samples.removeAll()
        }
        let k = assign(color)
        votes[track, default: [0, 0]][k] += 1
    }

    /// Nearest center; nudges it toward the sample.
    private mutating func assign(_ c: SIMD3<Float>) -> Int {
        guard var cs = centers else { return 0 }
        let k = simd_distance_squared(c, cs[0]) <= simd_distance_squared(c, cs[1]) ? 0 : 1
        cs[k] += (c - cs[k]) * alpha
        centers = cs
        return k
    }

    /// "A" / "B" by majority vote, nil without evidence.
    func team(of track: Int) -> String? {
        guard let cs = centers, let v = votes[track], v[0] != v[1] else { return nil }
        let cluster = v[0] > v[1] ? 0 : 1
        let brighter = luma(cs[0]) >= luma(cs[1]) ? 0 : 1
        let isA = (cluster == brighter) != swapped
        return isA ? "A" : "B"
    }

    /// Drop votes of tracks that no longer exist.
    mutating func forget(except live: Set<Int>) {
        votes = votes.filter { live.contains($0.key) }
    }

    private func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    // ------------------------------------------------------------ sampling

    /// Mean RGB (0…1) of the chest region of a player box — x 25–75 %,
    /// y 20–50 % of the box — from a BGRA pixel buffer, ~10×10 samples.
    /// Nil when the buffer isn't BGRA or the region is empty.
    static func torsoColor(in pixelBuffer: CVPixelBuffer, box: CGRect) -> SIMD3<Float>? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let x0 = Int(CGFloat(w) * (box.minX + box.width * 0.25)), x1 = Int(CGFloat(w) * (box.minX + box.width * 0.75))
        let y0 = Int(CGFloat(h) * (box.minY + box.height * 0.20)), y1 = Int(CGFloat(h) * (box.minY + box.height * 0.50))
        guard x1 > x0, y1 > y0, x0 >= 0, y0 >= 0, x1 <= w, y1 <= h else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let sx = max(1, (x1 - x0) / 10), sy = max(1, (y1 - y0) / 10)
        var sum = SIMD3<Float>(0, 0, 0); var n: Float = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let i = y * stride + x * 4               // B G R A
                sum += SIMD3(Float(p[i + 2]), Float(p[i + 1]), Float(p[i])) / 255
                n += 1
                x += sx
            }
            y += sy
        }
        return n > 0 ? sum / n : nil
    }
}
