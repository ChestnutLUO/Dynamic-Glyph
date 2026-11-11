import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// Reads key cards from a captured frame: which card is on it, the key
/// quantity off its count strip, the portal name off its name strip, and the
/// name strip's fingerprint for the counter's same-card decision.
///
/// The OCR passes follow the gear reader's conventions: crops are enlarged
/// twofold before recognition (the strips' text is small), recognition is
/// accurate with no language correction, and all evidence stays in the
/// source frame's pixel space. Portal names are read in the caller's
/// languages — a game in English still shows Chinese and Japanese portal
/// names, so a reader of those games passes its CJK families here, as the
/// gear reader's title recovery does.
public struct KeyCardScreenReader: Sendable {
    public let layout: KeyCardLayout

    public init(layout: KeyCardLayout = KeyCardLayout()) { self.layout = layout }

    /// Detects the key card on a full frame, if one shows.
    public func card(in image: CGImage) throws -> KeyCardBounds? {
        KeyCardDetector().detect(in: try ImageDecoder.decode(image))
    }

    /// What one card read, beyond what `PortalKeyCounter` consumes.
    public struct Reading: Sendable {
        public let reading: KeyCardFrameReading
        /// The count strip's OCR text, for diagnostics. Empty when nothing
        /// was recognized.
        public let countText: String
        /// The name strip's OCR text before cleaning.
        public let nameText: String
    }

    /// Reads one card already located. The count falls back to 1 on an
    /// Inventory card with no readable marker — the game shows no quantity
    /// for a single key — and reads nil elsewhere.
    public func read(_ image: CGImage, card: KeyCardBounds, sourceTime: Double,
                     nameLanguages: [String] = ["en-US"]) throws -> Reading {
        let countRegion = card.countRegion(layout: layout)
        let countText = try ocr(image, rect: countRegion, languages: ["en-US"])
        let count = KeyCountParsing.count(in: countText, kind: card.kind)
        let nameRegion = card.nameRegion(layout: layout)
        let nameText = try ocr(image, rect: nameRegion, languages: nameLanguages)
        let name = KeyNameCleaning.cleaned(nameText)
        let fingerprint = try fingerprint(image, rect: nameRegion)
        let reading = KeyCardFrameReading(sourceTime: sourceTime, card: card, fingerprint: fingerprint,
                                          count: count, name: name.isEmpty ? nil : name)
        return Reading(reading: reading, countText: countText, nameText: nameText)
    }

    /// Convenience: detects the card and reads it in one call.
    public func read(_ image: CGImage, sourceTime: Double,
                     nameLanguages: [String] = ["en-US"]) throws -> Reading? {
        guard let card = try card(in: image) else { return nil }
        return try read(image, card: card, sourceTime: sourceTime, nameLanguages: nameLanguages)
    }

    /// The name strip's fingerprint, from its own pixels only.
    private func fingerprint(_ image: CGImage, rect: PixelRect) throws -> NameRegionFingerprint {
        let bounds = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard let crop = image.cropping(to: bounds) else {
            // An empty strip fingerprint correlates with nothing, which is
            // the safe answer for a card whose name strip could not be cut.
            return NameRegionFingerprint(image: try LuminanceImage(width: 2, height: 2,
                                                                   pixels: [255, 255, 255, 255]),
                                         size: 2)
        }
        return NameRegionFingerprint(image: try ImageDecoder.decode(crop))
    }

    private func ocr(_ image: CGImage, rect: PixelRect, languages: [String]) throws -> String {
        let bounds = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard let crop = image.cropping(to: bounds) else { return "" }
        // The captured strip text is small. Scale pixels, not the OCR
        // coordinates: nothing here escapes as geometry.
        guard let canvas = CGContext(data: nil, width: crop.width * 2, height: crop.height * 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        canvas.interpolationQuality = .high
        canvas.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2))
        guard let enlarged = canvas.makeImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = false
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }
}
