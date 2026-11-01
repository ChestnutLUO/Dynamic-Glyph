import Foundation
import CoreGraphics
import ImageIO
import GlyphRecognition

/// Crops of the drop panel for gear-reading reports, never a frame queue. The
/// title strip is blacked out before encoding: a portal panel's title is the
/// portal's name, which the app shows and a report carries by default.
///
/// Beside each crop goes the whole frame it came from, unmasked, for a report
/// whose player chooses to send it: it shows a crop that missed a row, and
/// also the map and the portal's name. The app never shows it.
final class GearEvidenceWriter: @unchecked Sendable {
    // GearEvidenceSchedule reserves a separate budget and cadence per panel.
    /// The parser's title band, as a fraction of the frame height.
    static let titleBand = 0.045

    private let directory: URL
    private let queue = DispatchQueue(label: "dynamicglyph.gear-evidence", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let capacity = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()

    init(directory: URL) {
        self.directory = directory
    }

    /// The file name when queued, and a status for the log either way.
    func enqueue(_ image: CGImage, bounds: GearDropPanelBounds, sourceTime: Double) -> (file: String?, status: String) {
        guard capacity.wait(timeout: .now()) == .success else { return (nil, "writerBusy") }
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: width * 0.035, y: bounds.top * height, width: width * 0.93,
                          height: (bounds.bottom - bounds.top) * height).integral
        guard let crop = image.cropping(to: rect) else { capacity.signal(); return (nil, "cropFailed") }
        let name = String(format: "gear-%.6f.jpg", sourceTime)
        let url = directory.appendingPathComponent(name)
        let fullURL = directory.appendingPathComponent(HackGearPicture.fullFrameName(name))
        let titleHeight = min(Double(crop.height), Self.titleBand * height)
        group.enter()
        queue.async { [capacity, group] in
            defer { capacity.signal(); group.leave() }
            guard let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            // Core Graphics puts the origin at the bottom: the title is the top rows.
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: Double(crop.height) - titleHeight, width: Double(crop.width), height: titleHeight))
            guard let masked = context.makeImage() else { return }
            Self.writeJPEG(masked, to: url, quality: 0.8)
            // A lower quality: it is context for the crop, not what was read.
            Self.writeJPEG(image, to: fullURL, quality: 0.6)
        }
        return (name, "queued")
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            NSLog("[DynamicGlyph] Gear evidence image failed: %@", url.lastPathComponent)
        }
    }

    /// Blocks until queued pictures are on disk, so a shared report has them.
    func finish() {
        group.wait()
    }
}
