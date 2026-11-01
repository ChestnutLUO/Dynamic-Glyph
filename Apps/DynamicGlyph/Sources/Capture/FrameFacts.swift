import Foundation
import CoreMedia
import CoreVideo

/// Per-frame facts: what the capture source said, plus what the buffer shows.
///
/// `status` matters as much as the frame count: a source reports `.idle` when
/// nothing changed and `.blank` when the display went blank, so a steady
/// stream of `.idle` frames is a very different result from a steady stream of
/// `.complete` ones and must not be counted as success.
struct FrameFacts: Sendable, Equatable {
    var status: CaptureFrameStatus = .unknown
    var displayTime: UInt64?
    var scaleFactor: Double?
    var contentScale: Double?
    var contentRect: CGRect?
    var screenRect: CGRect?
    var orientation: UInt32?
    var width = 0
    var height = 0
    var pixelFormat = "-"
    var hash: UInt64 = 0

    /// `hashing` is for diagnostics only; recognition never reads the hash.
    init(metadata: CaptureFrameMetadata, sampleBuffer: CMSampleBuffer, hashing: Bool) {
        status = metadata.status
        displayTime = metadata.displayTime
        scaleFactor = metadata.scaleFactor
        contentScale = metadata.contentScale
        contentRect = metadata.contentRect
        screenRect = metadata.screenRect
        orientation = metadata.orientation
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            width = CVPixelBufferGetWidth(pixels)
            height = CVPixelBufferGetHeight(pixels)
            pixelFormat = FrameProbe.fourCC(CVPixelBufferGetPixelFormatType(pixels))
            if hashing { hash = FrameProbe.differenceHash(pixels) }
        }
    }

    /// Before any frame has arrived.
    init() {}
}

enum FrameProbe {

    static func fourCC(_ value: OSType) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii) ?? "?"
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 64-bit difference hash of a coarse luma grid.
    ///
    /// The question it answers is "is this live content or the same frame over
    /// and over", which a frame counter cannot distinguish. Reads plane 0,
    /// which is luma for the biplanar YUV formats iOS delivers and the blue
    /// channel for BGRA -- either is fine for change detection.
    static func differenceHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar
                ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                : CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                           : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                            : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                              : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = planar ? 1 : 4
        guard width > 9, height > 8 else { return 0 }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<8 {
            let y = height * row / 8
            let line = bytes + y * rowBytes
            for col in 0..<8 {
                let x1 = width * col / 9
                let x2 = width * (col + 1) / 9
                if line[x1 * stride] > line[x2 * stride] { hash |= (1 << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }
}
