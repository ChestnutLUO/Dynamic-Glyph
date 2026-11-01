import Foundation
import Testing

/// The Statistics summary line wraps only at its " · " separators: never
/// inside "26 in red", "红字 26" or "每次掉落 7.4", and never with the dot
/// leading the next line. Only the shown text carries the joiners.
@Suite("Statistics summary line breaks")
struct StatisticsLineBreakTests {
    static let joiner: Character = "\u{2060}", noBreakSpace: Character = "\u{00A0}"

    /// The text with the joiners taken out and no-break spaces made plain.
    func plain(_ text: String) -> String {
        String(text.filter { $0 != Self.joiner }.map { $0 == Self.noBreakSpace ? " " : $0 })
    }

    @Test("Segments are joined with a no-break space before the dot and break only after it")
    func joined() {
        let english = GearSummary.unbroken(["9 drops", "6.9 per drop", "26 in red"])
        #expect(plain(english) == "9 drops · 6.9 per drop · 26 in red")
        // The only ordinary spaces follow a separator's dot.
        let spaces = english.indices.filter { english[$0] == " " }
        #expect(spaces.count == 2)
        #expect(spaces.allSatisfy { english[english.index(before: $0)] == "·" })
        #expect(english.contains("\u{00A0}· "))
        #expect(!english.hasPrefix("·") && !english.contains("\u{2060}·") && !english.contains("·\u{2060}"))
    }

    @Test("Inside a Chinese or Japanese segment every character is joined to the next")
    func cjk() {
        let chinese = GearSummary.unbroken(["9 次掉落", "每次掉落 7.4", "红字 5"])
        #expect(plain(chinese) == "9 次掉落 · 每次掉落 7.4 · 红字 5")
        let segments = chinese.components(separatedBy: "\u{00A0}· ")
        #expect(segments.count == 3)
        for segment in segments {
            let characters = Array(segment)
            // Every other character is a joiner, so no break opportunity is left.
            #expect(characters.count % 2 == 1)
            #expect(characters.enumerated().allSatisfy { $0.offset % 2 == 1 ? $0.element == Self.joiner : $0.element != Self.joiner })
            #expect(!segment.contains(" "))
        }
        #expect(segments[2] == "红\u{2060}字\u{2060}\u{00A0}\u{2060}5")
        #expect(plain(GearSummary.unbroken(["赤表示 5"])) == "赤表示 5")
        #expect(GearSummary.unbroken([]).isEmpty && GearSummary.unbroken(["x"]) == "x")
    }
}
