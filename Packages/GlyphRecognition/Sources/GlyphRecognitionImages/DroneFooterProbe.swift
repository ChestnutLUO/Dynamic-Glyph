import CoreGraphics
import Foundation
import GlyphRecognition

/// The drone view's footer: a short yellow label ("DRONE FOOTAGE", or its
/// translation) centred in a dark tab at the bottom of the screen.
///
/// Pixels only. A candidate is never a drone verdict: a text read checks the
/// phrase, unless these same footer pixels were already read as one.
public enum DroneFooterProbe {
    /// The centre of the bottom strip, where the label sits: 60% of the
    /// width, the bottom 4.5% of the frame above the last 1%. The field
    /// recording's English label spans 33-67% of the width; the other
    /// languages' labels are no longer.
    public static func textRect(width: Int, height: Int) -> CGRect {
        CGRect(x: Double(width) * 0.2, y: Double(height) * 0.945,
               width: Double(width) * 0.6, height: Double(height) * 0.045).integral
    }

    /// Rows handed to the text read at most. A full-resolution frame's crop
    /// is scaled down to this; a broadcast's ~1310-row frame gives ~59 rows
    /// and is read as it is.
    public static let maximumReadHeight = 64

    /// Signature grid: columns and rows of yellow cells over `textRect`.
    static let gridColumns = 32, gridRows = 8
    /// Differing cells still counted as the same footer: a few cells of
    /// scaling noise, far fewer than any other label's.
    static let signatureTolerance = 10

    public struct Candidate: Sendable, Equatable {
        public let yellow: Int
        /// Which cells of the label hold yellow, to recognize a footer
        /// already read.
        public let signature: [UInt8]
    }

    @inline(__always)
    static func isYellow(_ p: (red: UInt8, green: UInt8, blue: UInt8)) -> Bool {
        p.red > 130 && p.green > 100 && Double(p.blue) < Double(p.green) * 0.7
    }

    /// `pixels` is `textRect`'s region. Yellow lettering centred in the
    /// region, neither too little nor a solid bar: about 700 of 361×59
    /// pixels in the field recording, 19% of the box around them.
    public static func candidate(_ pixels: ColorImage) -> Candidate? {
        let w = pixels.width, h = pixels.height
        var yellow = 0, left = w, right = -1, top = h, bottom = -1
        var cells = [Int](repeating: 0, count: gridColumns * gridRows)
        for y in 0..<h {
            let row = min(gridRows - 1, y * gridRows / h)
            for x in 0..<w where isYellow(pixels[x, y]) {
                yellow += 1
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                cells[row * gridColumns + min(gridColumns - 1, x * gridColumns / w)] += 1
            }
        }
        // As much yellow as the old full-strip test asked for (a third of
        // the frame's width, which is 60% of this region's).
        guard yellow * 9 > w * 5, right >= left else { return nil }
        let span = right - left + 1, rows = bottom - top + 1
        // A centred label, not a bar across the strip or a corner's colour.
        guard abs(left + right + 1 - w) <= w / 8, span * 20 <= w * 17,
              yellow * 5 <= span * rows * 3 else { return nil }
        let cellArea = max(1, (w / gridColumns) * (h / gridRows))
        let signature = cells.map { $0 * 8 > cellArea ? UInt8(1) : 0 }
        return Candidate(yellow: yellow, signature: signature)
    }

    /// The same footer's pixels as a read already confirmed.
    public static func matches(_ signature: [UInt8], _ known: [UInt8]) -> Bool {
        signature.count == known.count
            && zip(signature, known).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } <= signatureTolerance
    }

    /// The label's region as its own small image, scaled to at most
    /// `maximumReadHeight` rows: a plain crop would keep the whole frame
    /// alive while it waits for its read.
    public static func readCrop(_ image: CGImage) -> CGImage? {
        let rect = textRect(width: image.width, height: image.height)
        guard let cropped = image.cropping(to: rect) else { return nil }
        let scale = min(1, Double(maximumReadHeight) / Double(cropped.height))
        let width = max(1, Int((Double(cropped.width) * scale).rounded()))
        let height = max(1, Int((Double(cropped.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return cropped }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? cropped
    }
}
