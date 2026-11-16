import GlyphRecognition

extension StillSignature {
    /// The grid over the rectangle `left`, `top`, `width`, `height` of the
    /// capture's planes, read in place. Grey is the Y plane's value for NV12,
    /// in its own range, and `LumaGate`'s weights for BGRA. Signatures from
    /// planes compare with signatures from planes of the same format only:
    /// Y is not the RGB grey of `init(rgb:)`. Nil when the rectangle is empty
    /// or not inside the frame.
    public init?(planes: FramePlanes, left: Int, top: Int, width: Int, height: Int, columns: Int, rows: Int) {
        guard left >= 0, top >= 0, width > 0, height > 0, left + width <= planes.width,
              top + height <= planes.height else { return nil }
        let base = planes.base.assumingMemoryBound(to: UInt8.self)
        let stride = planes.bytesPerRow
        let signature: StillSignature?
        switch planes.format {
        case .nv12:
            signature = StillSignature(columns: columns, rows: rows, width: width, height: height,
                                       frameWidth: planes.width, frameHeight: planes.height) { y, start, end in
                let row = base + (top + y) * stride + left
                var sum = 0
                for x in start..<end { sum += Int(row[x]) }
                return sum
            }
        case .bgra:
            signature = StillSignature(columns: columns, rows: rows, width: width, height: height,
                                       frameWidth: planes.width, frameHeight: planes.height) { y, start, end in
                let row = base + (top + y) * stride + left * 4
                var sum = 0
                for x in start..<end {
                    let pixel = row + x * 4
                    sum += (77 * Int(pixel[2]) + 150 * Int(pixel[1]) + 29 * Int(pixel[0])) >> 8
                }
                return sum
            }
        }
        guard let signature else { return nil }
        self = signature
    }
}
