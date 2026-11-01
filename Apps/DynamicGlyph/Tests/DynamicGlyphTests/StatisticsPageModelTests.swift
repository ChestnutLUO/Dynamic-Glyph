import Combine
import CoreData
import Foundation
import QuartzCore
import Testing
import GlyphRecognition

@MainActor
@Suite("Statistics page model")
struct StatisticsPageModelTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Noon, so a few hours either side stays within the day.
    let now = Date(timeIntervalSince1970: 20_833 * 86_400 + 43_200)

    // MARK: - Data

    private func summary(hack: Int, closed: Bool = true, session: UInt64 = 1) -> HackResultSummary {
        HackResultSummary(captureSessionID: session, hackID: hack, state: closed ? .complete : .awaiting,
                          isClosed: closed, closeReason: closed ? "panelLeft" : nil,
                          hackingBonus: .init(percent: 100 - hack % 30, isFinal: true),
                          speedBonus: .init(percent: hack % 40, isFinal: true),
                          slots: [.init(glyph: "help", outcome: .accepted, check: .matched, comparison: .agreement),
                                  .init(glyph: "you", outcome: hack % 5 == 0 ? .rejected : .accepted, check: nil,
                                        comparison: .unknownAssociation)],
                          inputSeconds: 3.5)
    }

    private func group(_ id: Int, hack: Int?, quantity: Int = 2) -> GearDropSummary {
        let entries = [GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: quantity),
                       GearDropEntry(column: 1, row: 0, item: "Portal Key", levelState: .notApplicable, level: nil,
                                     quantity: 1)]
        return GearDropSummary(groupID: id, startedAt: 0, closedAt: 2, closeReason: "panelLeft", hackID: hack,
                               association: hack == nil ? .noWaitingHack : .ordered,
                               panels: [.init(stage: .portal, entries: entries, partial: false)])
    }

    private func gear(hack: Int, session: UInt64 = 1, quantity: Int = 2) -> HackGearAttachment {
        HackGearAttachment(captureSessionID: session, hackID: hack, reading: .read(group(hack, hack: hack, quantity: quantity)))
    }

    private func drop(_ id: Int, session: UInt64 = 1) -> GearDrop {
        GearDrop(captureSessionID: session, summary: group(id, hack: nil))
    }

    /// `hacks` hacks and `drops` drop groups over `days` days before `now`,
    /// some at the same instant, some still open, one unreadable of each.
    private func dataset(hacks: Int, drops: Int, days: Double) -> ([HackResultRecord], [GearDropRecord]) {
        let span = days * 86_400
        var records = (0..<hacks).map { index -> HackResultRecord in
            let date = now.addingTimeInterval(-span * Double(index) / Double(hacks))
            return HackResultRecord(id: "h\(index)", date: date, summary: summary(hack: index, closed: index % 97 != 1),
                                    gear: index % 3 == 0 ? nil : gear(hack: index))
        }
        var dropRecords = (0..<drops).map { index -> GearDropRecord in
            // Every tenth drop at exactly a hack's time: ties keep their order.
            let date = index % 10 == 0 && index / 10 < hacks
                ? records[index / 10].date : now.addingTimeInterval(-span * (Double(index) + 0.5) / Double(drops))
            return GearDropRecord(id: "d\(index)", date: date, drop: drop(index))
        }
        records.append(HackResultRecord(id: "unknown", date: now.addingTimeInterval(-3_600), summary: nil))
        dropRecords.append(GearDropRecord(id: "unknown", date: now.addingTimeInterval(-7_200), drop: nil))
        // Newest first, as HackResults hands them out.
        return (records.sorted { $0.date > $1.date }, dropRecords.sorted { $0.date > $1.date })
    }

    // MARK: - The page's computations before the model, kept as the reference

    private enum Reference {
        static func entries(_ records: [HackResultRecord], _ drops: [GearDropRecord]) -> [StatisticsEntry] {
            (records.map(StatisticsEntry.hack) + drops.map(StatisticsEntry.drop)).sorted { $0.date > $1.date }
        }

        static func shownEntries(_ records: [HackResultRecord], _ drops: [GearDropRecord],
                                 selection: StatisticsSelection, now: Date, calendar: Calendar) -> [StatisticsEntry] {
            let all = entries(records, drops)
            let range = selection.range(now: now, oldest: all.last?.date, calendar: calendar)
            return all.filter { range.contains($0.date) }
        }

        static func deletableIDs(_ shown: [StatisticsEntry]) -> Set<String> {
            Set(shown.filter(\.isDeletable).map(\.id))
        }

        static func days(_ shown: [StatisticsEntry], calendar: Calendar) -> [(day: Date, entries: [StatisticsEntry])] {
            var groups: [(day: Date, entries: [StatisticsEntry])] = []
            for entry in shown {
                let day = calendar.startOfDay(for: entry.date)
                if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) }
                else { groups.append((day, [entry])) }
            }
            return groups
        }

        /// Everything one evaluation of the old page worked out: the list four
        /// times over (count, toolbar, deletable ids, days), the history, the
        /// totals and the timeline's ticks.
        static func pass(_ records: [HackResultRecord], _ drops: [GearDropRecord], keepsResults: Bool,
                         selection: StatisticsSelection, now: Date, calendar: Calendar) -> Int {
            let history = StatisticsHistory(records: records, drops: drops, keepsResults: keepsResults, now: now,
                                            calendar: calendar)
            let range = selection.range(now: now, oldest: history.oldest, calendar: calendar)
            let statistics = HackStatistics(records: records, drops: drops, range: range, history: history, now: now,
                                            calendar: calendar)
            let ticks = StatisticsTimeline.Tick.ticks(records.map(\.date))
            let count = shownEntries(records, drops, selection: selection, now: now, calendar: calendar).count
            let toolbar = shownEntries(records, drops, selection: selection, now: now, calendar: calendar).count
            let deletable = deletableIDs(shownEntries(records, drops, selection: selection, now: now, calendar: calendar))
            let groups = days(shownEntries(records, drops, selection: selection, now: now, calendar: calendar),
                              calendar: calendar)
            return statistics.hacks + ticks.count + count + toolbar + deletable.count + groups.count
        }
    }

    private func expectMatchesReference(_ snapshot: StatisticsPageModel.Snapshot, records: [HackResultRecord],
                                        drops: [GearDropRecord], keepsResults: Bool = true,
                                        selection: StatisticsSelection, now: Date) {
        let history = StatisticsHistory(records: records, drops: drops, keepsResults: keepsResults, now: now,
                                        calendar: calendar)
        let range = selection.range(now: now, oldest: history.oldest, calendar: calendar)
        #expect(snapshot.history == history)
        #expect(snapshot.range == range)
        #expect(snapshot.statistics == HackStatistics(records: records, drops: drops, range: range, history: history,
                                                      now: now, calendar: calendar))
        #expect(snapshot.ticks == StatisticsTimeline.Tick.ticks(records.map(\.date)))
        let all = Reference.entries(records, drops)
        let shown = Reference.shownEntries(records, drops, selection: selection, now: now, calendar: calendar)
        #expect(snapshot.list.all.map(\.id) == all.map(\.id))
        #expect(snapshot.list.all == all)
        #expect(snapshot.list.shown == shown)
        #expect(snapshot.list.deletableIDs == Reference.deletableIDs(shown))
        let days = Reference.days(shown, calendar: calendar)
        #expect(snapshot.list.days.map(\.day) == days.map(\.day))
        #expect(snapshot.list.days.map { $0.entries.map(\.id) } == days.map { $0.entries.map(\.id) })
        // The flattened rows: each day's heading, then its cards in order.
        var rows: [StatisticsList.Row] = []
        for group in days {
            rows.append(.day(group.day))
            for (index, entry) in group.entries.enumerated() { rows.append(.entry(entry, isFirst: index == 0)) }
        }
        #expect(snapshot.list.rows == rows)
        #expect(Set(snapshot.list.rows.map(\.id)).count == snapshot.list.rows.count, "Row ids are unique")
    }

    // MARK: - Same output as before

    @Test("A fixed history gives the list, groups, totals and ticks the page computed before",
          arguments: [StatisticsRange.Preset.day, .sevenDays, .thirtyDays, .all, .last24Hours, .lastHour])
    func sameAsBefore(preset: StatisticsRange.Preset) {
        let (records, drops) = dataset(hacks: 300, drops: 700, days: 40)
        let oldest = (records.map(\.date) + drops.map(\.date)).min()
        let selection = StatisticsSelection.preset(preset, now: now, oldest: oldest, calendar: calendar)
        let model = StatisticsPageModel()
        let snapshot = model.snapshot(revision: 1, records: records, drops: drops, keepsResults: true,
                                      selection: selection, tick: now, now: now, calendar: calendar)
        expectMatchesReference(snapshot, records: records, drops: drops, selection: selection, now: now)
        #expect(!snapshot.list.shown.isEmpty)
    }

    @Test("A frozen range and keeping off match the old page too")
    func frozenAndNotKept() {
        let (records, drops) = dataset(hacks: 120, drops: 200, days: 10)
        let selection = StatisticsSelection(start: now.addingTimeInterval(-3 * 86_400 - 1_234),
                                            end: .at(now.addingTimeInterval(-86_400 + 77)))
        let model = StatisticsPageModel()
        let snapshot = model.snapshot(revision: 1, records: records, drops: drops, keepsResults: false,
                                      selection: selection, tick: now, now: now, calendar: calendar)
        expectMatchesReference(snapshot, records: records, drops: drops, keepsResults: false, selection: selection, now: now)
    }

    @Test("An empty history gives an empty list")
    func empty() {
        let selection = StatisticsSelection.preset(.day, now: now, oldest: nil, calendar: calendar)
        let snapshot = StatisticsPageModel().snapshot(revision: 0, records: [], drops: [], keepsResults: true,
                                                      selection: selection, tick: now, now: now, calendar: calendar)
        expectMatchesReference(snapshot, records: [], drops: [], selection: selection, now: now)
        #expect(snapshot.list.rows.isEmpty && snapshot.list.deletableIDs.isEmpty)
    }

    // MARK: - No work without a change

    @Test("Evaluations without a change reuse the snapshot; the minute, a tick, the range or keeping make a new one")
    func reuse() {
        let (records, drops) = dataset(hacks: 50, drops: 80, days: 5)
        let model = StatisticsPageModel()
        let day = StatisticsSelection.preset(.day, now: now, oldest: nil, calendar: calendar)
        func snapshot(revision: Int = 1, keeps: Bool = true, selection: StatisticsSelection? = nil, tick: Date? = nil,
                      at time: Date? = nil) -> StatisticsPageModel.Snapshot {
            model.snapshot(revision: revision, records: records, drops: drops, keepsResults: keeps,
                           selection: selection ?? day, tick: tick ?? now, now: time ?? now, calendar: calendar)
        }
        let first = snapshot()
        // Capture publishing at 5 Hz for a minute's worth, within the minute.
        for step in 0..<50 { _ = snapshot(at: now.addingTimeInterval(Double(step) * 0.2)) }
        #expect(model.snapshots == 1 && model.sorts == 1)
        #expect(snapshot(at: now.addingTimeInterval(9)).now == first.now)
        // The next minute, or the page's minute tick: new totals, same sort.
        _ = snapshot(at: now.addingTimeInterval(60))
        #expect(model.snapshots == 2 && model.sorts == 1)
        _ = snapshot(tick: now.addingTimeInterval(60), at: now.addingTimeInterval(60))
        #expect(model.snapshots == 3 && model.sorts == 1)
        // The handles moved, or keeping changed.
        let week = StatisticsSelection.preset(.sevenDays, now: now, oldest: nil, calendar: calendar)
        let moved = snapshot(selection: week, tick: now.addingTimeInterval(60), at: now.addingTimeInterval(60))
        #expect(model.snapshots == 4 && model.sorts == 1 && moved.list.shown.count > first.list.shown.count)
        _ = snapshot(keeps: false, selection: week, tick: now.addingTimeInterval(60), at: now.addingTimeInterval(60))
        #expect(model.snapshots == 5 && model.sorts == 1)
        // New records: sorted again.
        _ = snapshot(revision: 2, keeps: false, selection: week, tick: now.addingTimeInterval(60),
                     at: now.addingTimeInterval(60))
        #expect(model.snapshots == 6 && model.sorts == 2)
    }

    // MARK: - Live changes through HackResults

    private func isolatedPreferences() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-statistics-model-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    /// A clock the test advances by hand.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test("A new hack, its gear, a drop, a deletion and a sync each show at the next evaluation; other changes don't recompute")
    func liveChanges() async throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock(now)
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container),
                                  now: { clock.now })
        let model = StatisticsPageModel()
        let selection = StatisticsSelection.preset(.day, now: now.addingTimeInterval(-3_600), oldest: nil,
                                                   calendar: calendar)
        var evaluations = 0
        func evaluate() -> StatisticsPageModel.Snapshot {
            evaluations += 1
            // A moment after the latest record: the live end is left out.
            return model.snapshot(of: results, selection: selection, tick: now, now: clock.now.addingTimeInterval(1),
                                  calendar: calendar)
        }
        func check(_ snapshot: StatisticsPageModel.Snapshot) {
            expectMatchesReference(snapshot, records: results.records, drops: results.drops,
                                   keepsResults: results.keepsResults, selection: selection, now: snapshot.now)
        }
        var snapshot = evaluate()
        #expect(snapshot.list.shown.isEmpty)
        var made = model.snapshots

        // A hack read while capturing: in progress, then closed and saved.
        results.receive(summary(hack: 1, closed: false))
        snapshot = evaluate()
        #expect(snapshot.list.shown.map(\.id) == ["hack/\(results.records[0].id)"])
        #expect(snapshot.list.deletableIDs.isEmpty, "A hack still being read can't be deleted")
        clock.now = clock.now.addingTimeInterval(5)
        results.receive(summary(hack: 1, closed: true))
        snapshot = evaluate()
        #expect(snapshot.list.deletableIDs == ["hack/\(results.records[0].id)"])
        #expect(snapshot.statistics.hacks == 1)
        check(snapshot)

        // Its gear arrives later: the same record, edited.
        results.receiveGear(gear(hack: 1))
        snapshot = evaluate()
        guard case .hack(let edited)? = snapshot.list.shown.first else { Issue.record("no hack"); return }
        #expect(edited.gear == gear(hack: 1))
        #expect(snapshot.statistics.items > 0)
        check(snapshot)

        // A drop group no hack claimed.
        clock.now = clock.now.addingTimeInterval(30)
        results.receiveDrop(drop(7))
        snapshot = evaluate()
        #expect(snapshot.list.shown.count == 2)
        #expect(snapshot.list.shown.first.map { if case .drop = $0 { true } else { false } } == true)
        check(snapshot)
        made = model.snapshots

        // Capture publishing, the half-second clock, a switch that doesn't
        // touch the records: no new snapshot, nothing sorted again.
        let sorts = model.sorts
        results.readsGear.toggle()
        results.savesGearPictures.toggle()
        for _ in 0..<20 { _ = evaluate() }
        #expect(model.snapshots == made && model.sorts == sorts)

        // Deleted from the page.
        let hackID = results.records[0].id
        try results.delete(hacks: [hackID], drops: [])
        snapshot = evaluate()
        #expect(snapshot.list.shown.map(\.id) == ["drop/\(results.drops[0].id)"])
        #expect(snapshot.statistics.hacks == 0)
        check(snapshot)

        // Another iPhone's hack, synced into the store, read on refresh.
        let other = HackResultStore(container: container)
        try other.save(summary(hack: 2, session: 9), key: "other-iphone/9/2", date: clock.now.addingTimeInterval(-60),
                       now: clock.now)
        await results.refresh()
        snapshot = evaluate()
        #expect(snapshot.list.shown.contains { $0.id == "hack/other-iphone/9/2" })
        check(snapshot)

        // And one merged through the store's remote change notification.
        try other.saveDrop(drop(8, session: 9), key: "other-iphone/9/drop-8", date: clock.now.addingTimeInterval(-30),
                           now: clock.now)
        let before = results.revision
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        for _ in 0..<100 where results.revision == before { try await Task.sleep(for: .milliseconds(20)) }
        snapshot = evaluate()
        #expect(snapshot.list.shown.contains { $0.id == "drop/other-iphone/9/drop-8" })
        check(snapshot)

        // Cleared.
        results.clear()
        snapshot = evaluate()
        #expect(snapshot.list.shown.isEmpty && snapshot.list.rows.isEmpty)
        #expect(evaluations > model.snapshots)
    }

    @Test("Records that arrive while the app is in the background are on the first evaluation after it returns")
    func backgroundArrivals() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock(now)
        let results = HackResults(preferences: preferences,
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)),
                                  now: { clock.now })
        let model = StatisticsPageModel()
        let selection = StatisticsSelection.preset(.day, now: now, oldest: nil, calendar: calendar)
        let before = model.snapshot(of: results, selection: selection, tick: now, now: clock.now, calendar: calendar)
        #expect(before.list.shown.isEmpty)
        // Behind the game: hacks, gear and drops arrive, nothing is drawn.
        for hack in 1...3 {
            clock.now = clock.now.addingTimeInterval(10)
            results.receive(summary(hack: hack))
            results.receiveGear(gear(hack: hack))
        }
        results.receiveDrop(drop(4))
        // Back in front, within the same minute: the first evaluation has them.
        let after = model.snapshot(of: results, selection: selection, tick: now, now: clock.now.addingTimeInterval(1),
                                   calendar: calendar)
        #expect(after.list.shown.count == 4)
        #expect(after.statistics.hacks == 3)
        expectMatchesReference(after, records: results.records, drops: results.drops, selection: selection,
                               now: after.now)
    }

    // MARK: - Engine changes while the app is in the background

    /// Stands in for the engine: values always stored, notices gated.
    @MainActor
    private final class Screen: ObservableObject {
        lazy var gate = InterfacePublishGate(isOpen: true) { [weak self] in self?.objectWillChange.send() }
        var display = 0 { willSet { gate.willChange() } }
    }

    @Test("While closed the gate holds every notice; opening sends one at once and the values are current")
    func gateHoldsAndCatchesUp() {
        let screen = Screen()
        var notices = 0
        let subscription = screen.objectWillChange.sink { notices += 1 }
        defer { subscription.cancel() }
        screen.display = 1
        #expect(notices == 1)
        // In the background: 5 Hz for a minute, nothing reaches SwiftUI.
        screen.gate.close()
        for value in 2...301 { screen.display = value }
        #expect(notices == 1 && screen.gate.isStale)
        // Coming back: one notice, sent before open() returns, so the view
        // update queued for the first frame reads the newest value.
        screen.gate.open()
        #expect(notices == 2 && !screen.gate.isStale)
        #expect(screen.display == 301)
        // Open with nothing new: no notice.
        screen.gate.close()
        screen.gate.open()
        #expect(notices == 2)
        screen.display = 302
        #expect(notices == 3)
    }

    // MARK: - Cost at 2,000 hacks and 5,000 drops

    @Test("At 2,000 hacks and 5,000 drops an unchanged evaluation costs a lookup, not a sort")
    func benchmark() {
        let (records, drops) = dataset(hacks: 2_000, drops: 5_000, days: 30)
        let oldest = (records.map(\.date) + drops.map(\.date)).min()
        func milliseconds(_ runs: Int, _ work: () -> Void) -> Double {
            let start = CACurrentMediaTime()
            for _ in 0..<runs { work() }
            return (CACurrentMediaTime() - start) * 1_000 / Double(runs)
        }
        var lines: [String] = []
        for preset in [StatisticsRange.Preset.day, .sevenDays, .all] {
            let selection = StatisticsSelection.preset(preset, now: now, oldest: oldest, calendar: calendar)
            var sink = 0
            let entries = milliseconds(5) { sink += Reference.entries(records, drops).count }
            let days = milliseconds(5) {
                sink += Reference.days(Reference.shownEntries(records, drops, selection: selection, now: now,
                                                              calendar: calendar), calendar: calendar).count
            }
            let oldPass = milliseconds(5) {
                sink += Reference.pass(records, drops, keepsResults: true, selection: selection, now: now,
                                       calendar: calendar)
            }
            let model = StatisticsPageModel()
            var revision = 0
            let miss = milliseconds(5) {
                revision += 1
                sink += model.snapshot(revision: revision, records: records, drops: drops, keepsResults: true,
                                       selection: selection, tick: now, now: now, calendar: calendar).list.rows.count
            }
            let hit = milliseconds(200) {
                sink += model.snapshot(revision: revision, records: records, drops: drops, keepsResults: true,
                                       selection: selection, tick: now, now: now, calendar: calendar).list.rows.count
            }
            #expect(sink > 0)
            #expect(hit < oldPass / 20, "An unchanged evaluation must not redo the page's work")
            lines.append(String(format: "STATSPERF-BENCH preset=%@ hacks=%d drops=%d entries(sort)=%.2fms days(old,incl. sort)=%.2fms oldPass=%.2fms newMiss=%.2fms newHit=%.4fms",
                                preset.rawValue, records.count, drops.count, entries, days, oldPass, miss, hit))
        }
        // For the report: read from the test log.
        for line in lines { print(line) }
    }
}
