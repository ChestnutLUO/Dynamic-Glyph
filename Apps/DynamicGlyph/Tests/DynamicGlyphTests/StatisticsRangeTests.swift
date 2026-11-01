import Foundation
import Testing
import GlyphRecognition

@Suite("Statistics ranges")
struct StatisticsRangeTests {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    let calendar = Self.calendar("UTC")
    /// 20 October 2026, 15:00 UTC.
    var now: Date { date(2026, 10, 20, 15) }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
              in calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func day(_ daysAgo: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(Double(hour) * 3600)
    }

    func hack(_ id: String, at date: Date, items: Int = 1) -> HackResultRecord {
        let entry = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8,
                                  quantity: items, rarity: nil, multiplied: false)
        let summary = GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: 1,
                                      association: .ordered,
                                      panels: [.init(stage: .portal, entries: [entry], partial: false),
                                               .init(stage: .bonus, entries: [], partial: false)])
        return HackResultRecord(id: id, date: date,
                                summary: HackResultSummary(captureSessionID: 1, hackID: 1, state: .complete, isClosed: true,
                                                           closeReason: "panelLeft",
                                                           hackingBonus: .init(percent: 100, isFinal: true),
                                                           speedBonus: .init(percent: 50, isFinal: true), slots: []),
                                gear: HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .read(summary)))
    }

    func drop(_ id: String, at date: Date, items: Int = 1) -> GearDropRecord {
        let entry = GearDropEntry(column: 0, row: 0, item: "Power Cube", levelState: .known, level: 7,
                                  quantity: items, rarity: nil, multiplied: false)
        let summary = GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: nil,
                                      association: .noWaitingHack,
                                      panels: [.init(stage: .portal, entries: [entry], partial: false)])
        return GearDropRecord(id: id, date: date, drop: GearDrop(captureSessionID: 1, summary: summary))
    }

    /// A hack and a drop each day for 40 days, with as many items as days ago plus one.
    var history: (records: [HackResultRecord], drops: [GearDropRecord]) {
        let records = (0..<40).map { hack("h\($0)", at: day($0), items: $0 + 1) }
        let drops = (0..<40).map { drop("d\($0)", at: day($0, hour: 20), items: $0 + 1) }
        return (records, drops)
    }

    func statistics(_ range: StatisticsRange, records: [HackResultRecord], drops: [GearDropRecord],
                    history: StatisticsHistory? = nil, calendar: Calendar? = nil) -> HackStatistics {
        HackStatistics(records: records, drops: drops, range: range, history: history, now: now,
                       calendar: calendar ?? self.calendar)
    }

    // MARK: - Whole days

    @Test("7 days stepped back twice is the 7 days ending 14 days ago, and totals the 7 Day views")
    func sevenDaysBackTwice() throws {
        let current = StatisticsRange.preset(.sevenDays, endingOn: now, calendar: calendar)
        #expect(current.interval == day(6, hour: 0)..<day(-1, hour: 0))
        let back = try #require(current.shifted(by: -1, calendar: calendar)?.shifted(by: -1, calendar: calendar))
        #expect(back.preset == .sevenDays && back.dayCount(calendar: calendar) == 7)
        #expect(back.lastDay(calendar: calendar) == day(14, hour: 0))
        #expect(back.firstDay == day(20, hour: 0))
        let (records, drops) = history
        let week = statistics(back, records: records, drops: drops)
        let days = (14...20).map {
            statistics(.preset(.day, endingOn: day($0), calendar: calendar), records: records, drops: drops)
        }
        #expect(week.hacks == 7 && week.drops == 7)
        #expect(week.items == days.map(\.items).reduce(0, +))
        #expect(week.hacks == days.map(\.hacks).reduce(0, +))
        #expect(week.items == (15...21).reduce(0, +) * 2)
    }

    @Test("30 days are 30 calendar dates ending today, and ‹ shows the 30 before")
    func thirtyDays() throws {
        let current = StatisticsRange.preset(.thirtyDays, endingOn: now, calendar: calendar)
        #expect(current.dayCount(calendar: calendar) == 30)
        #expect(current.firstDay == day(29, hour: 0))
        let previous = try #require(current.shifted(by: -1, calendar: calendar))
        #expect(previous.interval == day(59, hour: 0)..<day(29, hour: 0))
        #expect(current.comparisonInterval(calendar: calendar) == previous.interval)
    }

    @Test("Custom Oct 3–17 is 15 dates, and Export of it holds the same records and totals")
    func customMatchesExport() throws {
        let range = StatisticsRange(preset: nil, interval: date(2026, 10, 3)..<date(2026, 10, 18), wholeDays: true)
        #expect(range.preset == nil && range.dayCount(calendar: calendar) == 15)
        #expect(range.interval == date(2026, 10, 3)..<date(2026, 10, 18))
        let (records, drops) = history
        let shown = statistics(range, records: records, drops: drops)
        let (exportedRecords, exportedDrops) = range.filter(records: records, drops: drops)
        let file = GearExport.make(GearExport.Snapshot(records: exportedRecords, drops: exportedDrops,
                                                       exporterVersion: nil, exporterBuild: nil),
                                   options: .init(), calendar: calendar)
        #expect(file.counts.hacks == shown.hacks && file.counts.drops == shown.drops && shown.hacks == 15)
        #expect(HackStatistics(records: exportedRecords, drops: exportedDrops, period: .all, now: now,
                               calendar: calendar).items == shown.items)
        // Oct 3 to 17 are 3 to 17 days ago, so 4 to 18 items each, twice.
        #expect(shown.items == (4...18).reduce(0, +) * 2)
        #expect(range.comparisonInterval(calendar: calendar) == date(2026, 9, 18)..<date(2026, 10, 3))
    }

    @Test("Days move by calendar days across a daylight-saving change, not by 24 hours")
    func daylightSaving() throws {
        let newYork = Self.calendar("America/New_York")
        // Clocks go back on 1 November 2026.
        let week = StatisticsRange.preset(.sevenDays, endingOn: date(2026, 11, 3, 12, in: newYork), calendar: newYork)
        let interval = try #require(week.interval)
        #expect(interval == date(2026, 10, 28, in: newYork)..<date(2026, 11, 4, in: newYork))
        #expect(interval.upperBound.timeIntervalSince(interval.lowerBound) == 7 * 86_400 + 3_600)
        #expect(week.dayCount(calendar: newYork) == 7)
        let previous = try #require(week.shifted(by: -1, calendar: newYork)?.interval)
        #expect(previous == date(2026, 10, 21, in: newYork)..<date(2026, 10, 28, in: newYork))
        let next = try #require(StatisticsRange.preset(.day, endingOn: date(2026, 10, 31, 12, in: newYork), calendar: newYork)
            .shifted(by: 1, calendar: newYork)?.interval)
        #expect(next == date(2026, 11, 1, in: newYork)..<date(2026, 11, 2, in: newYork))
        #expect(next.upperBound.timeIntervalSince(next.lowerBound) == 25 * 3_600)
        // A hack at 23:30 on the long day belongs to it.
        let late = date(2026, 11, 1, 23, 30, in: newYork)
        #expect(StatisticsRange(preset: .day, interval: next, wholeDays: true).contains(late))
    }

    @Test("A range across the new year keeps its dates and steps back across it")
    func crossYear() throws {
        let range = StatisticsRange(preset: nil, interval: date(2025, 12, 28)..<date(2026, 1, 4), wholeDays: true)
        #expect(range.dayCount(calendar: calendar) == 7)
        #expect(range.comparisonInterval(calendar: calendar) == date(2025, 12, 21)..<date(2025, 12, 28))
        let month = StatisticsRange.preset(.thirtyDays, endingOn: date(2026, 1, 10), calendar: calendar)
        #expect(month.firstDay == date(2025, 12, 12))
    }



    @Test("Filtering is half-open: midnight starts the next day")
    func halfOpen() {
        let today = StatisticsRange.preset(.day, endingOn: now, calendar: calendar)
        #expect(today.contains(day(0, hour: 0)))
        #expect(!today.contains(day(-1, hour: 0)))
        #expect(!today.contains(day(0, hour: 0).addingTimeInterval(-1)))
        #expect(StatisticsRange.all.contains(.distantPast))
    }





    @Test("The widget's periods open the matching presets")
    func widgetLink() {
        #expect(StatisticsPeriod.allCases.map(StatisticsRange.Preset.init) == [.day, .sevenDays, .all])
    }

    // MARK: - Timed ranges

    @Test("A same-day timed range includes its start and leaves out its end")
    func sameDayTimed() throws {
        let range = try #require(StatisticsRange.timed(from: date(2026, 10, 17, 14), until: date(2026, 10, 17, 17, 30)))
        #expect(range.preset == nil && !range.wholeDays && range.dayCount(calendar: calendar) == nil)
        #expect(range.contains(date(2026, 10, 17, 14)))
        #expect(range.contains(date(2026, 10, 17, 14, 7)))
        #expect(!range.contains(date(2026, 10, 17, 17, 30)))
        #expect(range.comparisonInterval(calendar: calendar) == date(2026, 10, 17, 10, 30)..<date(2026, 10, 17, 14))
        let records = [hack("start", at: date(2026, 10, 17, 14)), hack("end", at: date(2026, 10, 17, 17, 30)),
                       hack("inside", at: date(2026, 10, 17, 17, 29))]
        let shown = statistics(range, records: records, drops: [drop("d", at: date(2026, 10, 17, 17, 30))])
        #expect(shown.hacks == 2 && shown.drops == 0 && shown.hourly)
        // The charts span whole hours: 17:00–18:00 holds 17:29's bar.
        #expect(shown.hours == date(2026, 10, 17, 14)..<date(2026, 10, 17, 18))
    }

    @Test("An overnight range is four hours and steps back to the four before")
    func overnight() throws {
        let range = try #require(StatisticsRange.timed(from: date(2026, 10, 16, 22), until: date(2026, 10, 17, 2)))
        let previous = try #require(range.shifted(by: -1, calendar: calendar))
        #expect(previous.interval == date(2026, 10, 16, 18)..<date(2026, 10, 16, 22))
        #expect(!previous.wholeDays && previous.preset == nil)
        #expect(range.lastDay(calendar: calendar) == date(2026, 10, 17))
        let midnightEnd = try #require(StatisticsRange.timed(from: date(2026, 10, 16, 22), until: date(2026, 10, 17)))
        #expect(midnightEnd.lastDay(calendar: calendar) == date(2026, 10, 16))
    }

    @Test("Equal or reversed ends make no timed range")
    func invalidTimed() {
        #expect(StatisticsRange.timed(from: date(2026, 10, 17, 14), until: date(2026, 10, 17, 14)) == nil)
        #expect(StatisticsRange.timed(from: date(2026, 10, 17, 14), until: date(2026, 10, 17, 13, 45)) == nil)
    }

    @Test("Three hours step and compare by elapsed time across a daylight-saving change")
    func timedDaylightSaving() throws {
        let newYork = Self.calendar("America/New_York")
        // 03:00–06:00 EST on 1 November 2026, the day clocks go back at 02:00 EDT.
        let start = date(2026, 11, 1, 3, in: newYork), end = date(2026, 11, 1, 6, in: newYork)
        let range = try #require(StatisticsRange.timed(from: start, until: end))
        let previous = try #require(range.comparisonInterval(calendar: newYork))
        #expect(previous == start.addingTimeInterval(-3 * 3_600)..<start)
        // Three elapsed hours before 03:00 EST is 01:00 EDT, not midnight.
        #expect(newYork.dateComponents([.hour], from: previous.lowerBound).hour == 1)
        #expect(newYork.timeZone.secondsFromGMT(for: previous.lowerBound) == -4 * 3_600)
        let records = [hack("before", at: previous.lowerBound.addingTimeInterval(60)), hack("now", at: start)]
        let history = StatisticsHistory(hacks: .init(oldestDay: date(2026, 10, 1, in: newYork), mayBeTrimmed: false),
                                        drops: nil, newestDay: nil, now: date(2026, 11, 2, in: newYork), calendar: newYork)
        let shown = statistics(range, records: records, drops: [], history: history, calendar: newYork)
        #expect(shown.hacks == 1 && shown.change?.hacks == 0 && !shown.comparisonUnavailable)
    }



    // MARK: - Bounds and comparisons



    @Test("The oldest day is the earlier of both stores, gear-only included; nothing kept has no bounds")
    func oldestDay() {
        let both = StatisticsHistory(records: [hack("h", at: day(3))], drops: [drop("d", at: day(12))],
                                     keepsResults: true, now: now, calendar: calendar)
        #expect(both.oldestDay == day(12, hour: 0) && both.hacks?.oldestDay == day(3, hour: 0))
        let gearOnly = StatisticsHistory(records: [], drops: [drop("d", at: day(5)), drop("e", at: day(2))],
                                         keepsResults: true, now: now, calendar: calendar)
        #expect(gearOnly.oldestDay == day(5, hour: 0) && gearOnly.hacks == nil)
        #expect(gearOnly.newestDay == day(2, hour: 0))
        let empty = StatisticsHistory(records: [], drops: [], keepsResults: true, now: now, calendar: calendar)
        #expect(empty.oldestDay == nil)
    }

    @Test("Comparison is unavailable when the interval before reaches past the hacks kept")
    func comparisonSuppressed() {
        let records = [hack("a", at: day(0)), hack("b", at: day(1)), hack("c", at: day(2))]
        // Drops reach further back, but say nothing about the hacks kept.
        let drops = [drop("old", at: day(20))]
        let history = StatisticsHistory(records: records, drops: drops, keepsResults: true, now: now, calendar: calendar)
        let today = StatisticsRange.preset(.day, endingOn: now, calendar: calendar)
        let shown = statistics(today, records: records, drops: drops, history: history)
        #expect(shown.change?.hacks == 0 && !shown.comparisonUnavailable)
        let oldest = StatisticsRange.preset(.day, endingOn: day(2), calendar: calendar)
        #expect(!history.hacksComparable(oldest, calendar: calendar) && history.dropsComparable(oldest, calendar: calendar))
        let atOldest = statistics(oldest, records: records, drops: drops, history: history)
        #expect(atOldest.change == nil && atOldest.comparisonUnavailable)
        let week = statistics(.preset(.sevenDays, endingOn: now, calendar: calendar), records: records, drops: drops,
                              history: history)
        #expect(week.change == nil && week.comparisonUnavailable)
        let all = statistics(.all, records: records, drops: drops, history: history)
        #expect(all.change == nil && !all.comparisonUnavailable)
        // Without history nothing is compared.
        #expect(statistics(today, records: records, drops: drops).comparisonUnavailable)
        // An empty range shows its empty state, not the unavailable line.
        let empty = statistics(.preset(.day, endingOn: day(5), calendar: calendar), records: records, drops: drops,
                               history: history)
        #expect(!empty.comparisonUnavailable)
    }

    @Test("A trimmed stream's oldest day may be partial, so the day after can't be compared with it")
    func trimmed() {
        let records = (0..<4).map { hack("h\($0)", at: day($0)) }
        let retention = HackResultStore.Retention(maximumCount: 4, maximumAge: 90 * 86_400)
        let history = StatisticsHistory(records: records, drops: [], keepsResults: true, retention: retention,
                                        now: now, calendar: calendar)
        #expect(history.hacks?.mayBeTrimmed == true)
        #expect(!history.hacksComparable(.preset(.day, endingOn: day(2), calendar: calendar), calendar: calendar))
        #expect(history.hacksComparable(.preset(.day, endingOn: day(1), calendar: calendar), calendar: calendar))
        let untrimmed = StatisticsHistory(records: records, drops: [], keepsResults: true, now: now, calendar: calendar)
        #expect(untrimmed.hacksComparable(.preset(.day, endingOn: day(2), calendar: calendar), calendar: calendar))
        let aged = StatisticsHistory(records: [hack("old", at: day(90))], drops: [], keepsResults: true,
                                     now: now, calendar: calendar)
        #expect(aged.hacks?.mayBeTrimmed == true)
        let unsaved = StatisticsHistory(records: records, drops: [], keepsResults: false, now: now, calendar: calendar)
        #expect(unsaved.hacks?.mayBeTrimmed == true)
    }

    // MARK: - Quick choices

    /// 17:41:17 UTC: not on any grid.
    var oddNow: Date { date(2026, 10, 20, 17, 41).addingTimeInterval(17) }

    func keptHistory(now: Date) -> StatisticsHistory {
        StatisticsHistory(hacks: .init(oldestDay: day(30, hour: 0), mayBeTrimmed: false),
                          drops: .init(oldestDay: day(30, hour: 0), mayBeTrimmed: false),
                          newestDay: nil, now: now, calendar: calendar)
    }





    @Test("Hourly charts of a Last… choice span whole hours, so the last hour's bar fits")
    func quickChartHours() {
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-10800), until: oddNow)!
        let shown = HackStatistics(records: [hack("late", at: oddNow.addingTimeInterval(-60))], drops: [],
                                   range: range, history: keptHistory(now: oddNow), now: oddNow, calendar: calendar)
        #expect(shown.hourly && shown.hours == date(2026, 10, 20, 14)..<date(2026, 10, 20, 18))
        #expect(shown.itemBuckets.map(\.start) == [date(2026, 10, 20, 17)])
    }











    // MARK: - Items

    @Test("Items compare with the interval before, by the drops kept, not the hacks")
    func itemComparison() {
        let records = [hack("a", at: day(0), items: 5), hack("b", at: day(1), items: 2)]
        let drops = [drop("old", at: day(1), items: 1)]
        let history = StatisticsHistory(records: records, drops: drops, keepsResults: true, now: now, calendar: calendar)
        let today = statistics(.preset(.day, endingOn: now, calendar: calendar), records: records, drops: drops,
                               history: history)
        #expect(today.items == 5 && today.itemChange == 2 && !today.itemComparisonUnavailable)
        let oldest = statistics(.preset(.day, endingOn: day(1), calendar: calendar), records: records, drops: drops,
                                history: history)
        #expect(oldest.itemChange == nil && oldest.itemComparisonUnavailable)
        let all = statistics(.all, records: records, drops: drops, history: history)
        #expect(all.itemChange == nil && !all.itemComparisonUnavailable)
        // Nothing at all the day before, which is kept in full: a measured
        // zero, so "Up 1 item from Yesterday".
        let gap = statistics(.preset(.day, endingOn: day(0), calendar: calendar), records: [hack("c", at: day(0))],
                             drops: [], history: history)
        #expect(gap.itemChange == 1)
        // A hack the day before whose gear wasn't read: its items are
        // unknown, so no line rather than one against a made-up zero.
        var unread = hack("u", at: day(1))
        unread.gear = HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .notRead(reason: "timedOut"))
        let unknown = statistics(.preset(.day, endingOn: day(0), calendar: calendar),
                                 records: [hack("c", at: day(0)), unread], drops: [], history: history)
        #expect(unknown.itemChange == nil && unknown.change?.hacks == 0)
    }

    @Test("A hack's gear read is a drop: hacks alone fill Items dropped and compare")
    func hackGearIsADrop() {
        let records = [hack("a", at: day(0), items: 5), hack("b", at: day(0, hour: 14), items: 3),
                       hack("c", at: day(1), items: 4)]
        let history = StatisticsHistory(records: records, drops: [], keepsResults: true, now: now, calendar: calendar)
        let today = statistics(.preset(.day, endingOn: now, calendar: calendar), records: records, drops: [],
                               history: history)
        #expect(today.drops == 0 && today.dropsRead == 2 && today.items == 8)
        #expect(today.itemsPerDrop == 4 && today.itemChange == 4)
    }

    @Test("Item buckets add up to the total, by hour for a day and by day for longer")
    func itemBuckets() {
        let (records, drops) = history
        let week = statistics(.preset(.sevenDays, endingOn: now, calendar: calendar), records: records, drops: drops)
        #expect(!week.hourly && week.itemBuckets.count == 7)
        #expect(week.itemBuckets.map(\.items).reduce(0, +) == week.items)
        let today = statistics(.preset(.day, endingOn: now, calendar: calendar), records: records, drops: drops)
        #expect(today.hourly && today.itemBuckets.count == 2)
        #expect(today.itemBuckets.map(\.items).reduce(0, +) == today.items)
    }

    @Test("Comparison sentences name the interval before as the date line does")
    func comparisonWords() {
        #expect(StatisticsRangeText.change("2", sign: 1, previous: "Yesterday") == "Up 2 from Yesterday")
        #expect(StatisticsRangeText.itemChange(-30, previous: "Oct 13 – 19") == "Down 30 items from Oct 13 – 19")
        #expect(StatisticsRangeText.itemChange(0, previous: "Yesterday") == "Same as Yesterday")
        let history = keptHistory(now: now)
        #expect(StatisticsRangeText.previous(.preset(.day, endingOn: now, calendar: calendar), history: history,
                                             calendar: calendar) == "Yesterday")
    }

    // MARK: - Rev 3 corrections (Colo msg 783, Camo msg 782)

    @Test("Last 3 hours compares with the 3 hours before it: kept and empty is a measured zero")
    func quickComparisonAgainstEmptyWindow() throws {
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-10800), until: oddNow)!
        let records = [hack("a", at: oddNow.addingTimeInterval(-18 * 60), items: 3),
                       hack("b", at: oddNow.addingTimeInterval(-74 * 60), items: 2),
                       hack("old", at: day(11))]
        let history = StatisticsHistory(records: records, drops: [], keepsResults: true, now: oddNow, calendar: calendar)
        #expect(history.hacksComparable(range, calendar: calendar) && history.dropsComparable(range, calendar: calendar))
        let shown = HackStatistics(records: records, drops: [], range: range, history: history, now: oddNow,
                                   calendar: calendar)
        #expect(shown.hacks == 2 && shown.items == 5)
        #expect(shown.previousHacks == 0 && !shown.comparisonUnavailable && !shown.itemComparisonUnavailable)
        let change = try #require(shown.change)
        #expect(change.hacks == 2 && change.hacking == nil && change.speed == nil && change.accepted == nil)
        #expect(shown.itemChange == 5)
        // The window compared with is the 3 hours just before, as times only.
        let previous = try #require(StatisticsRangeText.previous(range, history: history, calendar: calendar))
        #expect(previous.contains(":41"))
        #expect(StatisticsRangeText.itemChange(5, previous: previous) == "Up 5 items from \(previous)")
        #expect(StatisticsRangeText.change("2", sign: 1, previous: previous) == "Up 2 from \(previous)")
        // A hack in the window before: compared with it, bonuses too.
        let busier = records + [hack("c", at: oddNow.addingTimeInterval(-4 * 3_600), items: 9)]
        let compared = HackStatistics(records: busier, drops: [], range: range, history: history, now: oddNow,
                                      calendar: calendar)
        #expect(compared.previousHacks == 1 && compared.change?.hacks == 1 && compared.change?.hacking == 0)
        #expect(compared.itemChange == -4)
    }

    @Test("Last 3 hours reaching before the hacks kept says unavailable, not Up from zero")
    func quickComparisonBeforeHistory() {
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-10800), until: oddNow)!
        // The oldest hack is an hour ago, so the 3 hours before aren't kept.
        let records = [hack("a", at: oddNow.addingTimeInterval(-3_600))]
        let history = StatisticsHistory(hacks: .init(oldestDay: day(0, hour: 0), oldest: oddNow.addingTimeInterval(-3_600),
                                                     mayBeTrimmed: true),
                                        drops: .init(oldestDay: day(0, hour: 0), mayBeTrimmed: true),
                                        newestDay: nil, now: oddNow, calendar: calendar)
        let shown = HackStatistics(records: records, drops: [], range: range, history: history, now: oddNow,
                                   calendar: calendar)
        #expect(shown.change == nil && shown.comparisonUnavailable && shown.previousHacks == nil)
        #expect(shown.itemChange == nil && shown.itemComparisonUnavailable)
    }

    @Test("A record exactly at a Last… choice's end belongs to the next window")
    func quickEndExcluded() throws {
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-3 * 3_600), until: oddNow)
        let window = try #require(range)
        #expect(!window.contains(oddNow) && window.contains(oddNow.addingTimeInterval(-3 * 3_600)))
        #expect(window.shifted(by: 1, calendar: calendar)?.contains(oddNow) == true)
    }

    @Test("Hacks and drops exactly at the start count; exactly at the end don't, in totals and bars")
    func recordsAtTheEnds() {
        let start = oddNow.addingTimeInterval(-3 * 3_600)
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-10800), until: oddNow)!
        let records = [hack("start", at: start, items: 2), hack("end", at: oddNow, items: 7)]
        let drops = [drop("start", at: start, items: 3), drop("end", at: oddNow, items: 11)]
        let shown = HackStatistics(records: records, drops: drops, range: range, history: nil, now: oddNow,
                                   calendar: calendar)
        #expect(shown.hacks == 1 && shown.drops == 1)
        #expect(shown.items == 2 + 3)
        // The hourly bars hold the start's items and none of the end's.
        #expect(shown.itemBuckets.reduce(0) { $0 + $1.items } == 2 + 3)
        // A whole day ends at the next midnight, which is the next day's.
        let today = StatisticsRange.preset(.day, endingOn: now, calendar: calendar)
        let midnight = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let day = statistics(today, records: [hack("m", at: midnight), hack("n", at: nextMidnight)],
                             drops: [drop("m", at: midnight), drop("n", at: nextMidnight)])
        #expect(day.hacks == 1 && day.drops == 1)
    }

    func kindsHack(_ id: String, at date: Date, _ kinds: [(String, Int)]) -> HackResultRecord {
        var record = hack(id, at: date)
        let entries = kinds.enumerated().map { index, kind in
            GearDropEntry(column: index % 4, row: index / 4, item: kind.0, levelState: .known, level: 8,
                          quantity: kind.1, rarity: nil, multiplied: false)
        }
        let summary = GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: 1,
                                      association: .ordered,
                                      panels: [.init(stage: .portal, entries: entries, partial: false),
                                               .init(stage: .bonus, entries: [], partial: false)])
        record.gear = HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .read(summary))
        return record
    }

    @Test("Other counts the items left out, not the kinds, and is gone with five kinds or fewer")
    func otherSlotCountsItems() {
        let today = StatisticsRange.preset(.day, endingOn: now, calendar: calendar)
        let six = kindsHack("six", at: day(0), [("Resonator", 30), ("Power Cube", 20), ("XMP Burster", 15),
                                               ("Portal Key", 12), ("Portal Shield", 14), ("Heat Sink", 1)])
        let row = statistics(today, records: [six], drops: []).gearRow
        #expect(row.shown.map(\.item) == ["Resonator", "Power Cube", "XMP Burster", "Portal Shield"])
        // Portal Key 12 and Heat Sink 1: 13 items in two kinds.
        #expect(row.other == 13)
        #expect(row.shown.map(\.total).reduce(0, +) + row.other == 92)
        let five = kindsHack("five", at: day(0), [("Resonator", 3), ("Power Cube", 2), ("XMP Burster", 1),
                                                 ("Portal Key", 1), ("Heat Sink", 1)])
        let fiveRow = statistics(today, records: [five], drops: []).gearRow
        #expect(fiveRow.shown.count == 5 && fiveRow.other == 0)
        #expect(StatisticsRangeText.otherItems(13) == "13 other items")
    }

    static let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/Resources/Localizable.xcstrings")

    @Test("The spoken Other slot is plural by items in English and one form in ja/zh, as copy-rev3 words it",
          .enabled(if: FileManager.default.fileExists(atPath: catalog.path)))
    func otherSlotPlural() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        let entry = try #require(strings["%lld other items"])
        let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
        let plural = (localizations["en"]?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
        func value(_ unit: [String: Any]?) -> String? { (unit?["stringUnit"] as? [String: Any])?["value"] as? String }
        let one = try #require(value(plural?["one"])), other = try #require(value(plural?["other"]))
        #expect(String(format: one, 1) == "1 other item")
        #expect(String(format: other, 15) == "15 other items")
        #expect(value(localizations["ja"]) == "その他のアイテム%lld個")
        #expect(value(localizations["zh-Hans"]) == "其他 %lld 件物品")
        #expect(value(localizations["zh-Hant"]) == "其他 %lld 件物品")
    }

    @Test("Last 3 hours keeps whole clock hours, and its first and last bars say the part they cover")
    func partialHourSlots() throws {
        let range = StatisticsRange.timed(from: oddNow.addingTimeInterval(-10800), until: oddNow)!
        let interval = try #require(range.interval)
        let records = [hack("late", at: oddNow.addingTimeInterval(-60), items: 4)]
        let shown = HackStatistics(records: records, drops: [], range: range, history: keptHistory(now: oddNow),
                                   now: oddNow, calendar: calendar)
        let domain = try #require(shown.hours)
        let slots = HackStatistics.itemSlots(buckets: shown.itemBuckets, domain: domain, range: interval,
                                             unit: .hour, calendar: calendar)
        #expect(slots.map(\.start) == (14...17).map { date(2026, 10, 20, $0) })
        #expect(slots.first?.span == interval.lowerBound..<date(2026, 10, 20, 15))
        #expect(slots[1].span == date(2026, 10, 20, 15)..<date(2026, 10, 20, 16))
        #expect(slots.last?.span == date(2026, 10, 20, 17)..<oddNow)
        #expect(slots.map(\.items) == [0, 0, 0, 4])
        #expect(slots.map(\.items).reduce(0, +) == shown.items)
        let labels = slots.map { StatisticsRangeText.slotSpan($0, hourly: true, withDate: false, now: oddNow,
                                                              calendar: calendar) }
        // "2:41 – 3:00 PM", "3 – 4 PM", "4 – 5 PM", "5:00 – 5:41 PM".
        #expect(labels[0].contains(":41") && labels[3].contains(":41"))
        #expect(!labels[1].contains(":41") && !labels[2].contains(":41"))
        #expect(StatisticsRangeText.items(0) == "0 items")
    }

    @Test("A day's last hourly bar reads like the others, times only: 11 PM – 12 AM")
    func lastHourOfDayLabel() {
        let lastHour = HackStatistics.ItemSlot(start: date(2026, 10, 20, 23),
                                               span: date(2026, 10, 20, 23)..<date(2026, 10, 21), items: 0)
        let label = StatisticsRangeText.slotSpan(lastHour, hourly: true, withDate: false, now: now, calendar: calendar)
        #expect(!label.contains("Oct") && !label.contains("2026") && !label.contains("/")
                && !label.lowercased().contains("midnight"), "\(label)")
        let span = date(2026, 10, 20, 23)..<date(2026, 10, 21)
        let en = StatisticsRangeText.timesOnly(span, template: "j", calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(en == "11\u{202F}PM\u{2009}–\u{2009}12\u{202F}AM" || en == "11 PM – 12 AM", "\(en)")
        let en24 = StatisticsRangeText.timesOnly(span, template: "j", calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(en24.hasPrefix("23") && en24.hasSuffix("00") && !en24.contains("Oct"), "\(en24)")
        for id in ["ja_JP", "zh_Hans_CN", "zh_Hant_TW"] {
            let text = StatisticsRangeText.timesOnly(span, template: "j", calendar: calendar, locale: Locale(identifier: id))
            #expect(!text.contains("10") && !text.contains("2026") && !text.contains("/"), "\(id): \(text)")
        }
        // A chart over two dates keeps the dates.
        let dated = StatisticsRangeText.slotSpan(lastHour, hourly: true, withDate: true, now: now, calendar: calendar)
        #expect(dated.contains("Oct 20") && dated.contains("Oct 21"), "\(dated)")
        let earlier = HackStatistics.ItemSlot(start: date(2026, 10, 20, 22),
                                              span: date(2026, 10, 20, 22)..<date(2026, 10, 20, 23), items: 0)
        #expect(!StatisticsRangeText.slotSpan(earlier, hourly: true, withDate: false, now: now, calendar: calendar)
            .contains("Oct"))
    }

    @Test("Slots before the drops kept are left out; a timed range over days has partial first and last days")
    func slotEdges() throws {
        let start = date(2026, 10, 14, 16, 30), end = date(2026, 10, 18, 9, 15)
        let range = try #require(StatisticsRange.timed(from: start, until: end))
        let domain = date(2026, 10, 14)..<date(2026, 10, 19)
        let slots = HackStatistics.itemSlots(buckets: [], domain: domain, range: range.interval, unit: .day,
                                             calendar: calendar)
        #expect(slots.count == 5 && slots.first?.span == start..<date(2026, 10, 15) && slots.last?.span == date(2026, 10, 18)..<end)
        let first = StatisticsRangeText.slotSpan(slots[0], hourly: false, withDate: false, now: now, calendar: calendar)
        let middle = StatisticsRangeText.slotSpan(slots[1], hourly: false, withDate: false, now: now, calendar: calendar)
        #expect(first.contains(":30") && !middle.contains(":"))
        let kept = HackStatistics.itemSlots(buckets: [], domain: domain, range: range.interval, unit: .day,
                                            historyStart: date(2026, 10, 16), calendar: calendar)
        #expect(kept.map(\.start) == [date(2026, 10, 16), date(2026, 10, 17), date(2026, 10, 18)])
    }

    @Test("Export stays on the toolbar, off on an empty range; Select goes")
    func toolbarOnEmptyRange() {
        let empty = StatisticsToolbarState(shownEntries: 0, selecting: false)
        #expect(empty.showsExport && !empty.exportEnabled && !empty.showsSelect)
        let some = StatisticsToolbarState(shownEntries: 3, selecting: false)
        #expect(some.showsExport && some.exportEnabled && some.showsSelect)
        let selecting = StatisticsToolbarState(shownEntries: 3, selecting: true)
        #expect(!selecting.showsExport && selecting.showsSelect)
    }

    @Test("No hacks in this period only for kept, loaded days: not before history, unsaved or failed")
    func emptyReasons() throws {
        let records = [hack("h", at: day(3))]
        let drops = [drop("d", at: day(9))]
        let history = StatisticsHistory(records: records, drops: drops, keepsResults: true, now: now, calendar: calendar)
        let kept = StatisticsRange.preset(.day, endingOn: day(1), calendar: calendar)
        #expect(StatisticsEmptyReason(range: kept, stream: history.hacks, history: history, keepsResults: true,
                                      storeProblem: false) == .noRecords)
        // Six days ago: drops are kept from nine days ago, hacks only from three.
        let early = StatisticsRange.preset(.day, endingOn: day(6), calendar: calendar)
        #expect(StatisticsEmptyReason(range: early, stream: history.hacks, history: history, keepsResults: true,
                                      storeProblem: false) == .beforeHistory)
        #expect(StatisticsEmptyReason(range: early, stream: history.drops, history: history, keepsResults: true,
                                      storeProblem: false) == .noRecords)
        #expect(StatisticsEmptyReason(range: kept, stream: history.hacks, history: history, keepsResults: true,
                                      storeProblem: true) == .unavailable)
        let nothing = StatisticsHistory(records: [], drops: [], keepsResults: true, now: now, calendar: calendar)
        #expect(StatisticsEmptyReason(range: kept, stream: nil, history: nothing, keepsResults: true,
                                      storeProblem: false) == .nothingSaved)
        // Saving off: this run began with a hack an hour ago.
        let run = StatisticsHistory(records: [hack("r", at: now.addingTimeInterval(-3_600))], drops: [],
                                    keepsResults: false, now: now, calendar: calendar)
        let lastHour = StatisticsRange.preset(.lastHour, endingOn: now, calendar: calendar)
        let lastDay = StatisticsRange.preset(.last24Hours, endingOn: now, calendar: calendar)
        #expect(StatisticsEmptyReason(range: lastHour, stream: run.hacks, history: run, keepsResults: false,
                                      storeProblem: false) == .noRecords)
        #expect(StatisticsEmptyReason(range: lastDay, stream: run.hacks, history: run, keepsResults: false,
                                      storeProblem: false) == .notKept)
    }

    @Test("The period path the Home card and widget use is unchanged by ranges")
    func periodPathUnchanged() {
        let (records, drops) = history
        let period = HackStatistics(records: records, drops: drops, period: .week, now: now, calendar: calendar)
        let range = statistics(.preset(.sevenDays, endingOn: now, calendar: calendar), records: records, drops: drops)
        #expect(period.hacks == range.hacks && period.items == range.items && period.chartDays == range.chartDays)
        #expect(period.bonusPoints == range.bonusPoints)
    }
}
