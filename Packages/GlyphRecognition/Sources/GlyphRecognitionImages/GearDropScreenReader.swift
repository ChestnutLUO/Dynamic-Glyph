import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// Which language family last recovered a CJK panel title, so the next reads
/// try that family first without losing a read when the title's script changes.
/// Owned by one OCR lane, whose reads run one at a time.
public final class GearTitleLanguageMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var family: [String]?
    private var lastUsed = -Double.infinity
    /// A remembered family older than this belongs to an earlier panel.
    static let lifetime = 5.0

    public init() {}

    public var preferredFamily: [String]? {
        lock.lock(); defer { lock.unlock() }
        return family
    }

    func families(at time: Double, all: [[String]]) -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        guard let family, time >= lastUsed, time - lastUsed <= Self.lifetime else { return all }
        return [family] + all.filter { $0 != family }
    }

    /// Nil forgets: the title read without help, or all fallback families failed.
    func remember(_ family: [String]?, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        self.family = family; lastUsed = time
    }
}

/// Collects one read's OCR passes for the session log (`GearReadPass`).
/// Owned by one read at a time.
final class GearReadPassLog: @unchecked Sendable {
    private let lock = NSLock()
    private var passes: [GearReadPass] = []
    func append(_ pass: GearReadPass) { lock.withLock { passes.append(pass) } }
    var all: [GearReadPass] { lock.withLock { passes } }
}

/// Reads only the summary box. Animation cards, even immediately below the
/// box, are never submitted to OCR. No title string escapes this operation.
public struct GearDropScreenReader: Sendable {
    public let language: GameLanguage
    /// Where each OCR pass is noted, when a caller asks for them.
    let passLog: GearReadPassLog?
    /// Stops the read between and during passes (`GearReadCancellation`).
    let cancellation: GearReadCancellation?
    public init(language: GameLanguage = .english) { self.language = language; passLog = nil; cancellation = nil }
    init(language: GameLanguage, passLog: GearReadPassLog?, cancellation: GearReadCancellation? = nil) {
        self.language = language; self.passLog = passLog; self.cancellation = cancellation
    }

    /// Item rows. English keeps Simplified Chinese second, for Chinese
    /// portal titles; other games read their own script first.
    var itemLanguages: [String] { language == .english ? ["en-US", "zh-Hans"] : language.recognitionLanguages }

    static let titleFamilies = [["zh-Hant", "zh-Hans", "en-US"], ["ja-JP", "en-US"], ["ko-KR", "en-US"]]

    func rowPositions(in lines: [ResultTextLine], bounds: GearDropPanelBounds) -> Set<Int> {
        let observed = lines.filter {
            $0.y + $0.height / 2 >= bounds.top + 0.045 && $0.y >= bounds.top
                && $0.y + $0.height <= bounds.bottom + 0.003 && GameText(language).effect($0.text) == nil
        }.compactMap { GearDropTextParser.position(of: $0, in: bounds) }
        // Whole-panel OCR can omit one column entirely. Its neighbour still
        // establishes a physical row; the other crop must read its own item.
        return Set(observed.flatMap { [($0 / 2) * 2, ($0 / 2) * 2 + 1] })
    }

    func readItemRow(_ image: CGImage, bounds: GearDropPanelBounds,
                     position: Int, original: GearDropEntry?) throws -> GearDropEntry? {
        try itemRow(image, bounds: bounds, position: position, original: original)?.entry
    }

