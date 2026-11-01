import Foundation
import CoreGraphics
import CoreText
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// Serialized: many synchronous Vision text requests at once never return on
/// the parallel test runner. The time limit turns any such hang into a failure.
@Suite("Recorded gear panels", .serialized, .timeLimit(.minutes(2)))
struct GearDropScreenReaderTests {
    func image(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Gear/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    @Test("Sanitized recorded panels retain their item quantities and explicit levels",
           arguments: [("four-base", 3, 2, GearDropStage.portal), ("four-bonus", 13, 5, .bonus),
                       ("five-base", 2, 2, .portal), ("five-bonus", 3, 3, .bonus),
                       ("multiplied-base", 2, 1, .portal), ("multiplied-bonus", 24, 5, .bonus)])
    func panels(_ sample: (String, Int, Int, GearDropStage)) throws {
        let reader = GearDropScreenReader()
        let frame = try image(sample.0)
        let candidate = try reader.bounds(in: frame)
        let bounds = try #require(candidate)
        let result = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(result.stage == sample.3)
        #expect(result.entries.count == sample.2)
        #expect(result.entries.reduce(0) { $0 + $1.quantity } == sample.1)
        #expect(result.entries.allSatisfy { $0.item != nil && $0.levelState != .unreadable },
                "Read: \(result.entries.map { "\($0.position) L\($0.level ?? -1) \($0.item ?? "?") x\($0.quantity)" })")
        #expect(result.unreadableRows == 0)
        if sample.0 == "five-base" {
            #expect(result.entries.first(where: { $0.item == "Turret" })?.rarity == .rare)
        }
        #expect(result.entries.filter { $0.levelState == .known }.allSatisfy { $0.rarity == nil })
        // Every quantity in the multiplied panels is red; every other is white.
        let multiplied = sample.0.hasPrefix("multiplied")
        #expect(result.entries.allSatisfy { $0.multiplied == multiplied },
                "Colours: \(result.entries.map { "\($0.item ?? "?") x\($0.quantity) \(String(describing: $0.multiplied))" })")
    }

    @Test("The quantity marker is found only on a line with exactly one", arguments: [
        ("L8 x10 XMP Burster", "x10"), ("8 X2 Resonator", "X2"), ("×3 Portal Shield", "×3"),
        ("Resonator", nil), ("x2 x3", nil), ("Box Xmp", nil), ("L8 x", nil)])
    func quantityMarker(_ sample: (String, String?)) {
        let range = GearDropScreenReader.quantityRange(in: sample.0)
        #expect(range.map { String(sample.0[$0]) } == sample.1)
    }

    @Test("CJK portal titles preserve English item names, quantities and levels",
          arguments: ["測試用傳送門", "测试传送门", "試験用ポータル", "테스트 포털"])
    func mixedLanguagePanel(_ title: String) throws {
        let reader = GearDropScreenReader()
        let original = try image("four-base")
        let bounds = try #require(try reader.bounds(in: original))
        let expected = try reader.read(original, bounds: bounds, sourceTime: 1)
        let frame = try replacingTitle(in: original, with: title)
        let result = try reader.read(frame, bounds: bounds, sourceTime: 2)
        #expect(result.stage == .portal)
        #expect(result.entries == expected.entries)
        #expect(result.unreadableRows == 0)
    }

    @Test("A recovered title's language is reused for the panel's next reads, then forgotten")
    func titleMemory() throws {
        let reader = GearDropScreenReader(), memory = GearTitleLanguageMemory()
        let original = try image("four-base")
        let bounds = try #require(try reader.bounds(in: original))
        let expected = try reader.read(original, bounds: bounds, sourceTime: 1)
        let japanese = try replacingTitle(in: original, with: "試験用ポータル")
        let first = try reader.read(japanese, bounds: bounds, sourceTime: 2, titleMemory: memory)
        #expect(first.stage == .portal && first.entries == expected.entries)
        // Which family reads it is Vision's choice; kanji may read as Chinese.
        let family = try #require(memory.preferredFamily)
        // The next read of the same panel tries that family first, and still reads it.
        let second = try reader.read(japanese, bounds: bounds, sourceTime: 2.25, titleMemory: memory)
        #expect(second.stage == .portal && second.entries == expected.entries)
        #expect(memory.preferredFamily == family)
        // A title read without help belongs to another panel: forget the family.
        _ = try reader.read(original, bounds: bounds, sourceTime: 2.5, titleMemory: memory)
        #expect(memory.preferredFamily == nil)
    }

    @Test("A short panel in another CJK script retains both confirming reads",
          arguments: [("測試用傳送門", "테스트 포털"), ("試験用ポータル", "테스트 포털"),
                      ("테스트 포털", "測試用傳送門"), ("테스트 포털", "試験用ポータル")])
    func titleLanguageTransition(_ titles: (String, String)) throws {
        let reader = GearDropScreenReader(), memory = GearTitleLanguageMemory()
        let original = try image("four-base")
        let bounds = try #require(try reader.bounds(in: original))
        let expected = try reader.read(original, bounds: bounds, sourceTime: 0)
        let previous = try replacingTitle(in: original, with: titles.0)
        let warmed = try reader.read(previous, bounds: bounds, sourceTime: 1, titleMemory: memory)
        #expect(warmed.stage == .portal)
        _ = try #require(memory.preferredFamily)

        let next = try replacingTitle(in: original, with: titles.1)
        var tracker = GearDropTracker()
        // Only two reads fit before this panel is tapped away. Losing the
        // first read to a stale language preference leaves no confirmed items.
        for time in [1.25, 1.5] {
            let evidence = try reader.read(next, bounds: bounds, sourceTime: time, titleMemory: memory)
            #expect(evidence.stage == .portal)
            #expect(evidence.entries == expected.entries)
            _ = tracker.accept(evidence)
        }
        let finished = tracker.finish(at: 1.65, reason: "panelLeft")
        let summary = try #require(finished)
        #expect(summary.recognizedQuantity == 3)
        #expect(summary.panels.count == 1)
        #expect(summary.panels.first?.partial == false)
    }

    @Test("Title language preference preserves every fallback and expires across time discontinuities")
    func titleLanguagePreferenceLifetime() {
        let memory = GearTitleLanguageMemory()
        let all = GearDropScreenReader.titleFamilies
        let korean = all[2]
        #expect(memory.families(at: 10, all: all) == all)
        memory.remember(korean, at: 10)
        #expect(memory.families(at: 10.25, all: all) == [korean, all[0], all[1]])
        #expect(memory.families(at: 15, all: all) == [korean, all[0], all[1]])
        #expect(memory.families(at: 15.01, all: all) == all)
        #expect(memory.families(at: 9, all: all) == all)
        memory.remember(nil, at: 10.5)
        #expect(memory.families(at: 10.75, all: all) == all)
    }

    @Test("Title recovery never turns missing, reward or unsupported titles into portal drops",
          arguments: [("", GearDropStage.unknown), ("獎勵物品:", .unsupported),
                      ("奖励物品:", .unsupported), ("Bounty Claimed", .excluded)])
    func titleRejections(_ sample: (String, GearDropStage)) throws {
        let reader = GearDropScreenReader()
        let frame = try replacingTitle(in: image("four-base"), with: sample.0)
        let bounds = try #require(try reader.bounds(in: frame))
        let result = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(result.stage == sample.1 || (sample.1 == .unsupported && result.stage == .unknown))
        #expect(result.entries.isEmpty)
    }

    @Test("An item with one rarity keeps it when its meter cannot be read",
          arguments: [("Aegis Shield", GearDropEntry.Rarity.veryRare), ("Hypercube", .veryRare),
                      ("ADA Refactor", .veryRare), ("JARVIS Virus", .veryRare), ("Force Amp", .rare)])
    func fixedRarityWithoutMeter(_ sample: (String, GearDropEntry.Rarity)) throws {
        let (item, rarity) = sample
        let original = try image("four-base")
        let context = try #require(CGContext(data: nil, width: original.width, height: original.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        context.translateBy(x: 0, y: CGFloat(original.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1))
        // Owned item text replaces both recorded entries; there are no bars.
        context.fill(CGRect(x: 26, y: 447, width: 510, height: 53))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 110, y: 482)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "x1 \(item)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, 20, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]))
        CTLineDraw(line, context)
        let frame = try #require(context.makeImage())
        let reader = GearDropScreenReader()
        let bounds = try #require(try reader.bounds(in: frame))
        let result = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.item == item)
        #expect(result.entries.first?.rarity == rarity)
        #expect(result.unreadableRows == 0)
    }

    /// Replace only the title of an already sanitized fixture with owned text.
    /// Pixel coordinates follow that fixture, independently of the OCR crop.
    private func replacingTitle(in image: CGImage, with title: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 20, y: 399, width: 522, height: 44))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("PingFangTC-Regular" as CFString, 18, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.75, green: 0.70, blue: 0.95, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: (562 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 433)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    @Test("Decoding only the detector's band finds the same box as the whole frame",
          arguments: ["four-base", "four-bonus", "five-base", "five-bonus", "multiplied-base", "multiplied-bonus"])
    func bandMatchesFrame(_ name: String) throws {
        let frame = try image(name)
        let whole = try ImageDecoder.decodeColor(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let expected = GearDropPanelDetector().candidate(in: whole)
        #expect(expected != nil)
        #expect(try GearDropScreenReader().bounds(in: frame) == expected)
    }

    @Test("An isolated red quantity is read from its pixels rather than a panel OCR substitution")
    func isolatedRedQuantity() throws {
        let frame = try image("red-resonator-quantity")
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let original = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known,
                                     level: 6, quantity: 7, multiplied: true)
        let result = try reader.readItemRow(frame, bounds: .init(top: 0.28626, bottom: 0.38321),
                                             position: 0, original: original)
        #expect(result?.quantity == 1 && result?.item == "Resonator" && result?.level == 6)
    }

    @Test("A red shield quantity retry cannot replace one with eleven")
    func isolatedShieldQuantity() throws {
        let frame = try image("red-shield-quantity")
        let original = GearDropEntry(column: 0, row: 0, item: "Portal Shield",
            levelState: .notApplicable, level: nil, quantity: 1, multiplied: true)
        let result = try GearDropScreenReader(language: .simplifiedChinese).readItemRow(
            frame, bounds: .init(top: 0.2862595419847328, bottom: 0.4549618320610687),
            position: 0, original: original)
        #expect(result?.quantity == 1 && result?.item == "Portal Shield")
    }

    @Test("A missing Chinese row can be recovered with its own level and quantity")
    func isolatedMissingRow() throws {
        let frame = try image("red-resonator-row")
        let result = try GearDropScreenReader(language: .simplifiedChinese).readItemRow(
            frame, bounds: .init(top: 0.28626, bottom: 0.38321), position: 1, original: nil)
        #expect(result?.quantity == 1 && result?.item == "Resonator" && result?.level == 6)
    }

    @Test("A completely omitted column is retried when its physical row is observed")
    func omittedColumn() {
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let bounds = GearDropPanelBounds(top: 0.28626, bottom: 0.38321)
        let left = ResultTextLine(text: "x2 能量塔护盾", confidence: 1,
            x: 0.20, y: bounds.top + 0.058, width: 0.24, height: 0.018)
        #expect(reader.rowPositions(in: [left], bounds: bounds) == [0, 1])
        #expect(reader.rowPositions(in: [], bounds: bounds).isEmpty)
    }

    @Test("A quantity crop cannot invent a missing level or borrow another item's level")
    func isolatedRowPreservesIdentity() throws {
        let frame = try image("red-resonator-quantity")
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let bounds = GearDropPanelBounds(top: 0.28626, bottom: 0.38321)
        let unread = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .unreadable,
                                  level: nil, quantity: 7)
        let recovered = try reader.readItemRow(frame, bounds: bounds, position: 0, original: unread)
        #expect(recovered?.quantity == 1 && recovered?.levelState == .unreadable && recovered?.level == nil)
        let other = GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known,
                                 level: 6, quantity: 7)
        #expect(try reader.readItemRow(frame, bounds: bounds, position: 0, original: other) == nil)
    }

    @Test("An English portal heading does not discard Chinese item rows")
    func latinTitleChineseItems() throws {
        let frame = try image("latin-title-chinese")
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let bounds = try #require(try reader.bounds(in: frame))
        let evidence = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(evidence.stage == .portal)
        #expect(evidence.entries.map(\.item) == ["XMP Burster", "Resonator"])
        #expect(evidence.entries.map(\.level) == [6, 6])
        #expect(evidence.entries.map(\.quantity) == [1, 1])
    }

    @Test("A Latin heading read at 0.3 by CJK OCR gets an independent English title read")
    func lowConfidenceLatinHeading() throws {
        let bounds = GearDropPanelBounds(top: 0.286, bottom: 0.383)
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let recovered = try reader.recoverTitle(bounds: bounds, sourceTime: 1, memory: nil) { languages in
            // The recorded heading scored 0.3 in CJK-first passes and 1.0
            // with English first. Substitute owned text for the portal name.
            [ResultTextLine(text: "Reference Building II", confidence: languages.first == "en-US" ? 1 : 0.3,
                            x: 0.29, y: 0.306, width: 0.42, height: 0.024)]
        }
        #expect(recovered.count == 1 && recovered.first?.confidence == 1)
    }

    @Test("Item sparks covering either horizontal border do not split a visible Bonus panel",
          arguments: ["spark-border-top", "spark-border-bottom"])
    func sparkBorders(_ name: String) throws {
        let frame = try image(name)
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame))
        #expect(abs(bounds.top * Double(frame.height) - 375) <= 2)
        #expect(abs(bounds.bottom * Double(frame.height) - 549) <= 2)
    }

    @Test("A partial horizontal border needs both sides of the rectangle",
          arguments: [false, true])
    func sparkBorderNeedsBothSides(_ removeRight: Bool) throws {
        let frame = try image("spark-border-top")
        let context = try #require(CGContext(data: nil, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: removeRight ? Double(frame.width) * 0.955 : 0,
                            y: Double(frame.height) - 545,
                            width: Double(frame.width) * 0.045, height: 165))
        let incomplete = try #require(context.makeImage())
        #expect(try GearDropScreenReader().bounds(in: incomplete) == nil)
    }

    @Test("The key inventory's stacked portal cards do not establish a drop panel")
    func keyInventory() throws {
        // One card's bottom border (row 433), the dark gap under it and the
        // next card's bottom border (614) once passed as a full-width box;
        // its key count "x1" then read as a one-item portal drop.
        let frame = try image("key-inventory")
        #expect(try GearDropScreenReader().bounds(in: frame) == nil)
    }

    @Test("A full-width box needs a vertical side at the panel's edge; either one is enough",
          arguments: [(true, false), (false, true), (true, true)])
    func fullWidthSides(_ hidden: (Bool, Bool)) throws {
        let (left, right) = hidden
        let frame = try image("five-base")
        let original = try #require(try GearDropScreenReader().bounds(in: frame))
        let context = try #require(CGContext(data: nil, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Rows 381-496, between the top (379) and bottom (498) borders, so
        // both horizontal strokes stay whole. Core Graphics' origin is the bottom left.
        let side = CGRect(x: 0, y: Double(frame.height) - 497, width: Double(frame.width) * 0.045, height: 116)
        if left { context.fill(side) }
        if right { context.fill(side.offsetBy(dx: Double(frame.width) * 0.955, dy: 0)) }
        let covered = try #require(context.makeImage())
        let bounds = try GearDropScreenReader().bounds(in: covered)
        if left && right {
            #expect(bounds == nil)
        } else {
            #expect(bounds == original)
        }
    }

    @Test("A panel whose sides sit nearer the screen edge, as on a wider phone, still reads")
    func sidesNearEdge() throws {
        // five-base's sides are at x 18 and 544 of 562 (0.032 and 0.968).
        // Cropping 4 px from each edge puts them at 0.025 and 0.975, where a
        // 440-pt-wide phone would draw them if the margin were fixed in points.
        let frame = try image("five-base")
        let original = try #require(try GearDropScreenReader().bounds(in: frame))
        let cropped = try #require(frame.cropping(to: CGRect(x: 4, y: 0, width: frame.width - 8,
                                                             height: frame.height)))
        #expect(Double(cropped.height) / Double(cropped.width) <= 2.25)
        let bounds = try #require(try GearDropScreenReader().bounds(in: cropped))
        #expect(abs(bounds.top - original.top) < 0.002)
        #expect(abs(bounds.bottom - original.bottom) < 0.002)
    }

    @Test("The conclusion, input lattice and map do not establish a drop panel")
    func negatives() throws {
        let reader = GearDropScreenReader()
        for path in ["Results/four-final.png", "Results/labels.png", "Phases/field-00381.png",
                     "Phases/field-00443.png", "Phases/field-00492.png", "Phases/field-00666.png"] {
            let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent(path))
            let frame = try #require(ImageDecoder.cgImage(from: data))
            if let bounds = try reader.bounds(in: frame) {
                let result = try reader.read(frame, bounds: bounds, sourceTime: 1)
                #expect(result.stage != .portal && result.stage != .bonus)
            }
        }
    }
}
