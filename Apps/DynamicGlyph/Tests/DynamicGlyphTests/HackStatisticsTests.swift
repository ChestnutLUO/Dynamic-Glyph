import Foundation
import Testing
import GlyphRecognition

@Suite("Statistics summary")
struct HackStatisticsTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Noon, so a few hours either side stays within the day.
    let now = Date(timeIntervalSince1970: 20_833 * 86_400 + 43_200)

    func record(_ id: String, daysAgo: Double, state: HackResult.State = .complete,
                hacking: HackResultSummary.Bonus? = .init(percent: 100, isFinal: true),
                speed: HackResultSummary.Bonus? = .init(percent: 50, isFinal: true),
                slots: [HackResultSummary.Slot] = [], gear: HackGearAttachment.Reading? = nil,
                input: Double? = nil, portalLevel: Int? = nil,
                commands: HackCommandSummary? = nil) -> HackResultRecord {
        let level = portalLevel.flatMap {
            PortalLevelRules.estimate(screen: PortalScreenEvidence(sourceTime: 0, resonators: Array(repeating: $0, count: 8),
                                                                   unreadSlots: 0, badgeHue: nil),
                                      glyphCount: slots.count)
        }
        let attachment = gear.map { HackGearAttachment(captureSessionID: 1, hackID: 1, reading: $0, portalLevel: level) }
            ?? level.map { HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .notRead(reason: "test"), portalLevel: $0) }
        return HackResultRecord(id: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                                summary: HackResultSummary(captureSessionID: 1, hackID: 1, state: state, isClosed: true,
                                                           closeReason: "panelLeft", hackingBonus: hacking,
                                                           speedBonus: speed, slots: slots, inputSeconds: input,
                                                           commands: commands),
                                gear: attachment)
    }

    func glyphs(_ count: Int, accepted: Int? = nil) -> [HackResultSummary.Slot] {
        (0..<count).map { slot("xm", $0 < (accepted ?? count) ? .accepted : .rejected) }
    }

    func slot(_ glyph: String?, _ outcome: GameSlotOutcome, _ comparison: ValidatorResultComparison.Status = .agreement,
              seconds: Double? = nil) -> HackResultSummary.Slot {
        .init(glyph: glyph, outcome: outcome, check: .matched, comparison: comparison, drawSeconds: seconds)
    }

    func entry(_ item: String?, level: Int? = nil, quantity: Int, rarity: GearDropEntry.Rarity? = nil,
               levelState: GearDropEntry.Level? = nil, multiplied: Bool? = nil) -> GearDropEntry {
        .init(column: 0, row: 0, item: item, levelState: levelState ?? (level == nil ? .notApplicable : .known),
              level: level, quantity: quantity, rarity: rarity, multiplied: multiplied)
    }

    func gear(_ portal: [GearDropEntry], _ bonus: [GearDropEntry]?, partial: Bool = false) -> HackGearAttachment.Reading {
        var panels = [GearDropSummary.Panel(stage: .portal, entries: portal, partial: partial)]
        if let bonus { panels.append(.init(stage: .bonus, entries: bonus, partial: false)) }
        return .read(GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: 1,
                                     association: .ordered, panels: panels))
    }

    @Test("Today starts at midnight, 7 days includes six earlier days, and All includes everything")
    func periods() {
        let records = [record("a", daysAgo: 0), record("b", daysAgo: 0.6), record("c", daysAgo: 6.4),
                       record("d", daysAgo: 7), record("e", daysAgo: 80)]
        let counts = HackStatistics.Period.allCases.map {
            HackStatistics(records: records, period: $0, now: now, calendar: calendar).hacks
        }
        #expect(counts == [1, 3, 5])
    }

    @Test("Only final bonuses are averaged; unread and last-seen values are left out")
    func bonuses() {
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, hacking: .init(percent: 150, isFinal: true), speed: .init(percent: 40, isFinal: true)),
            record("b", daysAgo: 0, hacking: .init(percent: 91, isFinal: true), speed: nil),
            record("c", daysAgo: 0, hacking: .init(percent: 400, isFinal: false), speed: .init(percent: 99, isFinal: false)),
            record("d", daysAgo: 0, state: .notObserved, hacking: nil, speed: nil),
            HackResultRecord(id: "unknown format", date: now, summary: nil),
        ], period: .today, now: now, calendar: calendar)
        #expect(statistics.hacks == 4)
        #expect(statistics.averageHackingBonus == 121)
        #expect(statistics.bestHackingBonus == 150)
        #expect(statistics.averageSpeedBonus == 40)
        #expect(statistics.resultsComplete == 3 && statistics.resultsNotSeen == 1)
        let empty = HackStatistics(records: [], period: .all, now: now, calendar: calendar)
        #expect(empty.averageHackingBonus == nil && empty.acceptedPercent == nil && !empty.hasGear)
    }

    @Test("Each Glyph counts only read verdicts, and takes the median of timed attempts only")
    func glyphs() throws {
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, slots: [slot("help", .accepted, seconds: 1.0), slot("xm", .rejected, .disagreement),
                                            slot("help", .unknown, .unknownGameOutcome, seconds: 9)]),
            record("b", daysAgo: 0, slots: [slot("help", .rejected, seconds: 2.0), slot("help", .accepted),
                                            slot(nil, .accepted, .coverageGap), slot("xm", .accepted, seconds: 0.5),
                                            slot("xm", .accepted, seconds: 0.7), slot("xm", .accepted, seconds: 3.0)]),
        ], period: .today, now: now, calendar: calendar)
        #expect(statistics.glyphsJudged == 8 && statistics.glyphsAccepted == 6 && statistics.acceptedPercent == 75)
        #expect(statistics.glyphs.map(\.glyph) == ["xm", "help"])
        let help = try #require(statistics.glyphs.last)
        #expect(help.judged == 3 && help.accepted == 2 && help.acceptedPercent == 67)
        #expect(help.drawTimes.count == 2 && help.medianDrawSeconds == 1.5)
        let xm = try #require(statistics.glyphs.first)
        #expect(xm.judged == 4 && xm.drawTimes.count == 3 && xm.medianDrawSeconds == 0.7)
        #expect(HackStatistics.GlyphLine(glyph: "now").medianDrawSeconds == nil)
        #expect(statistics.checkAgreements == 6 && statistics.checkDisagreements == 1)
    }

    @Test("Gear groups by item, split by level or rarity, with multiplied drops and coverage")
    func gearTotals() throws {
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, gear: gear([entry("Resonator", level: 8, quantity: 2),
                                                entry("Portal Shield", quantity: 1, rarity: .veryRare),
                                                entry("Portal Key", quantity: 2)],
                                               [entry("Resonator", level: 8, quantity: 3, multiplied: true),
                                                entry("Portal Shield", quantity: 2)])),
            record("b", daysAgo: 0, gear: gear([entry("Resonator", level: 7, quantity: 1, multiplied: false),
                                                entry(nil, quantity: 4, multiplied: true),
                                                entry("Resonator", quantity: 5, levelState: .unreadable)], nil,
                                               partial: true)),
            record("c", daysAgo: 0, gear: .notRead(reason: "resultTimeout")),
            record("d", daysAgo: 0),
        ], period: .today, now: now, calendar: calendar)
        #expect(statistics.gearComplete == 1 && statistics.gearPartial == 1 && statistics.gearNotRead == 1)
        #expect(statistics.gearIncomplete == 2)
        // Unnamed items are left out; an unread level still counts, as L?.
        #expect(statistics.items == 16 && statistics.itemsPerDrop == 8)
        // Multiplied drops count only when their item was named.
        #expect(statistics.multipliedItems == 3)
        #expect(statistics.gear.map(\.item) == ["Resonator", "Portal Shield", "Portal Key"])
        let resonator = try #require(statistics.gear.first)
        #expect(resonator.total == 11 && resonator.multiplied == 3)
        #expect(resonator.chips.map(\.split) == [.level(8), .level(7), .levelUnread])
        #expect(resonator.chips.map(\.quantity) == [5, 1, 5])
        // A meter that wasn't read, as in older records, is an unread rarity.
        #expect(statistics.gear[1].chips.map(\.split) == [.rarity(.veryRare), .rarity(.unreadable)])
        #expect(statistics.gear[2].chips.isEmpty && statistics.gear[2].total == 2)
        let none = HackStatistics(records: [record("a", daysAgo: 0)], period: .today, now: now, calendar: calendar)
        #expect(!none.hasGear && none.itemsPerDrop == nil)
    }

    func dropRecord(_ id: String, daysAgo: Double, _ entries: [GearDropEntry], partial: Bool = false,
                    association: GearDropSummary.Association = .noWaitingHack) -> GearDropRecord {
        let summary = GearDropSummary(groupID: 1, startedAt: 0, closedAt: 1, closeReason: "panelLeft", hackID: nil,
                                      association: association,
                                      panels: [.init(stage: .portal, entries: entries, partial: partial)])
        return GearDropRecord(id: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                              drop: GearDrop(captureSessionID: 1, summary: summary))
    }

    @Test("Drops no hack claimed join the gear totals, within the period, without counting as hacks")
    func dropTotals() throws {
        let hack = record("a", daysAgo: 0, gear: gear([entry("Resonator", level: 8, quantity: 2)],
                                                     [entry("Resonator", level: 8, quantity: 4)]))
        let drops = [
            // A portal panel alone is complete for a drop: no Bonus panel is expected.
            dropRecord("d1", daysAgo: 0, [entry("Resonator", level: 8, quantity: 1), entry("Power Cube", level: 7, quantity: 1)]),
            dropRecord("d2", daysAgo: 0, [entry("Portal Key", quantity: 1), entry(nil, quantity: 2)],
                       association: .uncertainContinuity),
            dropRecord("d3", daysAgo: 0, [entry("XMP Burster", level: 8, quantity: 3)], partial: true),
            dropRecord("old", daysAgo: 3, [entry("XMP Burster", level: 8, quantity: 50)]),
            GearDropRecord(id: "future", date: now, drop: nil),
        ]
        let statistics = HackStatistics(records: [hack], drops: drops, period: .today, now: now, calendar: calendar)
        #expect(statistics.hacks == 1 && statistics.drops == 3)
        #expect(statistics.gearComplete == 2 && statistics.gearPartial == 2 && statistics.gearNotRead == 0)
        #expect(statistics.items == 12 && statistics.itemsPerDrop == 3)
        #expect(statistics.gear.map(\.item) == ["Resonator", "XMP Burster", "Portal Key", "Power Cube"])
        #expect(!statistics.onlyDrops)
        let week = HackStatistics(records: [], drops: drops, period: .week, now: now, calendar: calendar)
        #expect(week.onlyDrops && week.drops == 4 && week.hasGear && week.hacks == 0)
        #expect(week.gear.first?.item == "XMP Burster" && week.gear.first?.total == 53)
    }

    @Test("An item with one rarity counts under it, even in readings saved before that was known",
          arguments: [("Hypercube", GearDropEntry.Rarity.veryRare), ("ADA Refactor", .veryRare),
                      ("JARVIS Virus", .veryRare), ("Turret", .rare)])
    func fixedRarity(_ sample: (String, GearDropEntry.Rarity)) throws {
        let (item, rarity) = sample
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, gear: gear([entry(item, quantity: 1, rarity: .unreadable),
                                                entry(item, quantity: 2, rarity: .common)],
                                               [entry(item, quantity: 1)])),
        ], period: .today, now: now, calendar: calendar)
        let group = try #require(statistics.gear.first)
        #expect(group.item == item && group.total == 4)
        #expect(group.chips == [.init(split: .rarity(rarity), quantity: 4)])
    }

    @Test("Longer periods chart one average per day; Today charts no single hacks")
    func bonusPoints() throws {
        let records = [
            record("a", daysAgo: 0.1, hacking: .init(percent: 120, isFinal: true), speed: nil),
            record("b", daysAgo: 0.2, hacking: .init(percent: 90, isFinal: false)),
            record("c", daysAgo: 2, hacking: .init(percent: 100, isFinal: true), speed: .init(percent: 40, isFinal: true)),
            record("d", daysAgo: 2.1, hacking: .init(percent: 151, isFinal: true), speed: .init(percent: 60, isFinal: true)),
        ]
        let today = HackStatistics(records: records, period: .today, now: now, calendar: calendar)
        #expect(today.bonusPoints.isEmpty && today.chartDays == nil)
        #expect(!BonusOverTimeChart.isShown(for: today, period: .today))
        let week = HackStatistics(records: records, period: .week, now: now, calendar: calendar)
        #expect(week.bonusPoints.map(\.hacks) == [2, 2])
        // A last-seen bonus is not averaged: today's Hacking is 120 alone.
        #expect(week.bonusPoints.map(\.hacking) == [126, 120] && week.bonusPoints.map(\.speed) == [50, 50])
        #expect(BonusOverTimeChart.isShown(for: week, period: .week))
        let days = try #require(week.chartDays)
        #expect(days.upperBound.timeIntervalSince(days.lowerBound) == 7 * 86_400)
        let all = HackStatistics(records: records + [record("e", daysAgo: 30)], period: .all, now: now, calendar: calendar)
        let allDays = try #require(all.chartDays)
        #expect(allDays.upperBound.timeIntervalSince(allDays.lowerBound) == 31 * 86_400)
    }

    @Test("Activity counts hacks per hour for Today and per day otherwise")
    func activity() {
        let records = [record("a", daysAgo: 0.01), record("b", daysAgo: 0.02), record("c", daysAgo: 0.2),
                       record("d", daysAgo: 3)]
        #expect(HackStatistics(records: records, period: .today, now: now, calendar: calendar).activity.map(\.hacks) == [1, 2])
        #expect(HackStatistics(records: records, period: .week, now: now, calendar: calendar).activity.map(\.hacks) == [1, 3])
    }

    @Test("Changes compare with yesterday or the 7 days before, in points, and never for All")
    func changes() throws {
        let records = [
            record("a", daysAgo: 0, hacking: .init(percent: 130, isFinal: true), speed: nil,
                   slots: [slot("xm", .accepted), slot("xm", .accepted)]),
            record("b", daysAgo: 1, hacking: .init(percent: 100, isFinal: true), speed: .init(percent: 60, isFinal: true),
                   slots: [slot("xm", .accepted), slot("xm", .rejected)]),
            record("c", daysAgo: 1.2),
            record("d", daysAgo: 9),
        ]
        let today = try #require(HackStatistics(records: records, period: .today, now: now, calendar: calendar).change)
        #expect(today == .init(hacks: -1, hacking: 30, speed: nil, accepted: 50, secondsPerGlyph: nil))
        let week = try #require(HackStatistics(records: records, period: .week, now: now, calendar: calendar).change)
        #expect(week.hacks == 2)
        #expect(HackStatistics(records: records, period: .all, now: now, calendar: calendar).change == nil)
        #expect(HackStatistics(records: [records[0]], period: .today, now: now, calendar: calendar).change == nil)
    }

    @Test("Weakest and slowest Glyphs need three attempts and rank worst first")
    func rankings() {
        let slots: [HackResultSummary.Slot] = [
            slot("help", .accepted, seconds: 1), slot("help", .rejected, seconds: 2), slot("help", .rejected, seconds: 3),
            slot("xm", .accepted, seconds: 0.4), slot("xm", .accepted, seconds: 0.5), slot("xm", .rejected, seconds: 0.6),
            slot("xm", .accepted),
            slot("now", .rejected, seconds: 5), slot("now", .rejected, seconds: 5),
        ]
        let statistics = HackStatistics(records: [record("a", daysAgo: 0, slots: slots)], period: .today, now: now,
                                        calendar: calendar)
        #expect(statistics.weakestGlyphs.map(\.glyph) == ["help", "xm"])
        #expect(statistics.drawTimeGlyphs.map(\.glyph) == ["help", "xm"])
        #expect(statistics.drawTimeGlyphs.first?.medianDrawSeconds == 2)
    }

    @Test("Mixed lengths hide bonus changes; Sec/Glyph and the per-length averages compare across them")
    func lengths() throws {
        let records = [
            record("a", daysAgo: 0, hacking: .init(percent: 150, isFinal: true), slots: glyphs(3), input: 6),
            record("b", daysAgo: 0, hacking: .init(percent: 90, isFinal: true), slots: glyphs(5, accepted: 4), input: 10),
            record("c", daysAgo: 1, hacking: .init(percent: 80, isFinal: true), slots: glyphs(5), input: 15),
        ]
        let today = HackStatistics(records: records, period: .today, now: now, calendar: calendar)
        #expect(today.lengths == [3, 5] && today.mixesLengths)
        // Input time over Glyphs, pooled: (6 + 10) / (3 + 5).
        #expect(today.secondsPerGlyph == 2)
        let mixed = try #require(today.change)
        #expect(mixed.hacking == nil && mixed.speed == nil, "Bonuses of mixed lengths aren't compared")
        #expect(mixed.secondsPerGlyph == -1 && mixed.accepted == -12)
        #expect(today.lengthAverages.map(\.glyphs) == [3, 5] && today.lengthAverages.map(\.hacking) == [150, 90])
        #expect(LengthBonusChart.isShown(for: today))
        // One length on both days: bonuses compare again.
        let same = HackStatistics(records: Array(records.dropFirst()), period: .today, now: now, calendar: calendar)
        #expect(!same.mixesLengths && same.change?.hacking == 10)
        #expect(HackStatistics(records: records, period: .week, now: now, calendar: calendar)
            .bonusPoints.map(\.accepted) == [100, 88])
        // Older results without an input time leave Sec/Glyph out.
        #expect(HackStatistics(records: [record("d", daysAgo: 0, slots: glyphs(3))], period: .today, now: now,
                               calendar: calendar).secondsPerGlyph == nil)
        #expect(!LengthBonusChart.isShown(for: HackStatistics(records: [], period: .today, now: now, calendar: calendar)))
    }

    @Test("Length rows split a length that several portal levels share, where the level was read")
    func lengthRows() throws {
        let records = [
            record("a", daysAgo: 0, hacking: .init(percent: 120, isFinal: true), slots: glyphs(3), input: 6, portalLevel: 4),
            record("b", daysAgo: 0, hacking: .init(percent: 100, isFinal: true), slots: glyphs(3), input: 9, portalLevel: 5),
            record("c", daysAgo: 0, slots: glyphs(3)),
            record("d", daysAgo: 0, slots: glyphs(5), portalLevel: 8),
        ]
        let rows = HackStatistics(records: records, period: .today, now: now, calendar: calendar).lengthRows
        #expect(rows.map(\.glyphs) == [3, 3, 3, 5])
        #expect(rows.map(\.level) == [nil, 4, 5, nil], "5 Glyphs is only L8, so it isn't split")
        #expect(rows.map(\.hacks) == [3, 1, 1, 1])
        #expect(rows[0].secondsPerGlyph == 2.5 && rows[0].hacking == 107)
        #expect(rows[1].secondsPerGlyph == 2 && rows[2].secondsPerGlyph == 3)
    }

    @Test("The chart's lines are remembered by name, and the last one can't be hidden")
    func chartSeries() {
        #expect(ChartSeries.parse(ChartSeries.defaultStorage) == [.hacking, .speed])
        #expect(ChartSeries.parse("accepted,unknown") == [.accepted])
        #expect(ChartSeries.parse("") == [.hacking, .speed], "Nothing readable falls back to the default")
        #expect(ChartSeries.storage([.accepted, .hacking]) == "hacking,accepted")
        #expect(ChartSeries.toggling(.accepted, in: [.hacking]) == [.hacking, .accepted])
        #expect(ChartSeries.toggling(.hacking, in: [.hacking, .speed]) == [.speed])
        #expect(ChartSeries.toggling(.speed, in: [.speed]) == [.speed])
    }

    func commands(speed: HackCommand? = nil, keys: HackCommand? = nil, drone: Bool = false,
                  uncertainKeys: Bool = false) -> HackCommandSummary {
        var commands = HackCommandSummary()
        if let speed { commands.presentation.status = .confirmed; commands.presentation.lastObserved = speed }
        if let keys { commands.gear.status = .confirmed; commands.gear.lastObserved = keys }
        if uncertainKeys { commands.gear.status = .unresolved }
        if drone { commands.mode = .drone; commands.gear.status = .notApplicable }
        return commands
    }

    @Test("Gear per key command counts only hacks read in full with no multiplied drop; drones stay apart")
    func keyCommands() throws {
        let full = gear([entry("Portal Key", quantity: 2), entry("Resonator", level: 8, quantity: 3)],
                        [entry("XMP Burster", level: 8, quantity: 4)])
        let partial = gear([entry("Portal Key", quantity: 9)], nil, partial: true)
        let doubled = gear([entry("Portal Key", quantity: 4, multiplied: true)], [entry("Resonator", level: 8, quantity: 2)])
        let keysOnly = gear([entry("Portal Key", quantity: 3)], [entry("Portal Key", quantity: 1)])
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, gear: full, commands: commands(keys: .requestKey)),
            record("b", daysAgo: 0, gear: partial, commands: commands(keys: .requestKey)),
            record("c", daysAgo: 0, gear: doubled, commands: commands(keys: .requestKey)),
            record("d", daysAgo: 0, gear: keysOnly, commands: commands(keys: .keysOnly)),
            record("e", daysAgo: 0, gear: full, commands: commands()),
            record("f", daysAgo: 0, gear: full, commands: commands(uncertainKeys: true)),
            record("g", daysAgo: 0, gear: full, commands: commands(speed: .complex, drone: true)),
            record("h", daysAgo: 0, gear: full),
        ], period: .today, now: now, calendar: calendar)
        let rows = statistics.keyCommandRows
        #expect(rows.map(\.group) == [.command(.requestKey), .command(.keysOnly), .none, .uncertain, .drone],
                "Older history without commands is left out")
        let request = try #require(rows.first)
        #expect(request.hacks == 3 && request.measured == 1)
        #expect(request.keysPerHack == 2 && request.otherItemsPerHack == 7)
        #expect(rows[1].keysPerHack == 4 && rows[1].otherItemsPerHack == 0)
        #expect(rows.last?.hacks == 1)
    }

    @Test("Bonuses by presentation speed keep Simple and Complex apart")
    func speedCommands() {
        let statistics = HackStatistics(records: [
            record("a", daysAgo: 0, hacking: .init(percent: 150, isFinal: true), slots: glyphs(4),
                   commands: commands(speed: .complex)),
            record("b", daysAgo: 0, hacking: .init(percent: 110, isFinal: true), slots: glyphs(4, accepted: 3),
                   commands: commands(speed: .complex)),
            record("c", daysAgo: 0, hacking: .init(percent: 90, isFinal: true), slots: glyphs(4), commands: commands()),
            record("d", daysAgo: 0, hacking: .init(percent: 70, isFinal: true), slots: glyphs(4)),
        ], period: .today, now: now, calendar: calendar)
        #expect(statistics.speedCommandRows.map(\.group) == [.command(.complex), .none])
        #expect(statistics.speedCommandRows.first?.hacking == 130 && statistics.speedCommandRows.first?.accepted == 88)
        #expect(statistics.speedCommandRows.last?.hacks == 1)
    }

    @Test("Every hack card says which commands were seen, that none was, or that one may have been missed")
    func cardCommandLine() {
        #expect(HackCommandSummary.cardText(nil) == "Commands not read")
        #expect(HackCommandSummary.cardText(HackCommandSummary()) == "No command")
        #expect(HackCommandSummary.cardText(commands(speed: .complex, keys: .keysOnly)) == "Complex hack · Keys only")
        #expect(HackCommandSummary.cardText(commands(keys: .requestKey)) == "No speed command · Request key")
        #expect(HackCommandSummary.cardText(commands(speed: .simple, uncertainKeys: true)) == "Simple hack · Key command uncertain")
        #expect(HackCommandSummary.cardText(commands(speed: .complex, drone: true)) == "Complex hack · Drone · key commands don't apply")
        var unseen = HackCommandSummary()
        unseen.presentation.status = .unresolved; unseen.gear.status = .unresolved
        #expect(HackCommandSummary.cardText(unseen) == "Speed command uncertain · Key command uncertain")
    }
}