    private func itemRow(_ image: CGImage, bounds: GearDropPanelBounds,
                         position: Int, original: GearDropEntry?) throws
        -> (entry: GearDropEntry, lines: [RecognizedLine])? {
        guard (0..<14).contains(position) else { return nil }
        let row = position / 2, column = position % 2
        // Once the name and level are read, leave icons, rarity bars and the
        // coloured L out of the quantity/name crop. Otherwise keep the L so
        // this row must establish its own level. Neither crop clips digits.
        let quantityOnly = original?.item != nil && original?.levelState != .unreadable
        let left = (quantityOnly ? 0.195 : 0.12) + Double(column) * 0.465
        let right = column == 0 ? 0.50 : 0.965
        let center = bounds.top + 0.067 + Double(row) * 0.036
        let top = max(bounds.top, center - 0.018)
        let bottom = min(bounds.bottom, center + 0.018)
        guard bottom > top else { return nil }
        let rect = CGRect(x: left * Double(image.width), y: top * Double(image.height),
                          width: (right - left) * Double(image.width),
                          height: (bottom - top) * Double(image.height)).integral
        let recognized = try recognize(image, rect: rect, languages: itemLanguages, purpose: .row)
        var fragments = recognized.filter { GearDropTextParser.position(of: $0.line, in: bounds) == position }
            .sorted { $0.line.x < $1.line.x }
        guard !fragments.isEmpty,
              fragments.allSatisfy({ $0.line.confidence >= language.confidence.line }) else { return nil }
        let clipped = (fragments.map { $0.line.x + $0.line.width }.max() ?? 0) >= right - 0.05
        guard let parsed = GearDropTextParser(language: language).parseEntry(
            fragments.map { $0.line.text }.joined(separator: " "), row: row, column: column, clipped: clipped),
              let item = parsed.item, original?.item == nil || original?.item == item else { return nil }
        var quantity = parsed.quantity
        if language != .english {
            // Read only ASCII quantity markers/digits with English first.
            // Chinese-first OCR can score a red x1 as x11 in this very crop.
            // Keep the name and level from the game's same-frame reader.
            let quantityLeft = (0.195 + Double(column) * 0.465) * Double(image.width)
            let quantityRect = CGRect(x: quantityLeft, y: rect.minY,
                width: right * Double(image.width) - quantityLeft, height: rect.height).integral
            let numbers = try recognize(image, rect: quantityRect, languages: ["en-US", "zh-Hans"], purpose: .quantity)
                .filter { $0.line.confidence >= 0.5 && $0.quantity != nil
                    && GearDropTextParser.position(of: $0.line, in: bounds) == position }
            guard numbers.count == 1, let number = numbers.first,
                  let marker = Self.quantityRange(in: number.line.text),
                  let value = Int(number.line.text[marker].dropFirst()), (1...9999).contains(value) else { return nil }
            quantity = value
            // Preserve item-language text and attach the numeric pass's box
            // once, so colour comes from the actual marker and all its digits.
            var attached = false
            fragments = fragments.map { fragment in
                guard !attached, let old = Self.quantityRange(in: fragment.line.text) else {
                    return RecognizedLine(line: fragment.line, quantity: nil)
                }
                attached = true
                let line = fragment.line
                let text = line.text.replacingCharacters(in: old, with: String(number.line.text[marker]))
                return RecognizedLine(line: ResultTextLine(text: text, confidence: line.confidence,
                    x: line.x, y: line.y, width: line.width, height: line.height), quantity: number.quantity)
            }
        }
        let entry = GearDropEntry(column: column, row: row, item: item,
            levelState: quantityOnly ? original!.levelState : parsed.levelState,
            level: quantityOnly ? original!.level : parsed.level, quantity: quantity,
            rarity: parsed.rarity)
        return (entry, fragments)
    }

