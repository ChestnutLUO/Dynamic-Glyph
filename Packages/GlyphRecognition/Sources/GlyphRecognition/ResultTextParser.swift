/// English portrait result layout. Values must be percentages in their own
/// fields; a nearby timer, item quantity, or missing value never becomes zero.
public struct ResultTextParser: Sendable {
    /// Where each value's line centre falls, as fractions of the frame height.
    public static let hackingValueBand: ClosedRange<Double> = 0.375...0.445
    public static let speedValueBand: ClosedRange<Double> = 0.535...0.605

    public let text: GameText
    public init(language: GameLanguage = .english) { text = GameText(language) }

    public func read(lines: [ResultTextLine], context: ResultReadContext, at time: Double,
                     appearances: [ResultSlotAppearance] = []) -> ResultFrameEvidence {
        let reliable = lines.filter { $0.confidence >= text.language.confidence.line }
        func normalized(_ text: String) -> String {
            String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        func inBand(_ line: ResultTextLine, _ band: ClosedRange<Double>) -> Bool {
            band.contains(line.y + line.height / 2) && line.x >= 0.06 && line.x + line.width <= 0.95
        }
        let hackingLines = reliable.filter { inBand($0, 0.30...0.37) && text.isHackingLabel($0.text) }
        let hackingLabel = !hackingLines.isEmpty
        let speedLabel = reliable.contains { inBand($0, 0.46...0.53) && text.isSpeedLabel($0.text) }
        let present = hackingLabel && speedLabel
        func percentage(in band: ClosedRange<Double>) -> Int? {
            let values = reliable.filter { inBand($0, band) }.compactMap { line -> Int? in
                let text = line.text.filter { !$0.isWhitespace }
                guard text.last == "%" || text.last == "％", text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }),
                      !text.dropLast().isEmpty, let value = Int(text.dropLast()), value <= 999 else { return nil }
                return value
            }
            let unique = Set(values)
            return unique.count == 1 ? unique.first : nil
        }
        let names = reliable.filter { inBand($0, 0.18...0.24) }.map { normalized($0.text) }
        let indices = context.glyphs.indices.filter { index in
            context.glyphs[index].map { names.contains(normalized($0)) } ?? false
        }
        // Repeated names cannot identify their animation stage on their own.
        let stage = indices.count == 1 ? indices.first : nil
        return ResultFrameEvidence(context: context, sourceTime: time, panelPresent: present,
            stageIndex: present ? stage : nil,
            hackingBonus: present ? percentage(in: Self.hackingValueBand) : nil,
            speedBonus: present ? percentage(in: Self.speedValueBand) : nil,
            appearances: present ? appearances : [], lines: lines,
            labelLanguage: present ? hackingLines.lazy.compactMap { self.text.hackingLabelLanguage($0.text) }.first : nil)
    }
}
