import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// One OCR request for both bonus fields and the short-lived stage name. The
/// lower hexagon contours are sampled separately, including under the PiP.
public struct ResultScreenReader: Sendable {
    public let language: GameLanguage
    public init(language: GameLanguage = .english) { self.language = language }

    public func read(_ image: CGImage, context: ResultReadContext, sourceTime: Double) throws -> ResultFrameEvidence {
        let aspect = Double(image.height) / Double(image.width)
        guard (2.1...2.25).contains(aspect) else {
            return ResultFrameEvidence(context: context, sourceTime: sourceTime, panelPresent: false)
        }
        let rect = CGRect(x: 0.06 * Double(image.width), y: 0.18 * Double(image.height),
                          width: 0.88 * Double(image.width), height: 0.44 * Double(image.height)).integral
        guard var lines = try recognize(image, in: rect, scale: 1) else {
            return ResultFrameEvidence(context: context, sourceTime: sourceTime, panelPresent: false)
        }
        let parser = ResultTextParser(language: language)
        let appearances = try appearances(in: image, count: context.glyphs.count)
        let evidence = parser.read(lines: lines, context: context, at: sourceTime, appearances: appearances)
        // A value with a look-alike in it gets a second look, enlarged:
        // Vision read a one-Glyph result's 38% as "З8%", a Cyrillic Ze, on
        // every frame of the 2026-10-05 field test, and 38% at 1.5 times the
        // size. Only the panel's lines are taken from it. The name above is
        // kept from capture size, where it reads best: enlarged, short names
        // such as XM were lost. The same crop is enlarged, since Vision read
        // a crop of the panel alone differently again.
        guard evidence.panelPresent, Self.hasLookAlike(lines, evidence: evidence) else { return evidence }
        let panelTop = 0.30
        guard let second = try recognize(image, in: rect, scale: 1.5) else { return evidence }
        lines = lines.filter { $0.y + $0.height / 2 < panelTop } + second.filter { $0.y + $0.height / 2 >= panelTop }
        return parser.read(lines: lines, context: context, at: sourceTime, appearances: appearances)
    }

    /// A value line that ends in a percent sign but holds something other
    /// than ASCII digits, where the parser read no value.
    static func hasLookAlike(_ lines: [ResultTextLine], evidence: ResultFrameEvidence) -> Bool {
        func misread(_ band: ClosedRange<Double>) -> Bool {
            lines.contains { line in
                let text = line.text.filter { !$0.isWhitespace }
                guard band.contains(line.y + line.height / 2), text.last == "%" || text.last == "％" else { return false }
                return !text.dropLast().allSatisfy { $0.isASCII && $0.isNumber }
            }
        }
        return (evidence.hackingBonus == nil && misread(ResultTextParser.hackingValueBand))
            || (evidence.speedBonus == nil && misread(ResultTextParser.speedValueBand))
    }

    /// Text in `rect`, its pixels enlarged by `scale`, in frame fractions.
    private func recognize(_ image: CGImage, in rect: CGRect, scale: Double) throws -> [ResultTextLine]? {
        guard var crop = image.cropping(to: rect) else { return nil }
        if scale != 1 {
            let width = Int(Double(crop.width) * scale), height = Int(Double(crop.height) * scale)
            guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ImageDecoder.DecodeError.cannotCreateContext
            }
            canvas.interpolationQuality = .high
            canvas.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let enlarged = canvas.makeImage() else { throw ImageDecoder.DecodeError.cannotCreateContext }
            crop = enlarged
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = language.recognitionLanguages
        try TextReadProbe.measure(.resultPanel) { try VNImageRequestHandler(cgImage: crop).perform([request]) }
        return (request.results ?? []).compactMap { observation -> ResultTextLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ResultTextLine(text: best.string, confidence: Double(best.confidence),
                x: (rect.minX + box.minX * rect.width) / Double(image.width),
                y: (rect.minY + (1 - box.maxY) * rect.height) / Double(image.height),
                width: box.width * rect.width / Double(image.width),
                height: box.height * rect.height / Double(image.height))
        }
    }

    /// Where the game centres each hexagon, as fractions of the frame width.
    /// Five fill the width and four nearly do, but three keep a wider fixed
    /// spacing, so their outer hexagons sit well inside even cells. Measured on
    /// 603-pixel-wide captures. One Glyph's sits at the centre, as any spacing
    /// puts it; two Glyphs are unrecorded and assumed to keep three's spacing.
    static func slotCenters(count: Int) -> [Double] {
        let spacing = count >= 5 ? 0.2 : count == 4 ? 0.246 : 0.292
        return (0..<count).map { 0.5 + (Double($0) - Double(count - 1) / 2) * spacing }
    }

    public func appearances(in image: CGImage, count: Int) throws -> [ResultSlotAppearance] {
        guard (1...5).contains(count) else { return [] }
        let cropRect = CGRect(x: 0, y: Double(image.height) * 0.11,
                              width: Double(image.width), height: Double(image.height) * 0.06).integral
        let pixels = try ImageDecoder.decodeColor(image, in: cropRect)
        let centers = Self.slotCenters(count: count).map { $0 * Double(image.width) }
        // The hexagons are the same size whatever their count.
        let halfWidth = 0.088 * Double(image.width)
        func support(index: Int, magenta: Bool) -> Int {
            var hits = 0
            for side in [-1.0, 1.0] {
                for step in 0..<16 {
                    let t = Double(step) / 15
                    let x = centers[index] + side * halfWidth * (1 - t)
                    let y = Double(image.height) * (0.127 + 0.027 * t) - cropRect.minY
                    let radius = max(2, image.width / 140)
                    var found = false
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            let px = Int(x) + dx, py = Int(y) + dy
                            guard px >= 0, py >= 0, px < pixels.width, py < pixels.height else { continue }
                            let p = pixels[px, py]
                            let r = Double(p.red), g = Double(p.green), b = Double(p.blue)
                            if magenta ? (r > 90 && b > 70 && g < min(r, b) * 0.65)
                                : (r > 90 && g > 90 && b < min(r, g) * 0.7) { found = true }
                        }
                    }
                    if found { hits += 1 }
                }
            }
            return hits
        }
        return (0..<count).map { index in
            let gold = support(index: index, magenta: false)
            let magenta = support(index: index, magenta: true)
            if gold >= 24 && magenta <= 4 { return .gold }
            if magenta >= 24 && gold <= 4 { return .magenta }
            return .unreadable
        }
    }
}

extension ResultScreenReader {
    /// Reads in the capture's language. When the result page's labels aren't
    /// found, the other languages are tried on this frame; the first whose
    /// labels match becomes the language. Called only once the page's shape
    /// was seen, so an unread frame means the wrong script, not no page.
    public static func read(_ image: CGImage, context: ResultReadContext, sourceTime: Double,
                            languages memory: GameLanguageMemory) throws -> ResultFrameEvidence {
        let current = memory.current
        let evidence = try ResultScreenReader(language: current).read(image, context: context, sourceTime: sourceTime)
        guard !evidence.panelPresent else {
            // Japanese games print these labels in English too, so they
            // confirm only a language of their own.
            if current != .english, evidence.labelLanguage == current { memory.found(current) }
            return evidence
        }
        for language in memory.alternatives(at: sourceTime, on: .result) {
            let other = try ResultScreenReader(language: language).read(image, context: context, sourceTime: sourceTime)
            // Only its own label names it: SPEED BONUS stays English in Japanese.
            if other.panelPresent, other.labelLanguage == language { memory.found(language); return other }
        }
        return evidence
    }
}