    /// Recover only the title; item text stays with the game's reader.
    /// `passes` limits how many families are tried, in order: the remembered
    /// family first, else the list's own order. Nil tries every family.
    func recoverTitle(bounds: GearDropPanelBounds, sourceTime: Double,
                      memory: GearTitleLanguageMemory?, passes: Int? = nil,
                      recognize: ([String]) throws -> [ResultTextLine]) throws -> [ResultTextLine] {
        // A Chinese/Japanese game can have an English portal name. CJK-first
        // OCR can score that heading at 0.3 even when it reads every letter.
        // English-first recovery must discard its item reads: those same
        // passes garble the Chinese rows underneath.
        let all = (language == .english ? [] : [["en-US", "zh-Hans"]]) + Self.titleFamilies
        let ordered = memory?.families(at: sourceTime, all: all) ?? all
        let families = passes.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
        for languages in families {
            let recovered = try recognize(languages).filter {
                $0.y >= bounds.top && $0.y + $0.height <= bounds.bottom + 0.003
                    && $0.x >= 0.025 && $0.x + $0.width <= 0.98
                    && $0.y + $0.height / 2 < bounds.top + 0.045
            }
            guard recovered.count == 1, recovered[0].confidence >= 0.7 else { continue }
            memory?.remember(languages, at: sourceTime)
            return recovered
        }
        memory?.remember(nil, at: sourceTime)
        return []
    }

    /// True unless the lines hold exactly one title-zone line at 0.7 or more,
    /// as `recoverTitle` judges each family's pass. Without retries, a title
    /// pass on the panel crop that fails this gets one more pass, in the same
    /// family, on the title zone (`titleZoneRect`).
    static func needsTitleFallback(_ lines: [ResultTextLine], bounds: GearDropPanelBounds) -> Bool {
        let titles = lines.filter {
            $0.y >= bounds.top && $0.y + $0.height <= bounds.bottom + 0.003
                && $0.x >= 0.025 && $0.x + $0.width <= 0.98
                && $0.y + $0.height / 2 < bounds.top + 0.045
        }
        return !(titles.count == 1 && titles[0].confidence >= 0.7)
    }

