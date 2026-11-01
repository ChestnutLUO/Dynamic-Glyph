import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// Reads the portal screen's resonator levels and level badge. Only the two
/// label columns go to OCR; the portal's name and address above them never do.
public struct PortalScreenReader: Sendable {
    public init() {}

    /// Decodes only the detector's band: this runs on every frame.
    public func isCandidate(_ image: CGImage) throws -> Bool {
        try faction(image) != nil
    }

    /// The faction of a portal screen's resonator bars, or nil on any other
    /// screen.
    public func faction(_ image: CGImage) throws -> PortalFaction? {
        let band = PortalScreenDetector.band(frameHeight: image.height)
        let pixels = try ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: band.lowerBound,
                                                                     width: image.width, height: band.count))
        return PortalScreenDetector().faction(pixels, frameHeight: image.height, bandTop: band.lowerBound)
    }

    public func read(_ image: CGImage, sourceTime: Double) throws -> PortalScreenEvidence {
        let width = Double(image.width), height = Double(image.height)
        var lines: [ResultTextLine] = []
        var yellowLabels: Set<Int> = []
        // The labels sit beside the bars, the agent names under them.
        for (x0, x1) in [(0.0, 0.34), (0.66, 1.0)] {
            let rect = CGRect(x: x0 * width, y: 0.28 * height, width: (x1 - x0) * width, height: 0.42 * height).integral
            guard let crop = image.cropping(to: rect) else { continue }
            // The labels are small at 562 px; enlarge the pixels, not the
            // coordinates, as the gear reader does.
            guard let canvas = CGContext(data: nil, width: crop.width * 2, height: crop.height * 2,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageDecoder.DecodeError.cannotCreateContext }
            canvas.interpolationQuality = .high
            canvas.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2))
            guard let enlarged = canvas.makeImage() else { throw ImageDecoder.DecodeError.cannotCreateContext }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try TextReadProbe.measure(.portalScreen) {
                try VNImageRequestHandler(cgImage: enlarged).perform([request])
            }
            for observation in request.results ?? [] {
                guard let best = observation.topCandidates(1).first else { continue }
                if PortalScreenParser.isLevelOneYellow(hues: try labelHues(best, in: rect, of: image)) {
                    yellowLabels.insert(lines.count)
                }
                let box = observation.boundingBox
                lines.append(ResultTextLine(text: best.string, confidence: Double(best.confidence),
                    x: (rect.minX + box.minX * rect.width) / width,
                    y: (rect.minY + (1 - box.maxY) * rect.height) / height,
                    width: box.width * rect.width / width, height: box.height * rect.height / height))
            }
        }
        return PortalScreenParser().read(lines: lines, badgeHue: try badgeHue(in: image), at: sourceTime,
                                         faction: try faction(image), yellowLabels: yellowLabels)
    }

    /// Hues of the strongly coloured pixels in the character that stands for
    /// a label's L: an L-like letter, or a two-digit word's 1, before the
    /// digit. Empty when the line has no such character.
    func labelHues(_ text: VNRecognizedText, in rect: CGRect, of image: CGImage) throws -> [Double] {
        let characters = Array(text.string)
        guard let index = characters.indices.first(where: { index in
            index + 1 < characters.count && "LlI|1".contains(characters[index]) && characters[index + 1].isNumber
        }) else { return [] }
        let start = text.string.index(text.string.startIndex, offsetBy: index)
        guard let box = try text.boundingBox(for: start..<text.string.index(after: start))?.boundingBox else { return [] }
        let character = CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + (1 - box.maxY) * rect.height,
                               width: box.width * rect.width, height: box.height * rect.height).integral
        guard character.width >= 1, character.height >= 1 else { return [] }
        let pixels = try ImageDecoder.decodeColor(image, in: character)
        var hues: [Double] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels[x, y]
                let r = Double(p.red) / 255, g = Double(p.green) / 255, b = Double(p.blue) / 255
                let high = max(r, g, b), spread = high - min(r, g, b)
                guard high > 0.45, spread / high > 0.45 else { continue }
                var hue: Double
                if high == r { hue = 60 * ((g - b) / spread).truncatingRemainder(dividingBy: 6) }
                else if high == g { hue = 60 * ((b - r) / spread + 2) }
                else { hue = 60 * ((r - g) / spread + 4) }
                if hue < 0 { hue += 360 }
                hues.append(hue)
            }
        }
        return hues
    }

    /// The badge's mean hue, from its saturated pixels. Nil while it is still
    /// fading in: fewer than 100 such pixels at 562 px wide.
    public func badgeHue(in image: CGImage) throws -> Double? {
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: 0.02 * width, y: 0.095 * height, width: 0.12 * width, height: 0.055 * height).integral
        let pixels = try ImageDecoder.decodeColor(image, in: rect)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels[x, y]
                let r = Double(p.red) / 255, g = Double(p.green) / 255, b = Double(p.blue) / 255
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 0.45, high > 0, (high - low) / high > 0.5 else { continue }
                red += r; green += g; blue += b; count += 1
            }
        }
        let scale = width / 562
        guard Double(count) >= 100 * scale * scale else { return nil }
        return Self.hue(red: red / Double(count), green: green / Double(count), blue: blue / Double(count))
    }

    static func hue(red r: Double, green g: Double, blue b: Double) -> Double? {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return nil }
        var hue: Double
        if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }
}
