import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
import VideoToolbox
import GlyphRecognition
import GlyphRecognitionImages

/// The live capture renders the drone footer's label, the command band and
/// a header read's rows on their own, from `CIImage(cvPixelBuffer:)`, when
/// no full frame has been rendered: these hold such a region to the same
/// rectangle cut from the
/// full render, byte for byte, in the pixel formats the capture delivers and
/// at the sizes broadcasts and apps send, with the regions starting on odd
/// and even rows and columns. The context is the app's
/// (`LiveGlyphOutput.context`).
@Suite("Region renders equal crops of the full render")
struct RegionRenderTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let context = CIContext(options: [.useSoftwareRenderer: false])

    static let formats: [(OSType, String)] = [
        (kCVPixelFormatType_32BGRA, "BGRA"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v")
    ]
    static let sizes: [(width: Int, height: Int)] = [(603, 1311), (602, 1310), (1206, 2622)]
    /// Buffers as VideoToolbox converts them carry only the YCbCr matrix; a
    /// capture's also name its primaries and transfer function, which Core
    /// Image then honours. Each size is rendered both ways.
    static var attachmentSets: [(name: String, attachments: [CFString: CFString])] {
        [("converted", [:]),
         ("capture", [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                      kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                      kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2])]
    }
    static var buffers: [(format: OSType, name: String, attachments: [CFString: CFString])] {
        formats.flatMap { format in attachmentSets.map { (format.0, "\(format.1) \($0.name)", $0.attachments) } }
    }
    /// The drone footer, a result panel and a gear panel: the footer's yellow
    /// label and saturated colour where 4:2:0 chroma is shared between rows.
    static let fixtures = ["Phases/field-00666.png", "Results/three-final.png", "Gear/four-bonus.png"]

    static func image(_ path: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent(path))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    /// `image` scaled to `width` by `height` in `format`, the BGRA drawing
    /// converted by VideoToolbox as a capture's would be.
    static func pixelBuffer(_ image: CGImage, width: Int, height: Int, format: OSType,
                            attachments: [CFString: CFString] = [:]) throws -> CVPixelBuffer {
        func make(_ format: OSType) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer) == kCVReturnSuccess,
                  let buffer else { throw Failure(description: "no \(format) buffer of \(width)x\(height)") }
            return buffer
        }
        let bgra = try make(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(bgra, [])
        guard context != nil else { throw Failure(description: "could not draw into a BGRA buffer") }
        func attach(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
            for (key, value) in attachments where format != kCVPixelFormatType_32BGRA
                || key != kCVImageBufferYCbCrMatrixKey {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            }
            return buffer
        }
        guard format != kCVPixelFormatType_32BGRA else { return attach(bgra) }
        let converted = try make(format)
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { throw Failure(description: "no pixel transfer session") }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: bgra, to: converted) == noErr else {
            throw Failure(description: "could not convert to \(format)")
        }
        return attach(converted)
    }

    /// As `LiveGlyphOutput.render`.
    static func renderFull(_ pixels: CVPixelBuffer) throws -> CGImage {
        let input = CIImage(cvPixelBuffer: pixels)
        return try #require(context.createCGImage(input, from: input.extent))
    }

    /// As `LiveGlyphOutput.render(_:region:)`: a top-left rectangle, in
    /// Core Image's bottom-left coordinates.
    static func renderRegion(_ pixels: CVPixelBuffer, _ region: CGRect) throws -> CGImage {
        let input = CIImage(cvPixelBuffer: pixels)
        let rect = CGRect(x: region.minX, y: input.extent.height - region.maxY, width: region.width,
                          height: region.height)
        return try #require(context.createCGImage(input, from: rect))
    }

    /// As `LiveGlyphOutput.copy(_:cropping:)`, the band cut from a full
    /// render before region renders.
    static func copy(_ image: CGImage, cropping rect: CGRect) throws -> CGImage {
        let cropped = try #require(image.cropping(to: rect.integral))
        let context = try #require(CGContext(data: nil, width: cropped.width, height: cropped.height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return try #require(context.makeImage())
    }

    static func whole(_ image: CGImage) -> CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    /// Differing bytes and the largest difference between two buffers.
    struct Difference: CustomStringConvertible {
        var compared = 0, differing = 0, largest = 0
        mutating func add(_ a: [UInt8], _ b: [UInt8]) {
            guard a.count == b.count else { differing += max(a.count, b.count); compared += max(a.count, b.count); return }
            compared += a.count
            for (x, y) in zip(a, b) where x != y { differing += 1; largest = max(largest, abs(Int(x) - Int(y))) }
        }
        var description: String { "\(differing) of \(compared) bytes differ, largest \(largest)" }
    }

    @Test("Footer label, command band and header rows: region render against the crop of the full render, every format, size, attachment set and row parity")
    func regionEqualsCrop() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        var total = Difference()
        var cases = 0
        for path in Self.fixtures {
            let source = try Self.image(path)
            for size in Self.sizes {
                for (format, formatName, attachments) in Self.buffers {
                    let pixels = try Self.pixelBuffer(source, width: size.width, height: size.height, format: format,
                                                      attachments: attachments)
                    let full = try Self.renderFull(pixels)
                    #expect(full.width == size.width && full.height == size.height)
                    let footer = DroneFooterProbe.textRect(width: size.width, height: size.height)
                    let band = CommandNoticeDetector.band(width: size.width, height: size.height)
                    let header = HeaderTextRecognizer().headerRect(width: size.width, height: size.height)
                    // The app's rectangles, then each moved by a row and by a
                    // column, so both parities of start row and column are seen
                    // at every size.
                    for (name, base) in [("footer", footer), ("band", band), ("header", header)] {
                        for (dx, dy) in [(0.0, 0.0), (0, 1), (1, 0), (1, 1), (0, -1)] {
                            let rect = base.offsetBy(dx: dx, dy: dy)
                                .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                            let context = "\(path) \(size.width)x\(size.height) \(formatName) \(name) "
                                + "x\(Int(rect.minX)) y\(Int(rect.minY))"
                            let region = try Self.renderRegion(pixels, rect)
                            #expect(region.width == Int(rect.width) && region.height == Int(rect.height), "\(context)")
                            let crop = try #require(full.cropping(to: rect))
                            var difference = Difference()
                            difference.add(try ImageDecoder.decodeColor(region, in: Self.whole(region)).pixels,
                                           try ImageDecoder.decodeColor(full, in: rect).pixels)
                            difference.add(try ImageDecoder.decode(region).pixels, try ImageDecoder.decode(crop).pixels)
                            if name == "band" {
                                // The band as the detector got it before: a copy of the crop.
                                difference.add(try ImageDecoder.decode(region).pixels,
                                               try ImageDecoder.decode(try Self.copy(full, cropping: rect)).pixels)
                            }
                            #expect(difference.differing == 0, "\(context): \(difference)")
                            total.compared += difference.compared; total.differing += difference.differing
                            total.largest = max(total.largest, difference.largest)
                            cases += 1
                        }
                    }
                    // The footer probe's two entry points and read crops.
                    let region = try Self.renderRegion(pixels, footer)
                    let fromRegion = try DroneFooterProbe.textPixels(region: region, frameWidth: size.width,
                                                                     frameHeight: size.height)
                    let fromFull = try DroneFooterProbe.textPixels(in: full)
                    #expect(fromRegion.width == fromFull.width && fromRegion.pixels == fromFull.pixels)
                    #expect(DroneFooterProbe.candidate(fromRegion) == DroneFooterProbe.candidate(fromFull))
                    let readRegion = try #require(DroneFooterProbe.readCrop(region: region))
                    let readFull = try #require(DroneFooterProbe.readCrop(full))
                    var read = Difference()
                    read.add(try ImageDecoder.decodeColor(readRegion, in: Self.whole(readRegion)).pixels,
                             try ImageDecoder.decodeColor(readFull, in: Self.whole(readFull)).pixels)
                    #expect(readRegion.width == readFull.width && readRegion.height == readFull.height
                            && read.differing == 0,
                            "\(path) \(size.width)x\(size.height) \(formatName) read crop: \(read)")
                    total.compared += read.compared; total.differing += read.differing
                    total.largest = max(total.largest, read.largest)
                }
            }
        }
        #expect(cases == Self.fixtures.count * Self.sizes.count * Self.buffers.count * 15)
        print("RegionRenderTests: \(cases) region cases; \(total)")
    }

    @Test("The header rows rendered alone read as the whole frame does: command, presentation and input headers, every format and attachment set",
          arguments: [("Phases/field-00381.png", GamePhase.command), ("Phases/field-00443.png", .presenting),
                      ("Phases/field-00492.png", .input)])
    func headerRegionReadsTheSameHeader(path: String, phase: GamePhase) async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let recognizer = HeaderTextRecognizer()
        let source = try Self.image(path)
        for (format, name, attachments) in Self.buffers {
            let pixels = try Self.pixelBuffer(source, width: source.width, height: source.height, format: format,
                                              attachments: attachments)
            let full = try Self.renderFull(pixels)
            let region = try Self.renderRegion(pixels, recognizer.headerRect(width: full.width, height: full.height))
            let whole = try await recognizer.read(full, sourceTime: 1)
            let alone = try await recognizer.read(headerRegion: region, sourceTime: 1)
            #expect(whole.phase == phase, "\(path) \(name): \(whole)")
            #expect(alone == whole, "\(path) \(name): \(alone) against \(whole)")
        }
    }

    @Test("A footer region of the wrong size is refused, not misread")
    func wrongSizeRegion() throws {
        let source = try Self.image("Phases/field-00666.png")
        let pixels = try Self.pixelBuffer(source, width: 603, height: 1311, format: kCVPixelFormatType_32BGRA)
        let footer = DroneFooterProbe.textRect(width: 603, height: 1311)
        let region = try Self.renderRegion(pixels, footer.insetBy(dx: 1, dy: 0))
        #expect(throws: ImageDecoder.DecodeError.self) {
            try DroneFooterProbe.textPixels(region: region, frameWidth: 603, frameHeight: 1311)
        }
        let capture = CommandNoticeCapture()
        #expect(throws: ImageDecoder.DecodeError.self) {
            try capture.observeMode(footer: region, frameWidth: 603, frameHeight: 1311, at: 1)
        }
        #expect(capture.modeCandidates == 0 && capture.modeProbeDue(at: 1))
    }
}
