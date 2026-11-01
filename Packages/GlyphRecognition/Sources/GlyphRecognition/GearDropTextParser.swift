/// Item names and panel titles from the game language's text (GameText);
/// see Docs/GEAR_DROP_ITEMS.md. Unknown names stay unknown. Rarity bars are
/// not parsed as text; an item's fixed rarity can follow from its identity.
public struct GearDropTextParser: Sendable {
    public let text: GameText
    public init(language: GameLanguage = .english) { text = GameText(language) }
    /// Six item rows plus the physical row occupied by an optional effect.
    /// Keep physical positions stable when OCR misses that effect in a frame.
    static let rowLimit = 7

    public func read(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> GearDropFrameEvidence {
        let contained = lines.filter {
            $0.y >= bounds.top && $0.y + $0.height <= bounds.bottom + 0.003
                && $0.x >= 0.025 && $0.x + $0.width <= 0.98
        }
        let titles = contained.filter { $0.y + $0.height / 2 < bounds.top + 0.045 }
        let floor = text.language.confidence
        guard titles.count == 1, let title = titles.first, title.confidence >= floor.title else {
            return GearDropFrameEvidence(sourceTime: time, stage: .unknown, bounds: bounds)
        }
        let normalized = GameText.normalized(title.text)
        let stage: GearDropStage
        switch text.title(title.text) {
        case .bonus: stage = .bonus
        case .unsupported: stage = .unsupported
        case .bounty: stage = .excluded
        case .message: stage = .unknown
        case .other:
            // A near miss of an English title is unread, never a portal name.
            stage = normalized.isEmpty || Self.distance(normalized, "bonusitems") <= 3
                || Self.distance(normalized, "bountyclaimed") <= 3 ? .unknown : .portal
        }
        guard stage == .portal || stage == .bonus else {
            return GearDropFrameEvidence(sourceTime: time, stage: stage, bounds: bounds)
        }
        let body = self.body(contained, bounds: bounds)
        return GearDropFrameEvidence(sourceTime: time, stage: stage, bounds: bounds,
                                     entries: body.entries, unreadableRows: body.unreadable,
                                     effects: body.effects.count == 1 ? body.effects : nil,
                                     titleLanguage: stage == .bonus ? text.bonusTitleLanguage(title.text) : nil)
    }

    /// The rows and effects under the title, parsed as a panel's are.
    private func body(_ contained: [ResultTextLine], bounds: GearDropPanelBounds)
        -> (entries: [GearDropEntry], unreadable: Int, effects: [String]) {
        let floor = text.language.confidence
        var body = contained.filter { $0.y + $0.height / 2 >= bounds.top + 0.045 }
        // An active item effect adds a line under the title, such as
        // "ITO EN (+) applied.": recorded as an effect, never as an item row.
        let effectLines = body.filter {
            $0.confidence >= floor.title && $0.y + $0.height / 2 < bounds.top + 0.09
                && text.effect($0.text) != nil
        }
        body.removeAll { line in effectLines.contains(line) }
        let effects = Array(Set(effectLines.compactMap { text.effect($0.text) })).sorted()
        var rows: [Int: [ResultTextLine]] = [:]
        var unreadable = effects.count > 1 ? 1 : 0
        for line in body {
            guard let position = Self.position(of: line, in: bounds) else { unreadable += 1; continue }
            rows[position, default: []].append(line)
        }
        var entries: [GearDropEntry] = []
        for (position, fragments) in rows.sorted(by: { $0.key < $1.key }) {
            guard fragments.allSatisfy({ $0.confidence >= floor.line }) else { unreadable += 1; continue }
            let ordered = fragments.sorted { $0.x < $1.x }
            // Japanese panels cut a long name at the column's edge with no "…".
            let column = position % 2
            let right = ordered.map { $0.x + $0.width }.max() ?? 0
            let clipped = right >= (column == 0 ? 0.50 : 0.98) - 0.05
            if let entry = parseEntry(ordered.map(\.text).joined(separator: " "), row: position / 2,
                                      column: column, clipped: clipped) {
                entries.append(entry)
            } else { unreadable += 1 }
        }
        return (entries, unreadable + (body.isEmpty ? 1 : 0), effects)
    }

    /// A read with no panel stage (`read` gave `.unknown`: no single title
    /// line at the title floor, a message or a near miss) whose body still
    /// shows a drop panel: an applied effect line, or a row naming a known
    /// item, each at the floors a panel's own body needs. Such a read is a
    /// panel whose title went unread, not a false candidate: it only keeps
    /// the read pace. Its rows are never stored; that needs a title.
    public func showsUntitledPanel(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> Bool {
        guard read(lines: lines, bounds: bounds, at: time).stage == .unknown else { return false }
        let contained = lines.filter {
            $0.y >= bounds.top && $0.y + $0.height <= bounds.bottom + 0.003
                && $0.x >= 0.025 && $0.x + $0.width <= 0.98
        }
        let body = self.body(contained, bounds: bounds)
        return !body.effects.isEmpty || body.entries.contains { $0.item != nil }
    }

    /// The entry position (`row * 2 + column`) an item line belongs to, or nil
    /// when it lies outside the rows or crosses its column's edge.
    public static func position(of line: ResultTextLine, in bounds: GearDropPanelBounds) -> Int? {
        // The row pitch is constant across the measured portrait layouts.
        // Anchor to the moving panel, not the screen or OCR output order.
        let row = Int(((line.y + line.height / 2 - bounds.top - 0.067) / 0.036).rounded())
        let column = line.x < 0.5 ? 0 : 1
        guard (0..<rowLimit).contains(row), line.x + line.width <= (column == 0 ? 0.50 : 0.98) else { return nil }
        return row * 2 + column
    }

    /// Only known labels may leave OCR as effect metadata. Never retain raw
    /// text, and never discard the sign when comparing ITO EN variants.
    static func effect(from line: String) -> String? { GameText(.english).effect(line) }

    /// `clipped`: the row's text reaches its column's edge, so its name may
    /// be cut short without an ellipsis.
    public func parseEntry(_ text: String, row: Int, column: Int, clipped: Bool = false) -> GearDropEntry? {
        guard (0..<Self.rowLimit).contains(row), (0..<2).contains(column) else { return nil }
        let characters = Array(text)
        let markers = characters.indices.filter { ["x", "X", "×"].contains(characters[$0])
            && $0 + 1 < characters.count && characters[$0 + 1].isASCII && characters[$0 + 1].isNumber }
        guard markers.count == 1, let marker = markers.first else { return nil }
        var end = marker + 1
        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
        guard let quantity = Int(String(characters[(marker + 1)..<end])), (1...9999).contains(quantity),
              end < characters.count else { return nil }
        let name = String(characters[end...]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, !name.uppercased().contains(" AP") else { return nil }
        let item = self.text.item(named: name, clipped: clipped)
        guard !name.contains("+") || item == "ITO EN Transmuter (+)" else { return nil }
        let prefix = Array(String(characters[..<marker]).filter { !$0.isWhitespace })
        let levelled = item.map(GameText.levelledItems.contains) == true
        let level: Int? = {
            guard item.map(GameText.unlevelledItems.contains) != true, let last = prefix.last,
                  let value = Int(String(last)), (1...8).contains(value) else { return nil }
            let before = prefix.dropLast().last
            if before == "L" { return value }
            // Only an item that has levels: iOS reads its coloured L as "1" or
            // loses it in the icon ("15 x2", "1*)8 x1"). Rarity bars, which OCR
            // can read as "11", belong only to items without levels.
            guard levelled else { return nil }
            if let before, before.isNumber, before != "1" { return nil }
            return value
        }()
        let levelState: GearDropEntry.Level = level != nil ? .known
            : (item.map(GameText.unlevelledItems.contains) == true ? .notApplicable : .unreadable)
        let entry = GearDropEntry(column: column, row: row, item: item,
                                  levelState: levelState, level: level, quantity: quantity)
        return entry.withRarity(entry.intrinsicRarity)
    }

    private static func distance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        guard abs(a.count - b.count) <= 3 else { return 4 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() {
                next.append(min(next[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = next
        }
        return previous[b.count]
    }
}
