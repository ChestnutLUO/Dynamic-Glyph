import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import GlyphRecognition
@testable import GlyphRecognitionImages

/// Rendered key cards, read with Vision. Serialized, like the other Vision
/// suites: many synchronous text requests at once never return on the
/// parallel runner.
@Suite("Key card reading", .serialized, .timeLimit(.minutes(2)))
struct KeyCardScreenReaderTests {
    static let frameWidth = 600
    static let frameHeight = 1200

    /// Draws an Inventory-style screen: a bright-bordered key card on the
    /// game's dark theme, "x12" in its count strip, the portal name in its
    /// name strip, and the tops of neighbouring cards below — the extra
    /// bounded regions a real inventory frame always shows.
    func frame(count: String, name: String, card: CGRect) throws -> CGImage {
        let width = Self.frameWidth, height = Self.frameHeight
        let canvas = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        canvas.setLineWidth(2)
        // Core Graphics is bottom-left origin; the strips are measured from
        // the card's top. Convert a top-left y with `height - y`.
        func cg(_ topY: CGFloat) -> CGFloat { CGFloat(height) - topY }
        canvas.stroke(CGRect(x: card.minX + 1, y: cg(card.maxY) + 1, width: card.width - 2,
                             height: card.height - 2), lineWidth: 2)
        // Neighbouring cards, cut off by the frame edge like a scrolled
        // list: one column continuing below the card, a second column
        // beside it. Their bounded interiors are the extra dark regions a
        // real inventory frame always shows.
        for offset in [70, 150, 230, 300] {
            canvas.stroke(CGRect(x: card.minX + 1, y: 0, width: card.width - 2, height: CGFloat(offset)),
                          lineWidth: 2)
        }
        for offset in [70, 150, 230] {
            canvas.stroke(CGRect(x: 21, y: 0, width: 98, height: CGFloat(offset)), lineWidth: 2)
        }
        let layout = KeyCardLayout()
        let fractions = layout.kindLayout(.inventory)
        let countStrip = CGRect(x: card.minX,
                                y: cg(card.minY + card.height * fractions.countHeight),
                                width: card.width,
                                height: card.height * fractions.countHeight)
        let nameStrip = CGRect(x: card.minX,
                               y: cg(card.minY + card.height * (fractions.nameTop + fractions.nameHeight)),
                               width: card.width,
                               height: card.height * fractions.nameHeight)
        func draw(_ text: String, in strip: CGRect, fraction: CGFloat, size: CGFloat) {
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.textMatrix = .identity
            canvas.textPosition = CGPoint(x: strip.minX + 12, y: strip.minY + strip.height * fraction)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("Helvetica" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1)])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), canvas)
        }
        draw(count, in: countStrip, fraction: 0.22, size: card.height * fractions.countHeight * 0.55)
        draw(name, in: nameStrip, fraction: 0.3, size: card.height * fractions.nameHeight * 0.66)
        return try #require(canvas.makeImage())
    }

    func makeCard() -> CGRect { CGRect(x: 150, y: 200, width: 300, height: 500) }

    @Test("A rendered card is located, counted and named")
    func readsCard() throws {
        let card = makeCard()
        let image = try frame(count: "x12", name: "Test Portal", card: card)
        let reader = KeyCardScreenReader()
        let bounds = try #require(reader.card(in: image))
        #expect(bounds.kind == .inventory)
        // The detector reads the card's dark interior, just inside the
        // drawn border.
        #expect(bounds.x >= Int(card.minX) && bounds.y >= Int(card.minY)
            && bounds.x + bounds.width <= Int(card.maxX)
            && bounds.y + bounds.height <= Int(card.maxY))
        let reading = try #require(reader.read(image, card: bounds, sourceTime: 1))
        #expect(reading.reading.count == 12)
        #expect(reading.reading.name?.localizedCaseInsensitiveContains("Portal") == true)
    }

    @Test("The same card rendered twice correlates above the same-card threshold")
    func sameCardCorrelation() throws {
        let card = makeCard()
        let first = try frame(count: "x12", name: "Test Portal", card: card)
        let second = try frame(count: "x12", name: "Test Portal", card: card)
        let reader = KeyCardScreenReader()
        let firstReading = try #require(reader.read(first, sourceTime: 1))
        let secondReading = try #require(reader.read(second, sourceTime: 1.05))
        #expect(firstReading.reading.fingerprint
            .correlation(with: secondReading.reading.fingerprint) > 0.75)
    }

    @Test("Different portal names stay below the same-card threshold")
    func differentCards() throws {
        let card = makeCard()
        let first = try frame(count: "x12", name: "Alpha Portal", card: card)
        let second = try frame(count: "x3", name: "Omega Station", card: card)
        let reader = KeyCardScreenReader()
        let firstReading = try #require(reader.read(first, sourceTime: 1))
        let secondReading = try #require(reader.read(second, sourceTime: 1.05))
        #expect(firstReading.reading.fingerprint
            .correlation(with: secondReading.reading.fingerprint) < 0.75)
    }

    @Test("A frame without a card reads none")
    func noCard() throws {
        let canvas = try #require(CGContext(data: nil, width: Self.frameWidth, height: Self.frameHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight))
        let image = try #require(canvas.makeImage())
        #expect(try KeyCardScreenReader().card(in: image) == nil)
    }
}