    /// Decodes only the rows the detector samples: this runs on every frame.
    public func bounds(in image: CGImage) throws -> GearDropPanelBounds? {
        let band = GearDropPanelDetector.band(frameHeight: image.height)
        let pixels = try ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: band.lowerBound,
                                                                     width: image.width, height: band.count))
        return GearDropPanelDetector().candidate(in: pixels, frameHeight: image.height, bandTop: band.lowerBound)
    }

    /// `titleMemory` prioritizes the last successful title language;
    /// each read can still try the remaining families on the same frame.
    public func read(_ image: CGImage, bounds: GearDropPanelBounds, sourceTime: Double,
                     titleMemory: GearTitleLanguageMemory? = nil) throws -> GearDropFrameEvidence {
        try readPanel(image, bounds: bounds, sourceTime: sourceTime, titleMemory: titleMemory).evidence
    }

    private struct PanelRead {
        let evidence: GearDropFrameEvidence
        /// Positions whose names this pack reads but the English pack cannot.
        /// Shared English names never establish a localized read.
        let localizedPositions: Set<Int>
        /// See `GearPanelReading.untitledPanel`.
        let untitledPanel: Bool
    }

    /// `retries` off reads the panel once, with no row rereads, except:
    /// - with `rereadsUnreadableRows`, one reread of each row the panel read
    ///   left unparsed (`rereadPositions`);
    /// - a missing or unclear title gets one title-recovery pass, in one
    ///   language family (`recoverTitle(passes: 1)`), as build 80 always did
    ///   with every family: a CJK-only portal name is otherwise never read.
    private func readPanel(_ image: CGImage, bounds: GearDropPanelBounds, sourceTime: Double,
                           titleMemory: GearTitleLanguageMemory? = nil, retries: Bool = true,
                           rereadsUnreadableRows: Bool = false) throws -> PanelRead {
        let rect = CGRect(x: Double(image.width) * 0.035, y: bounds.top * Double(image.height),
                          width: Double(image.width) * 0.93,
                          height: (bounds.bottom - bounds.top) * Double(image.height)).integral
        // Keep the item OCR unchanged: selecting Chinese for the entire box
        // can lose English item names and levels in mixed-language panels.
        var recognized = try recognize(image, rect: rect, languages: itemLanguages, purpose: .panel, bounds: bounds)
        var lines = recognized.map(\.line)
        let titleBottom = bounds.top + 0.045
        let titles = lines.filter {
            $0.y >= bounds.top && $0.y + $0.height <= bounds.bottom + 0.003
                && $0.x >= 0.025 && $0.x + $0.width <= 0.98
                && $0.y + $0.height / 2 < titleBottom
        }
        let titleFloor = language.confidence.title
        if titles.count == 1, titles[0].confidence >= titleFloor { titleMemory?.remember(nil, at: sourceTime) }
        if titles.isEmpty || (titles.count == 1 && titles[0].confidence < titleFloor) {
            // A portal name can be CJK even with English game UI. Retry
            // only a missing or low-confidence title from this same frame.
            // Multiple title lines remain ambiguous; a retry must still pass
            // the parser's title confidence and exclusion checks.
            // Keep the panel context: cropping to the title alone lowers
            // Vision confidence on short CJK names. Discard every fallback
            // item read. Try each language family in a bounded order;
            // stop at the first single, confident title. The scheduled read
            // still owns the OCR lane for the entire operation.
            // Up to four passes per unclear title (three in English). Try the
            // last successful family first, then the others if its script changes.
            // Without retries (Low Power Mode, a hot phone) only the first of
            // those, and only for a panel with an unclear title: its panel-crop
            // pass, then, only if that finds no single confident title, one
            // pass in the same family on the title zone with a 0.03 margin
            // (`titleZoneRect`). On a Mac the panel crop lost a CJK-only
            // portal name that crop read. At most two passes more; with
            // retries, every family reads the panel crop only, as before.
            let recovered = try recoverTitle(bounds: bounds, sourceTime: sourceTime, memory: titleMemory,
                                             passes: retries ? nil : 1) { languages in
                let panel = try recognize(image, rect: rect, languages: languages, purpose: .title,
                                          bounds: bounds).map(\.line)
                guard !retries, Self.needsTitleFallback(panel, bounds: bounds) else { return panel }
                let zone = Self.titleZoneRect(rect, bounds: bounds, imageHeight: image.height)
                return try recognize(image, rect: zone, languages: languages, purpose: .title, bounds: bounds).map(\.line)
            }
            if !recovered.isEmpty {
                lines.removeAll { titles.contains($0) }
                lines += recovered
            }
        }
        let parser = GearDropTextParser(language: language)
        let evidence = parser.read(lines: lines, bounds: bounds, at: sourceTime)
        let untitledPanel = evidence.stage == .unknown
            && parser.showsUntitledPanel(lines: lines, bounds: bounds, at: sourceTime)
        var rowEntries = evidence.entries
        var unreadableRows = evidence.unreadableRows
        let scope: RowRereads? = retries ? .unresolved : rereadsUnreadableRows ? .unparsed : nil
        if let scope, evidence.stage == .portal || evidence.stage == .bonus {
            // Red quantities and unresolved rows are fragile in whole-panel
            // OCR. Retry each physical position at most once, within this same
            // frame/read. A retry is not another tracker vote.
            let positions = Self.rereadPositions(rowPositions(in: lines, bounds: bounds), entries: rowEntries,
                                                 unreadableRows: unreadableRows, scope: scope) { entry in
                quantityColor(of: entry, lines: recognized, bounds: bounds, image: image).multiplied
            }
            for position in positions {
                let original = rowEntries.first { $0.position == position }
                guard let recovered = try itemRow(image, bounds: bounds, position: position, original: original) else { continue }
                if original == nil { unreadableRows = max(0, unreadableRows - 1) }
                rowEntries.removeAll { $0.position == position }
                rowEntries.append(recovered.entry)
                recognized.removeAll { GearDropTextParser.position(of: $0.line, in: bounds) == position }
                recognized += recovered.lines
                lines.removeAll { GearDropTextParser.position(of: $0, in: bounds) == position }
                lines += recovered.lines.map(\.line)
            }
        }
        let entries = rowEntries.sorted { $0.position < $1.position }.map { entry -> GearDropEntry in
            if let rarity = entry.intrinsicRarity { return entry.withRarity(rarity) }
            guard entry.hasRarityMeter else { return entry }
            let centerY = bounds.top + 0.067 + Double(entry.row) * 0.036
            let meter = CGRect(x: (0.123 + Double(entry.column) * 0.465) * Double(image.width),
                y: (centerY - 0.013) * Double(image.height),
                width: 0.074 * Double(image.width), height: 0.026 * Double(image.height)).integral
            // A clipped meter cannot establish that an unlit bar is present.
            guard meter.minY >= bounds.top * Double(image.height),
                  meter.maxY <= bounds.bottom * Double(image.height),
                  let pixels = try? ImageDecoder.decodeColor(image, in: meter) else {
                return entry.withRarity(.unreadable)
            }
            return entry.withRarity(GearRarityReader().read(pixels) ?? .unreadable)
        }.map { quantityColor(of: $0, lines: recognized, bounds: bounds, image: image) }
        let result = GearDropFrameEvidence(sourceTime: sourceTime, stage: evidence.stage, bounds: bounds,
            entries: entries, unreadableRows: unreadableRows, effects: evidence.effects,
            titleLanguage: evidence.titleLanguage)
        // Compare the same OCR fragments without English's confidence floor:
        // a low-confidence English name still isn't localized evidence.
        let body = lines.filter { line in
            line.y >= bounds.top && line.y + line.height <= bounds.bottom + 0.003
                && line.x >= 0.025 && line.x + line.width <= 0.98
                && line.y + line.height / 2 >= bounds.top + 0.045
                && !(line.y + line.height / 2 < bounds.top + 0.09
                    && line.confidence >= language.confidence.title && GameText(language).effect(line.text) != nil)
        }
        let rows = Dictionary(grouping: body.compactMap { line -> (Int, ResultTextLine)? in
            guard let position = GearDropTextParser.position(of: line, in: bounds) else { return nil }
            return (position, line)
        }, by: { $0.0 })
        let english = GearDropTextParser()
        let localized = entries.filter { entry in
            guard language != .english, let item = entry.item, let row = rows[entry.position] else { return false }
            let fragments = row.map { $0.1 }.sorted { $0.x < $1.x }
            let right = fragments.map { $0.x + $0.width }.max() ?? 0
            let clipped = right >= (entry.column == 0 ? 0.50 : 0.98) - 0.05
            let name = english.parseEntry(fragments.map(\.text).joined(separator: " "), row: entry.row,
                                          column: entry.column, clipped: clipped)?.item
            return name != item
        }.map(\.position)
        return PanelRead(evidence: result, localizedPositions: Set(localized), untitledPanel: untitledPanel)
    }

    /// Which rows a read rereads on its own frame.
    enum RowRereads: Sendable {
        /// A row with no entry, no name or no level, or a quantity not
        /// clearly white.
        case unresolved
        /// Only a row the panel read left without an entry, and only when it
        /// counted an unreadable row: the one reread kept when constrained
        /// (Low Power Mode, a hot phone), where a missing row costs the drop
        /// an item but each extra crop costs a whole OCR pass.
        case unparsed
    }

    /// The positions to reread, in order, each once. `positions` are the
    /// physical rows' columns the panel read saw (`rowPositions`); `multiplied`
    /// gives an entry's quantity colour, asked only when it decides.
    static func rereadPositions(_ positions: Set<Int>, entries: [GearDropEntry], unreadableRows: Int,
                                scope: RowRereads, multiplied: (GearDropEntry) -> Bool?) -> [Int] {
        positions.sorted().filter { position in
            let original = entries.first { $0.position == position }
            switch scope {
            case .unresolved:
                guard let original else { return true }
                return original.item == nil || original.levelState == .unreadable || multiplied(original) != false
            case .unparsed:
                return original == nil && unreadableRows > 0
            }
        }
    }

    /// A text line, and where its "x2" quantity is, in source pixels.
    private struct RecognizedLine {
        let line: ResultTextLine
        let quantity: CGRect?
    }

    private func quantityColor(of entry: GearDropEntry, lines: [RecognizedLine],
                               bounds: GearDropPanelBounds, image: CGImage) -> GearDropEntry {
        // The parser takes a row's quantity from its one line with a marker;
        // any other count leaves which pixels to read unknown.
        let boxes = lines.compactMap { line -> CGRect? in
            guard GearDropTextParser.position(of: line.line, in: bounds) == entry.position else { return nil }
            return line.quantity
        }
        let panel = CGRect(x: 0, y: bounds.top * Double(image.height), width: Double(image.width),
                           height: (bounds.bottom - bounds.top) * Double(image.height))
        guard boxes.count == 1 else { return entry }
        let box = boxes[0].intersection(panel).integral
        guard !box.isEmpty, let pixels = try? ImageDecoder.decodeColor(image, in: box) else { return entry }
        return entry.withMultiplied(GearQuantityColorReader().read(pixels))
    }

    /// The parser's quantity marker, "x" and its digits; nil unless the line
    /// holds exactly one, as an item row does.
    static func quantityRange(in text: String) -> Range<String.Index>? {
        func isDigit(_ index: String.Index) -> Bool {
            index < text.endIndex && text[index].isASCII && text[index].isNumber
        }
        let markers = text.indices.filter { ["x", "X", "×"].contains(text[$0]) && isDigit(text.index(after: $0)) }
        guard markers.count == 1, let marker = markers.first else { return nil }
        var end = text.index(after: marker)
        while isDigit(end) { end = text.index(after: end) }
        return marker..<end
    }

    /// The title zone with a margin, for the title pass's fallback without
    /// retries: from `bounds.top - 0.03` (not above the frame) to
    /// `bounds.top + 0.045 + 0.03` (not below the panel), across the panel
    /// crop's width. On a Mac the panel crop read the CJK-only portal name
    /// of 2026-10-28 hack 1 on 9 of 40 frames, this crop on 40 of 40
    /// (2026-10-29 title probe, `zone0.03`).
    static func titleZoneRect(_ panel: CGRect, bounds: GearDropPanelBounds, imageHeight: Int) -> CGRect {
        let margin = 0.03
        let top = max(0, bounds.top - margin), bottom = min(bounds.bottom, bounds.top + 0.045 + margin)
        return CGRect(x: panel.minX, y: top * Double(imageHeight), width: panel.width,
                      height: (bottom - top) * Double(imageHeight)).integral
    }

    private func recognize(_ image: CGImage, rect: CGRect, languages: [String], purpose: GearReadPass.Purpose,
                           bounds: GearDropPanelBounds? = nil) throws -> [RecognizedLine] {
        try cancellation?.check()
        guard let crop = image.cropping(to: rect) else {
            return []
        }
        let started = ProcessInfo.processInfo.systemUptime
        // The captured item font is small at 562 px. Scale pixels, not the OCR
        // coordinates, so all evidence remains in the source frame's space.
        guard let canvas = CGContext(data: nil, width: crop.width * 2, height: crop.height * 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageDecoder.DecodeError.cannotCreateContext }
        canvas.interpolationQuality = .high
        canvas.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2))
        guard let enlarged = canvas.makeImage() else { throw ImageDecoder.DecodeError.cannotCreateContext }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = false
        // A cancelled pass may end with an error or with no results: either
        // way the read stops here, and nothing of the pass is used.
        try cancellation?.begin(request)
        defer { cancellation?.end() }
        try TextReadProbe.measure(.gearPanel) { try VNImageRequestHandler(cgImage: enlarged).perform([request]) }
        try cancellation?.check()
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let line = ResultTextLine(text: best.string, confidence: Double(best.confidence),
                x: (rect.minX + box.minX * rect.width) / Double(image.width),
                y: (rect.minY + (1 - box.maxY) * rect.height) / Double(image.height),
                width: box.width * rect.width / Double(image.width),
                height: box.height * rect.height / Double(image.height))
            guard let marker = Self.quantityRange(in: best.string),
                  let quantity = try? best.boundingBox(for: marker)?.boundingBox else {
                return RecognizedLine(line: line, quantity: nil)
            }
            return RecognizedLine(line: line, quantity: CGRect(x: rect.minX + quantity.minX * rect.width,
                y: rect.minY + (1 - quantity.maxY) * rect.height,
                width: quantity.width * rect.width, height: quantity.height * rect.height))
        }
        if let passLog {
            // Counts and confidences only: no text leaves this function.
            var titles: [Double] = []
            if let bounds {
                for recognized in lines {
                    let line: ResultTextLine = recognized.line
                    let inside = line.y >= bounds.top && line.y + line.height <= bounds.bottom + 0.003
                    let across = line.x >= 0.025 && line.x + line.width <= 0.98
                    let top = line.y + line.height / 2 < bounds.top + 0.045
                    if inside && across && top { titles.append(line.confidence) }
                }
            }
            passLog.append(GearReadPass(purpose: purpose, languages: languages, lines: lines.count,
                titleLines: titles.count, titleConfidences: titles.sorted(by: >),
                milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000))
        }
        return lines
    }
}

