import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Jersey-number reading (PLAYER MODULE): the trained model detects `number`
/// regions on jerseys; Vision OCR reads the digits from just those regions
/// (regionOfInterest — no full-frame text pass). Non-numeric reads are
/// dropped, so a sponsor logo never becomes a jersey number.
enum NumberReader {
    /// Digits found in one frame with the region's center point (normalized,
    /// TOP-LEFT origin) for player association.
    static func read(in pixelBuffer: CVPixelBuffer, maxCount: Int = 8) -> [(point: CGPoint, digits: String)] {
        let regions = ObjectDetector.unified?.detect(labels: ["number"], in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.3)
            .map(\.box) ?? []
        guard !regions.isEmpty else { return [] }

        var results: [(CGPoint, String)] = []
        for region in regions {
            // Pad the crop a little; convert top-left → Vision's bottom-left.
            let padded = region.insetBy(dx: -region.width * 0.2, dy: -region.height * 0.2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let roi = CGRect(x: padded.origin.x,
                             y: 1 - padded.origin.y - padded.height,
                             width: padded.width,
                             height: padded.height)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.regionOfInterest = roi

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            try? handler.perform([request])

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined()
            let digits = text.filter(\.isNumber)
            if (1...2).contains(digits.count) {
                results.append((CGPoint(x: region.midX, y: region.midY), digits))
            }
        }
        return results
    }
}
