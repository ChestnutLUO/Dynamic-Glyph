import Foundation
import Testing
import GlyphRecognition

/// The Home Screen Summary widget's figures, from the file the app writes,
/// against the Statistics page's on the same saved results.
@MainActor
@Suite("Summary widget")
struct StatisticsWidgetSummaryTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Noon, so a few hours either side stays within the day.
    let now = Date(timeIntervalSince1970: 20_833 * 86_400 + 43_200)

    func record(_ id: String, daysAgo: Double, hacking: Int? = 100, speed: Int? = 50,
                slots: [HackResultSummary.Slot] = [], input: Double? = nil,
                gear: HackGearAttachment.Reading? = nil) -> HackResultRecord {
        HackResultRecord(id: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                         summary: HackResultSummary(captureSessionID: 1, hackID: 1, state: .complete, isClosed: true,
                                                    closeReason: "panelLeft",
                                                    hackingBonus: hacking.map { .init(percent: $0, isFinal: true) },
                                                    speedBonus: speed.map { .init(percent: $0, isFinal: true) },
                                                    slots: slots, inputSeconds: input),
                         gear: gear.map { HackGearAttachment(captureSessionID: 1, hackID: 1, reading: $0) })
    }

    func glyphs(_ count: Int, accepted: Int? = nil) -> [HackResultSummary.Slot] {
        (0..<count).map {
            .init(glyph: "xm", outcome: $0 < (accepted ?? count) ? .accepted : .rejected, check: .matched,
                  comparison: .agreement)
        }
    }

    func entry(_ item: String?, level: Int? = nil, quantity: Int, multiplied: Bool? = nil) -> GearDropEntry {
        .init(column: 0, row: 0, item: item, levelState: level == nil ? .notApplicable : .known, level: level,
              quantity: quantity, multiplied: multiplied)
    }

    func gear(_ portal: [GearDropEntry], _ bonus: [GearDropEntry]?, partial: Bool = false) -> HackGearAttachment.Reading {
        var panels = [GearDropSummary.Panel(stage: .portal, entries: portal, partial: partial)]
        if let bonus { panels.append(.init(stage: .bonus, entries: bonus, partial: false)) }
        return .read(GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: 1,
                                     association: .ordered, panels: panels))
    }

    func dropRecord(_ id: String, daysAgo: Double, _ entries: [GearDropEntry]) -> GearDropRecord {
        let summary = GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: nil,
                                      association: .noWaitingHack,
                                      panels: [.init(stage: .portal, entries: entries, partial: false)])
        return GearDropRecord(id: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                              drop: GearDrop(captureSessionID: 1, summary: summary))
    }

    /// Hacks of two lengths over 60 days, read, unread and not kept gear,
    /// and drops no hack claimed, one on a day without hacks.
    var fixtureRecords: [HackResultRecord] {
        [
            record("a", daysAgo: 0, hacking: 150, speed: 40, slots: glyphs(3), input: 6.3,
                   gear: gear([entry("Resonator", level: 8, quantity: 2), entry("Portal Key", quantity: 1)],
                              [entry("Resonator", level: 8, quantity: 3, multiplied: true)])),
            record("b", daysAgo: 0.3, hacking: 90, slots: glyphs(5, accepted: 4), input: 10,
                   gear: .notRead(reason: "resultTimeout")),
            record("c", daysAgo: 1, hacking: 80, slots: glyphs(5), input: 15,
                   gear: gear([entry("XMP Burster", level: 7, quantity: 4)], nil, partial: true)),
            record("d", daysAgo: 3, hacking: 120, slots: glyphs(3)),
            record("e", daysAgo: 6.4, speed: nil, slots: glyphs(4, accepted: 2), input: 9.7),
            record("f", daysAgo: 7, hacking: 110, slots: glyphs(3), input: 5),
            record("g", daysAgo: 10, hacking: 90, slots: glyphs(5)),
            record("h", daysAgo: 13, hacking: 60),
            record("i", daysAgo: 20, slots: glyphs(3),
                   gear: gear([entry("Power Cube", level: 6, quantity: 2)], [entry("Power Cube", level: 6, quantity: 1)])),
            record("j", daysAgo: 60, hacking: 200),
            HackResultRecord(id: "unknown format", date: now, summary: nil),
        ]
    }

    var fixtureDrops: [GearDropRecord] {
        [
            dropRecord("d1", daysAgo: 0, [entry("Resonator", level: 8, quantity: 1), entry(nil, quantity: 2)]),
            dropRecord("d2", daysAgo: 2, [entry("Portal Shield", quantity: 2)]),
            dropRecord("d3", daysAgo: 12, [entry("XMP Burster", level: 8, quantity: 5)]),
            dropRecord("d4", daysAgo: 30, [entry("Portal Key", quantity: 3)]),
            GearDropRecord(id: "unknown drop", date: now, drop: nil),
        ]
    }

    /// Every number the summary card, its chart, gear strip and gear sheet show.
    func expectSame(_ widget: StatisticsFigures, _ app: HackStatistics, _ label: String) {
        let parts = widget.parts, tally = parts.tally
        #expect(widget.hacks == app.hacks, "hacks, \(label)")
        #expect(widget.drops == app.drops, "drops, \(label)")
        #expect(widget.items == app.items, "items, \(label)")
        #expect(parts.bonusItems == app.bonusItems, "bonus items, \(label)")
        #expect(parts.multipliedItems == app.multipliedItems, "multiplied, \(label)")
        #expect(tally.averageHacking == app.averageHackingBonus, "Avg. Hacking, \(label)")
        #expect(tally.bestHacking == app.bestHackingBonus, "best Hacking, \(label)")
        #expect(tally.averageSpeed == app.averageSpeedBonus, "Avg. Speed, \(label)")
        #expect(tally.acceptedPercent == app.acceptedPercent, "Accepted, \(label)")
        #expect(tally.secondsPerGlyph == app.secondsPerGlyph, "Sec/Glyph, \(label)")
        #expect(widget.change == app.change, "change, \(label)")
        #expect(widget.bonusPoints == app.bonusPoints, "bonus points, \(label)")
        #expect(widget.chartDays == app.chartDays, "chart days, \(label)")
        #expect(widget.lengths == app.lengths && widget.mixesLengths == app.mixesLengths,
                "lengths, \(label)")
        #expect(widget.lengthRows == app.lengthRows, "length rows, \(label)")
        #expect(widget.lengthAverages == app.lengthAverages, "length chart, \(label)")
        #expect(widget.gear == app.gear, "gear by type, \(label)")
        #expect(widget.itemsPerDrop == app.itemsPerDrop, "per drop, \(label)")
        #expect(parts.gearComplete == app.gearComplete && parts.gearPartial == app.gearPartial
                    && parts.gearNotRead == app.gearNotRead && parts.gearNotKept == app.gearNotKept,
                "gear coverage, \(label)")
        #expect(widget.hasGear == app.hasGear && widget.onlyDrops == app.onlyDrops
                    && widget.gearIncomplete == app.gearIncomplete, "gear flags, \(label)")
        #expect(parts.resultsComplete == app.resultsComplete && parts.resultsPartial == app.resultsPartial
                    && parts.resultsNotSeen == app.resultsNotSeen, "results, \(label)")
    }

    @Test("Each period's figures equal the Statistics page's, now and at every midnight of the timeline")
    func matchesStatistics() throws {
        let records = fixtureRecords, drops = fixtureDrops
        let written = StatisticsWidgetSummary(records: records, drops: drops, now: now, calendar: calendar)
        // What the widget reads back from the file.
        let summary = try JSONDecoder().decode(StatisticsWidgetSummary.self, from: written.encoded())
        #expect(summary == written)
        for date in StatisticsWidgetSummary.timelineDates(now: now, calendar: calendar) {
            for period in StatisticsPeriod.allCases {
                expectSame(summary.figures(period, at: date, calendar: calendar),
                           HackStatistics(records: records, drops: drops, period: period, now: date, calendar: calendar),
                           "\(period) at \(date)")
            }
        }
        // The fixtures do exercise each part.
        let today = summary.figures(.today, at: now, calendar: calendar)
        #expect(today.hacks == 2 && today.drops == 1 && today.items == 7 && today.parts.bonusItems == 3)
        #expect(today.change != nil && today.mixesLengths)
        let week = summary.figures(.week, at: now, calendar: calendar)
        #expect(week.hacks == 5 && week.drops == 2 && week.change?.hacks == 2 && week.bonusPoints.count == 4)
        let all = summary.figures(.all, at: now, calendar: calendar)
        #expect(all.hacks == 10 && all.drops == 4 && all.change == nil)
    }

    @Test("Only 15 days are kept by day; All is merged in the file, with its chart points")
    func storedDays() throws {
        let summary = StatisticsWidgetSummary(records: fixtureRecords, drops: fixtureDrops, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        #expect(summary.coverageStart == today.addingTimeInterval(-14 * 86_400))
        #expect(summary.days.allSatisfy { $0.start >= summary.coverageStart })
        #expect(summary.days.map(\.start) == summary.days.map(\.start).sorted())
        #expect(summary.days.count == 9, "Only days with hacks or drops")
        #expect(summary.all.tally.hacks == 10 && summary.all.drops == 4)
        #expect(summary.allPoints.count == 9)
    }

    @Test("A day before the stored days has no change rather than a wrong one")
    func clockSetBack() {
        let summary = StatisticsWidgetSummary(records: fixtureRecords, drops: fixtureDrops, now: now, calendar: calendar)
        let earlier = now.addingTimeInterval(-2 * 86_400)
        // 7 days then compares with days from before the file's first.
        #expect(summary.figures(.week, at: earlier, calendar: calendar).change == nil)
        #expect(summary.figures(.today, at: earlier, calendar: calendar).change != nil)
    }

    @Test("Hacks whose gear wasn't read have unknown items, not zero; a reading of nothing is a zero")
    func unknownGear() {
        let notRead = StatisticsWidgetSummary(records: [record("a", daysAgo: 0, gear: .notRead(reason: "resultTimeout")),
                                                        record("b", daysAgo: 0)],
                                              drops: [], now: now, calendar: calendar)
            .figures(.today, at: now, calendar: calendar)
        #expect(notRead.hacks == 2 && notRead.hasGear && !notRead.hasGearReading)
        #expect(notRead.parts.gearNotRead == 1 && notRead.parts.gearNotKept == 1 && notRead.itemsPerDrop == nil)
        let notKept = StatisticsWidgetSummary(records: [record("b", daysAgo: 0)], drops: [], now: now, calendar: calendar)
            .figures(.today, at: now, calendar: calendar)
        #expect(!notKept.hasGear && !notKept.hasGearReading)
        let nothing = StatisticsWidgetSummary(records: [record("c", daysAgo: 0, gear: gear([], []))], drops: [],
                                              now: now, calendar: calendar)
            .figures(.today, at: now, calendar: calendar)
        #expect(nothing.hasGearReading && nothing.items == 0 && nothing.itemsPerDrop == 0)
    }

    @Test("Drops without a hack count as drops and items, never as hacks")
    func dropsOnly() {
        let drops = fixtureDrops
        let summary = StatisticsWidgetSummary(records: [], drops: drops, now: now, calendar: calendar)
        let week = summary.figures(.week, at: now, calendar: calendar)
        #expect(week.onlyDrops && week.hacks == 0 && week.drops == 2 && week.items == 3 && week.hasGearReading)
        expectSame(week, HackStatistics(records: [], drops: drops, period: .week, now: now, calendar: calendar), "week")
    }

    @Test("With nothing saved every period is zero, as on Statistics")
    func empty() {
        for period in StatisticsPeriod.allCases {
            let app = HackStatistics(records: [], period: period, now: now, calendar: calendar)
            let empty = StatisticsWidgetSummary.empty.figures(period, at: now, calendar: calendar)
            #expect(empty.hacks == 0 && empty.drops == 0 && empty.items == 0 && !empty.hasGearReading)
            expectSame(empty, app, "empty summary, \(period)")
            expectSame(StatisticsWidgetSummary(records: [], drops: [], now: now, calendar: calendar)
                .figures(period, at: now, calendar: calendar), app, "nothing saved, \(period)")
        }
    }

    @Test("No file, an unreadable one or one of another version is unavailable, not zeros; a summary of nothing is zeros")
    func unavailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StatisticsWidgetSummary.load(from: nil) == nil, "No App Group")
        #expect(StatisticsWidgetSummary.load(from: url) == nil, "No file yet")
        try Data("not a summary".utf8).write(to: url)
        #expect(StatisticsWidgetSummary.load(from: url) == nil, "Garbage")
        var other = StatisticsWidgetSummary.empty
        other.version += 1
        try other.encoded().write(to: url)
        #expect(StatisticsWidgetSummary.load(from: url) == nil, "Another version")
        // Written by the app with nothing saved: read, and every period zero.
        try StatisticsWidgetSummary(records: [], drops: [], now: now, calendar: calendar).encoded().write(to: url)
        let read = try #require(StatisticsWidgetSummary.load(from: url))
        #expect(read.figures(.all, at: now, calendar: calendar).hacks == 0)
    }

    @Test("The timeline is now, then each of the next seven local midnights")
    func timeline() {
        let dates = StatisticsWidgetSummary.timelineDates(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        #expect(dates.first == now && dates.count == 8)
        #expect(Array(dates.dropFirst()) == (1...7).map { today.addingTimeInterval(Double($0) * 86_400) })
        // Today and 7 days move on at those midnights.
        let summary = StatisticsWidgetSummary(records: fixtureRecords, drops: [], now: now, calendar: calendar)
        #expect(summary.figures(.today, at: dates[1], calendar: calendar).hacks == 0)
        #expect(summary.figures(.week, at: dates[7], calendar: calendar).hacks == 0)
    }

    @Test("Where a clock change skips midnight, that day starts at 1:00 and the next ones at midnight again")
    func timelineAcrossSkippedMidnight() throws {
        var chile = Calendar(identifier: .gregorian)
        chile.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        // Noon, Friday 4 September 2026: clocks go from 0:00 to 1:00 on Sunday the 6th.
        let friday = try #require(chile.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12)))
        let dates = StatisticsWidgetSummary.timelineDates(now: friday, calendar: chile)
        #expect(dates.count == 8)
        let starts = dates.dropFirst().map { chile.dateComponents([.day, .hour], from: $0) }
        #expect(starts.map(\.day) == [5, 6, 7, 8, 9, 10, 11])
        #expect(starts.map(\.hour) == [0, 1, 0, 0, 0, 0, 0])
    }

    @Test("Today and 7 days are known only in the time zone the days were cut in, or one with the same midnights")
    func knowsDaysAcrossZones() throws {
        let summary = StatisticsWidgetSummary(records: fixtureRecords, drops: [], now: now, calendar: calendar)
        #expect(summary.timeZone == calendar.timeZone.identifier)
        #expect(summary.knowsDays(at: now, calendar: calendar))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(!summary.knowsDays(at: now, calendar: tokyo))
        // London is on UTC in January, so the same midnights.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        #expect(summary.knowsDays(at: now, calendar: london))
        // A file from before the zone was written is taken to be the widget's.
        var older = summary
        older.timeZone = nil
        #expect(older.knowsDays(at: now, calendar: tokyo))
    }

    @Test("The small widget's button cycles Today, 7 days, All")
    func cycle() {
        #expect(StatisticsPeriod.today.next == .week && StatisticsPeriod.week.next == .all
                    && StatisticsPeriod.all.next == .today)
    }

    @Test("A tap on the widget opens Statistics on its period; other links are not the app's")
    func link() throws {
        #expect(AppLink.statistics(nil).url.absoluteString == "dynamicglyph://statistics")
        #expect(AppLink.statistics(.today).url.absoluteString == "dynamicglyph://statistics?period=today")
        #expect(AppLink.statistics(.week).url.absoluteString == "dynamicglyph://statistics?period=week")
        #expect(AppLink.statistics(.all).url.absoluteString == "dynamicglyph://statistics?period=all")
        for period in [nil] + StatisticsPeriod.allCases.map(Optional.some) {
            #expect(AppLink(url: AppLink.statistics(period).url) == .statistics(period), "\(String(describing: period))")
        }
        func link(_ string: String) throws -> AppLink? { AppLink(url: try #require(URL(string: string))) }
        #expect(try link("DynamicGlyph://Statistics?Period=WEEK") == .statistics(.week))
        #expect(try link("dynamicglyph://statistics?period=month") == .statistics(nil),
                "A period this build doesn't know still opens Statistics")
        #expect(try link("dynamicglyph://statistics?other=1&period=all") == .statistics(.all))
        #expect(try link("dynamicglyph://settings") == nil)
        #expect(try link("dynamicglyph://settings?period=week") == nil)
        #expect(try link("https://statistics?period=week") == nil)
    }

    @Test("The items line drops the multiplied items, then per drop, never the items")
    func itemsLine() {
        let figures = StatisticsWidgetSummary(records: fixtureRecords, drops: fixtureDrops, now: now, calendar: calendar)
            .figures(.today, at: now, calendar: calendar)
        let app = HackStatistics(records: fixtureRecords, drops: fixtureDrops, period: .today, now: now, calendar: calendar)
        #expect(GearSummary.line(figures) == GearSummary.line(app), "The widget's line is the app's")
        #expect(figures.multipliedItems > 0 && figures.itemsPerDrop != nil)
        let full = GearSummary.line(figures)
        let noMultiplied = GearSummary.line(figures, multiplied: false)
        let itemsOnly = GearSummary.line(figures, perDrop: false, multiplied: false)
        #expect(full.hasPrefix(noMultiplied) && noMultiplied.hasPrefix(itemsOnly) && full != noMultiplied
                    && noMultiplied != itemsOnly)
        #expect(!itemsOnly.contains("·"))
    }

    @Test("A file of another version, or not a summary, is not read")
    func fileVersions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var summary = StatisticsWidgetSummary(records: fixtureRecords, drops: fixtureDrops, now: now, calendar: calendar)
        try summary.encoded().write(to: url)
        #expect(StatisticsWidgetSummary.read(from: url) == summary)
        summary.version = StatisticsWidgetSummary.currentVersion + 1
        try summary.encoded().write(to: url)
        #expect(StatisticsWidgetSummary.read(from: url) == nil)
        try Data("{}".utf8).write(to: url)
        #expect(StatisticsWidgetSummary.read(from: url) == nil)
        #expect(try summary.encoded() == summary.encoded(), "The same summary, the same bytes")
    }

    // MARK: - Publishing

    @Test("A summary is written and the widget reloaded once; the same bytes again are skipped")
    func publisher() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var reloads = 0
        let publisher = SummaryWidgetPublisher(url: url) { reloads += 1 }
        let summary = StatisticsWidgetSummary(records: fixtureRecords, drops: [], now: now, calendar: calendar)
        publisher.publish(summary)
        publisher.publish(summary)
        #expect(reloads == 1 && StatisticsWidgetSummary.read(from: url) == summary)
        publisher.publish(.empty)
        #expect(reloads == 2 && StatisticsWidgetSummary.read(from: url) == .empty)
        // Nowhere to write: no file is left that could count a deleted hack.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/SummaryWidget.json")
        var failedReloads = 0
        SummaryWidgetPublisher(url: missing) { failedReloads += 1 }.publish(summary)
        #expect(failedReloads == 1 && !FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("While capturing the file is written every time, but the widget reloaded at most once per interval and at Stop")
    func publisherWhileCapturing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = now, reloads = 0
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let publisher = SummaryWidgetPublisher(url: url, now: { clock }, schedule: { scheduled.append(($0, $1)) }) {
            reloads += 1
        }
        let one = StatisticsWidgetSummary(records: Array(fixtureRecords.prefix(1)), drops: [], now: now,
                                          calendar: calendar)
        let two = StatisticsWidgetSummary(records: Array(fixtureRecords.prefix(2)), drops: [], now: now,
                                          calendar: calendar)
        publisher.isCapturing = true
        publisher.publish(one)
        #expect(reloads == 1, "The first write of a run always reloads")
        clock = now.addingTimeInterval(60)
        publisher.publish(two)
        #expect(reloads == 1 && StatisticsWidgetSummary.read(from: url) == two, "Written, the reload held back")
        #expect(scheduled.count == 1 && abs(scheduled[0].0 - (SummaryWidgetPublisher.captureReloadInterval - 60)) < 0.001)
        clock = now.addingTimeInterval(120)
        publisher.publish(one)
        #expect(reloads == 1 && scheduled.count == 1, "One reload waits, however many writes")
        // The interval ends: the held reload goes.
        clock = now.addingTimeInterval(SummaryWidgetPublisher.captureReloadInterval)
        scheduled[0].1()
        #expect(reloads == 2)
        // A write held back at Stop reloads then.
        clock = clock.addingTimeInterval(30)
        publisher.publish(two)
        #expect(reloads == 2)
        publisher.isCapturing = false
        #expect(reloads == 3)
        // Not capturing, each new write reloads at once.
        publisher.publish(one)
        #expect(reloads == 4)
        // Forced, as after a time zone change, even the same bytes reload while capturing.
        publisher.isCapturing = true
        publisher.publish(one, force: true)
        #expect(reloads == 5)
    }

    private func summary(hack: Int) -> HackResultSummary {
        HackResultSummary(captureSessionID: 1, hackID: hack, state: .complete, isClosed: true, closeReason: "panelLeft",
                          hackingBonus: .init(percent: 120, isFinal: true), speedBonus: .init(percent: 49, isFinal: true),
                          slots: [.init(glyph: "help", outcome: .accepted, check: .matched, comparison: .agreement)])
    }

    private func drop(group: Int) -> GearDrop {
        let entry = GearDropEntry(column: 0, row: 0, item: "Power Cube", levelState: .known, level: 7, quantity: 2)
        return GearDrop(captureSessionID: 1, summary: GearDropSummary(
            groupID: group, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: nil,
            association: .noWaitingHack, panels: [.init(stage: .portal, entries: [entry], partial: false)]))
    }

    @Test("The app writes what the store holds after saves, deletions and Clear; unsaved hacks stay out")
    func publishedFromResults() throws {
        let suite = "dynamicglyph-widget-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: AppPreferences(defaults: defaults), store: store,
                                  widget: SummaryWidgetPublisher(url: url) {}, now: { clock })
        func figures(_ period: StatisticsPeriod) throws -> StatisticsFigures {
            try #require(StatisticsWidgetSummary.read(from: url)).figures(period, at: clock)
        }
        #expect(try figures(.all).hacks == 0, "Written at launch")
        results.receive(summary(hack: 1))
        results.receive(summary(hack: 2))
        results.receiveDrop(drop(group: 1))
        #expect(try figures(.today).hacks == 2 && figures(.all).hacks == 2 && figures(.all).drops == 1)
        #expect(try figures(.all).items == 2)
        let deleted = try #require(results.records.first?.id)
        try results.delete(hacks: [deleted], drops: [])
        // All is rebuilt from the store, so the deleted hack leaves nothing.
        #expect(try figures(.today).hacks == 1 && figures(.all).hacks == 1 && figures(.all).drops == 1)
        results.keepsResults = false
        results.receive(summary(hack: 3))
        #expect(try figures(.all).hacks == 1, "A hack not kept isn't there at the next launch either")
        results.clear()
        #expect(try figures(.all).hacks == 0 && figures(.all).drops == 0 && figures(.all).items == 0)
    }
}