extension GearDropScreenReader {
    /// Another language's Bonus title, or a row whose name wasn't read: a
    /// Japanese panel can hold an English "Power Cube" beside names an
    /// English reader can't read.
    static func needsOtherLanguages(_ evidence: GearDropFrameEvidence) -> Bool {
        evidence.stage == .unsupported
            || (evidence.stage != .excluded && (evidence.entries.isEmpty || evidence.unreadableRows > 0
                || evidence.entries.contains { $0.item == nil }))
    }

    /// A portal read must recover localized names while preserving every
    /// quantity and known identity from the original read of this frame.
    static func improvesPortal(_ candidate: GearDropFrameEvidence, over original: GearDropFrameEvidence,
                               localizedPositions: Set<Int>) -> Bool {
        guard candidate.stage == .portal, [.portal, .unknown].contains(original.stage), !localizedPositions.isEmpty,
              candidate.entries.filter({ $0.item != nil }).count > original.entries.filter({ $0.item != nil }).count,
              candidate.unreadableRows + candidate.entries.filter({ $0.item == nil }).count
                <= original.unreadableRows + original.entries.filter({ $0.item == nil }).count else { return false }
        return original.entries.allSatisfy { entry in
            guard let recovered = candidate.entries.first(where: { $0.position == entry.position }),
                  recovered.quantity == entry.quantity else { return false }
            if let item = entry.item, recovered.item != item { return false }
            if entry.levelState != .unreadable,
               recovered.levelState != entry.levelState || recovered.level != entry.level { return false }
            if let rarity = entry.rarity, rarity != .unreadable, recovered.rarity != rarity { return false }
            if let multiplied = entry.multiplied, recovered.multiplied != multiplied { return false }
            return true
        } && (original.effects == nil || original.effects == candidate.effects)
    }

