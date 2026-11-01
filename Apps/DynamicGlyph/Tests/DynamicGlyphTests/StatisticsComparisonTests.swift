import Foundation
import SwiftUI
import Testing

private final class StatisticsLocalizationBundle: NSObject {}

@Suite("Statistics localized comparisons")
struct StatisticsComparisonTests {
    private var bundle: Bundle { Bundle(for: StatisticsLocalizationBundle.self) }
    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try #require(bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
    private let previous = "8:28–9:29"

    private func highlighted(_ text: AttributedString) -> String {
        text.runs.filter {
            $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] != nil
        }.map { String(text[$0.range].characters) }.joined()
    }

    @Test("Only the delta is coloured even when the date contains that digit",
          arguments: ["en", "ja", "zh-Hans", "zh-Hant"], [2, -2, 1, -1, 0])
    func itemChanges(language: String, difference: Int) throws {
        let bundle = try localizedBundle(language)
        let sentence = StatisticsRangeText.itemChangeAttributed(difference, previous: previous,
                                                               locale: Locale(identifier: language), bundle: bundle)
        let styled = styledComparison(sentence, color: difference == 0 ? nil : .green)
        #expect(String(styled.characters).contains(previous))
        #expect(highlighted(styled) == (difference == 0 ? "" : String(abs(difference))))
        // The entire date argument remains secondary, including its 2s.
        let plain = String(styled.characters)
        switch language {
        case "zh-Hans", "zh-Hant": #expect(plain.hasPrefix(difference == 0 && language == "zh-Hans" ? "与" : difference == 0 ? "與" : "比"))
        case "ja": #expect(plain.contains(difference == 0 ? "同じ" : difference > 0 ? "増加" : "減少"))
        default:
            if abs(difference) == 1 { #expect(plain.contains("1 item from")) }
            if abs(difference) == 2 { #expect(plain.contains("2 items from")) }
        }
    }

    @Test("Generic hack, point and second changes retain the amount argument",
          arguments: ["en", "ja", "zh-Hans", "zh-Hant"], ["2", "2 pts", "0.2s"])
    func otherChanges(language: String, amount: String) throws {
        let bundle = try localizedBundle(language)
        for sign in [-1, 1] {
            let sentence = StatisticsRangeText.changeAttributed(amount, sign: sign, previous: previous,
                                                                locale: Locale(identifier: language), bundle: bundle)
            #expect(highlighted(styledComparison(sentence, color: .red)) == amount)
            #expect(highlighted(styledComparison(sentence, color: nil)).isEmpty)
        }
        let unchanged = StatisticsRangeText.changeAttributed(amount, sign: 0, previous: previous,
                                                              locale: Locale(identifier: language), bundle: bundle)
        #expect(highlighted(styledComparison(unchanged, color: .green)).isEmpty)
    }

    @Test("Axis marks are unique whole bucket starts, never half-hour duplicates",
          arguments: [0, 1, 2, 3, 4, 24, 48, 7, 30])
    func axisDates(count: Int) {
        let start = Date(timeIntervalSince1970: 0)
        let slots = (0..<count).map { index in
            let date = start.addingTimeInterval(Double(index) * 3600)
            return HackStatistics.ItemSlot(start: date, span: date..<date.addingTimeInterval(3600), items: index)
        }
        let marks = StatisticsRangeText.itemAxisDates(slots: slots)
        #expect(marks.count == min(count, 4))
        #expect(Set(marks).count == marks.count)
        #expect(marks.allSatisfy { mark in slots.contains { $0.start == mark } })
        #expect(marks.first == slots.first?.start)
        #expect(marks.last == slots.last?.start)
    }

    @Test("A live preset label expires at the displayed minute boundary without moving data",
          arguments: [StatisticsRange.Preset.lastHour, .last24Hours])
    func displayedPresetExpiry(preset: StatisticsRange.Preset) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tapped = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21,
                                                        hour: 10, minute: 29, second: 50))!
        let oldest = tapped.addingTimeInterval(-90 * 86400)
        let selection = StatisticsSelection.preset(preset, now: tapped, oldest: oldest, calendar: calendar)
        #expect(selection.matchedPreset(now: tapped.addingTimeInterval(9), oldest: oldest, calendar: calendar) == preset)
        let now = tapped.addingTimeInterval(10)
        #expect(selection.matchedPreset(now: now, oldest: oldest, calendar: calendar) == nil)
        let range = selection.range(now: now, oldest: oldest, calendar: calendar)
        let span = try #require(range.interval)
        let previous = try #require(range.comparisonInterval(calendar: calendar))
        #expect(range.preset == nil && range.isLive)
        #expect(span.lowerBound == selection.start)
        #expect(previous.upperBound == span.lowerBound)
        #expect(previous.upperBound.timeIntervalSince(previous.lowerBound) == span.upperBound.timeIntervalSince(span.lowerBound))
        let readout = StatisticsRangeText.readout(selection, now: now, oldest: oldest, calendar: calendar)
        #expect(readout.line2 == nil && readout.isLive)
    }
}
