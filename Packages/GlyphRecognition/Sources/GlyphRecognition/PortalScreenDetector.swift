/// The faction a portal screen's resonator bars are drawn in. A neutral
/// portal has no resonators, so no bars, and is not found this way.
public enum PortalFaction: String, Sendable, Codable, CaseIterable {
    case resistance, enlightened, machina

    /// One bar pixel's colour. Measured on 2026-09 and 2026-10 recordings at
    /// half resolution: Resistance bars about (40, 105, 145), Enlightened
    /// about (30, 80–186, 20–47), Machina about (146, 0, 0). Map beams,
    /// magenta result panels and pink notices miss them: their red ones carry
    /// blue (43 and up), their green ones red.
    func matches(red r: Int, green g: Int, blue b: Int) -> Bool {
        switch self {
        case .resistance: return b > 80 && g > 60 && r < 110 && b - r > 40 && b >= g
        case .enlightened: return g > 80 && r < 50 && b < 60 && g - b > 40
        case .machina: return r > 110 && g < 40 && b < 30
        }
    }
}

/// A cheap check for the portal screen: resonator bars at both edges, in
/// pairs at the same height, in one faction's colour. Measured on two phones:
/// bars of about 5% of the height, at least two pairs on every portal screen,
/// and no second pair on the map, Glyph, command, result or drop screens,
/// where portal beams can light one edge or form one tall pair.
public struct PortalScreenDetector: Sendable {
    public init() {}

    /// The rows of a frame the detector samples, so a caller can decode only
    /// this band.
    public static func band(frameHeight: Int) -> Range<Int> {
        Int(Double(frameHeight) * 0.30)..<Int(Double(frameHeight) * 0.66)
    }

    /// `image` holds frame rows starting at `bandTop`, full frame width.
    public func isCandidate(_ image: ColorImage, frameHeight: Int, bandTop: Int) -> Bool {
        faction(image, frameHeight: frameHeight, bandTop: bandTop) != nil
    }

    /// The faction whose bars form two or more pairs, or nil on any other
    /// screen. Should two factions both form pairs, the one with more wins;
    /// a tie names neither.
    public func faction(_ image: ColorImage, frameHeight: Int, bandTop: Int) -> PortalFaction? {
        let aspect = Double(frameHeight) / Double(image.width)
        guard (2.1...2.25).contains(aspect), image.width >= 280 else { return nil }
        let counts = PortalFaction.allCases.map { faction in
            (faction, pairs(of: faction, in: image, frameHeight: frameHeight, bandTop: bandTop))
        }.filter { $0.1 >= 2 }.sorted { $0.1 > $1.1 }
        guard let best = counts.first, counts.count == 1 || counts[1].1 < best.1 else { return nil }
        return best.0
    }

    private func pairs(of faction: PortalFaction, in image: ColorImage, frameHeight: Int, bandTop: Int) -> Int {
        let height = Double(frameHeight)
        let shortest = Int(height * 0.03), longest = Int(height * 0.08), offset = height * 0.012
        func bars(from x0: Double, to x1: Double) -> [Range<Int>] {
            let columns = Int(x0 * Double(image.width))..<Int(x1 * Double(image.width))
            var found: [Range<Int>] = []
            var start: Int?
            for y in Self.band(frameHeight: frameHeight) {
                let row = y - bandTop
                let lit = row >= 0 && row < image.height && columns.contains { x in
                    let p = image[x, row]
                    return faction.matches(red: Int(p.red), green: Int(p.green), blue: Int(p.blue))
                }
                if lit, start == nil { start = y }
                if !lit, let first = start { found.append(first..<y); start = nil }
            }
            if let first = start { found.append(first..<Self.band(frameHeight: frameHeight).upperBound) }
            return found.filter { (shortest...longest).contains($0.count) }
        }
        let left = bars(from: 0, to: 0.1), right = bars(from: 0.9, to: 1)
        return left.filter { bar in
            right.contains { abs(Double($0.lowerBound - bar.lowerBound)) <= offset
                && abs(Double($0.upperBound - bar.upperBound)) <= offset }
        }.count
    }
}

/// Resonator levels from the portal screen's label columns. Only a level
/// label counts; agent names beside it are never parsed or kept.
public struct PortalScreenParser: Sendable {
    public init() {}

    /// `yellowLabels` are the indices of lines whose L is drawn in L1's
    /// yellow; such a line's one level is 1 whatever digit was read.
    public func read(lines: [ResultTextLine], badgeHue: Double?, at time: Double,
                     faction: PortalFaction? = nil, yellowLabels: Set<Int> = []) -> PortalScreenEvidence {
        var levels: [Int] = []
        for (index, line) in lines.enumerated() where line.confidence >= 0.4 {
            let read = Self.levels(in: line.text)
            levels += yellowLabels.contains(index) && read.count == 1 ? [1] : read
        }
        let read = Array(levels.prefix(8))
        return PortalScreenEvidence(sourceTime: time, resonators: read, unreadSlots: 8 - read.count, badgeHue: badgeHue,
                                    faction: faction)
    }

    /// Whether a label's L, given the hues of its strongly coloured pixels,
    /// is L1's yellow. Each label's L is drawn in its level's colour. Vision
    /// reads L1 labels as "L7" or "17" (two of eight on a 2026-09-26
    /// Resistance portal, most on the 2026-10-05 Machina ones), and the
    /// yellow catches it. Measured on 114 portal screens: L1's L at 60–68°,
    /// every other level's far from it (L4 3–12°, L5 339–345°, L6 323–327°,
    /// L7 275–281°, L8 252–259°). Other levels aren't told apart by colour:
    /// a blue or green backdrop shifts their sampled hue by up to 100°,
    /// while no backdrop turned one yellow.
    public static func isLevelOneYellow(hues: [Double]) -> Bool {
        guard hues.count >= 20 else { return false }
        return Double(hues.filter { (50...78).contains($0) }.count) >= Double(hues.count) * 0.6
    }

    /// `L8`, and the forms OCR makes of it: a lower-case l, I or | for the
    /// coloured L, or "18" for a whole label read as digits. A digit inside a
    /// word, as in an agent name, never counts.
    static func levels(in text: String) -> [Int] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count == 1, let word = words.first, word.count == 2, word.first == "1",
           let value = word.last?.wholeNumberValue, (1...8).contains(value) { return [value] }
        var found: [Int] = []
        var index = 0
        while index < words.count {
            let word = words[index].filter { $0 != "A" && $0 != "^" }
            let characters = Array(word)
            if characters.count == 2, "LlI|".contains(characters[0]),
               let value = characters[1].wholeNumberValue, (1...8).contains(value) {
                found.append(value)
            } else if characters.count == 1, "LlI|".contains(characters[0]), index + 1 < words.count,
                      words[index + 1].count == 1, let value = words[index + 1].first?.wholeNumberValue,
                      (1...8).contains(value) {
                found.append(value); index += 1
            }
            index += 1
        }
        return found
    }
}