    /// Tries other readers for unresolved rows. A better portal read can be
    /// returned without naming the game's language; only its own Bonus title
    /// changes that language. Shared English item names authorize neither.
    /// `retries` off (Low Power Mode, a hot device) makes it one pass in the
    /// game's language: the panel's next frame is read again anyway. Only a
    /// missing or unclear title adds one title pass, in one family. With
    /// `rereadsUnreadableRows`, a row that pass left unparsed is still read
    /// once more on its own: a red "x1 Portal Key" went unread in all five
    /// reads of a hot phone's portal panel.
    public static func read(_ image: CGImage, bounds: GearDropPanelBounds, sourceTime: Double,
                            titleMemory: GearTitleLanguageMemory? = nil,
                            languages memory: GameLanguageMemory, retries: Bool = true,
                            rereadsUnreadableRows: Bool = false) throws -> GearDropFrameEvidence {
        try reading(image, bounds: bounds, sourceTime: sourceTime, titleMemory: titleMemory, languages: memory,
                    retries: retries, rereadsUnreadableRows: rereadsUnreadableRows).evidence
    }

    /// `read`, with whether an unknown read showed an untitled panel and
    /// each OCR pass it took (counts, confidences and times; no text).
    /// `cancellation` stops it early: it then throws `CancellationError`
    /// (or Vision's own error for the pass it cancelled) and returns nothing.
    /// Once its last OCR pass has finished, it returns as usual.
    public static func reading(_ image: CGImage, bounds: GearDropPanelBounds, sourceTime: Double,
                               titleMemory: GearTitleLanguageMemory? = nil,
                               languages memory: GameLanguageMemory, retries: Bool = true,
                               rereadsUnreadableRows: Bool = false,
                               cancellation: GearReadCancellation? = nil) throws -> GearPanelReading {
        let log = GearReadPassLog(), current = memory.current
        let first = try GearDropScreenReader(language: current, passLog: log, cancellation: cancellation)
            .readPanel(image, bounds: bounds, sourceTime: sourceTime, titleMemory: titleMemory,
                       retries: retries, rereadsUnreadableRows: rereadsUnreadableRows)
        let evidence = try read(first.evidence, in: current, image, bounds: bounds, sourceTime: sourceTime,
                                titleMemory: titleMemory, languages: memory, retries: retries, log: log,
                                cancellation: cancellation)
        return GearPanelReading(evidence: evidence, untitledPanel: evidence.stage == .unknown && first.untitledPanel,
                                passes: log.all)
    }

    /// The other-language retries after the first read, `evidence`, in `current`.
    private static func read(_ evidence: GearDropFrameEvidence, in current: GameLanguage, _ image: CGImage,
                             bounds: GearDropPanelBounds, sourceTime: Double, titleMemory: GearTitleLanguageMemory?,
                             languages memory: GameLanguageMemory, retries: Bool,
                             log: GearReadPassLog, cancellation: GearReadCancellation?) throws -> GearDropFrameEvidence {
        // Only the Bonus title names a language, and no game leaves it in
        // English, so it can confirm English too.
        if evidence.titleLanguage == current { memory.found(current) }
        guard retries, needsOtherLanguages(evidence) else { return evidence }
        let preferred = memory.panelReadingLanguage(at: sourceTime, bounds: bounds)
        var best: (language: GameLanguage, evidence: GearDropFrameEvidence)?
        var ambiguous = false
        var languages = preferred.map { $0 == current ? [] : [$0] } ?? []
        let alternatives = memory.alternatives(at: sourceTime, on: .panel).filter { !languages.contains($0) }
        languages += alternatives
        for language in languages {
            let read = try GearDropScreenReader(language: language, passLog: log, cancellation: cancellation)
                .readPanel(image, bounds: bounds, sourceTime: sourceTime, titleMemory: titleMemory)
            let other = read.evidence
            // Only the language's own Bonus title names it: item names such as
            // Portal Key stay English in several games, and English is read in
            // every language.
            if other.titleLanguage == language {
                memory.found(language)
                return other
            }
            guard improvesPortal(other, over: evidence, localizedPositions: read.localizedPositions) else { continue }
            // Reuse a previously verified reader during the retry interval,
            // while checking its evidence again on this frame.
            if language == preferred, !needsOtherLanguages(other) {
                memory.rememberPanelReading(language, at: sourceTime, bounds: bounds)
                return other
            }
            let named = other.entries.filter { $0.item != nil }.count
            let bestNamed = best?.evidence.entries.filter { $0.item != nil }.count ?? 0
            if named > bestNamed {
                best = (language, other); ambiguous = false
            } else if named == bestNamed, let best, best.evidence.entries != other.entries {
                ambiguous = true
            }
        }
        if let best, !ambiguous {
            memory.rememberPanelReading(best.language, at: sourceTime, bounds: bounds)
            return best.evidence
        }
        return evidence
    }
}
