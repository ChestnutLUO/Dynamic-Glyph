import Foundation

/// A hack, or a drop group no hack claimed, in the Statistics list.
enum StatisticsEntry: Identifiable, Equatable {
    case hack(HackResultRecord), drop(GearDropRecord)

    var id: String {
        switch self {
        case .hack(let record): return "hack/\(record.id)"
        case .drop(let record): return "drop/\(record.id)"
        }
    }
    var date: Date {
        switch self {
        case .hack(let record): return record.date
        case .drop(let record): return record.date
        }
    }
    var isDeletable: Bool {
        switch self {
        case .hack(let record): return record.isDeletable
        case .drop: return true
        }
    }
    /// A finished hack or a drop this build can read.
    var isExportable: Bool {
        switch self {
        case .hack(let record): return record.summary?.isClosed == true
        case .drop(let record): return record.drop != nil
        }
    }
    /// Panel pictures stay in the session's logs when a record goes.
    var hasPictures: Bool {
        switch self {
        case .hack(let record): return !(record.gear?.pictures ?? []).isEmpty
        case .drop(let record): return !(record.drop?.pictures ?? []).isEmpty
        }
    }
    var kind: GearExport.Kind {
        if case .hack = self { return .hack }
        return .drop
    }
    /// What VoiceOver reads for the card while selecting.
    var label: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch self {
        case .hack:
            return String(localized: "Hack result, \(time)",
                          comment: "Statistics, selecting: VoiceOver label of a hack's card. The placeholder is its time.")
        case .drop:
            return String(localized: "Item drop, \(time)",
                          comment: "Statistics, selecting: VoiceOver label of a drop group's card. The placeholder is its time.")
        }
    }
}

/// The Statistics list: every hack and drop newest first, the ones in the
/// shown range, and those by local day.
struct StatisticsList: Equatable {
    struct Day: Equatable {
        let day: Date
        let entries: [StatisticsEntry]
    }

    /// One row of the list, flattened so the lazy stack makes each card only
    /// as it scrolls into view: a day's heading, then its cards.
    enum Row: Identifiable, Equatable {
        case day(Date)
        /// `isFirst`: the day's first card, right under its heading.
        case entry(StatisticsEntry, isFirst: Bool)

        var id: String {
            switch self {
            case .day(let day): return "day/\(day.timeIntervalSinceReferenceDate)"
            case .entry(let entry, _): return entry.id
            }
        }
    }

    /// Every hack and drop, newest first.
    let all: [StatisticsEntry]
    /// The hacks and drops in the shown range: the list, Select and Export
    /// all cover them, start included and end left out.
    let shown: [StatisticsEntry]
    let days: [Day]
    let rows: [Row]
    /// What Select All chooses.
    let deletableIDs: Set<String>

    /// Sorted as the page always sorted them.
    static func sorted(records: [HackResultRecord], drops: [GearDropRecord]) -> [StatisticsEntry] {
        (records.map(StatisticsEntry.hack) + drops.map(StatisticsEntry.drop)).sorted { $0.date > $1.date }
    }

    init(all: [StatisticsEntry], range: StatisticsRange, calendar: Calendar = .current) {
        self.all = all
        shown = all.filter { range.contains($0.date) }
        var groups: [Day] = []
        var current: (day: Date, entries: [StatisticsEntry])?
        for entry in shown {
            let day = calendar.startOfDay(for: entry.date)
            if current?.day == day {
                current?.entries.append(entry)
            } else {
                if let current { groups.append(Day(day: current.day, entries: current.entries)) }
                current = (day, [entry])
            }
        }
        if let current { groups.append(Day(day: current.day, entries: current.entries)) }
        days = groups
        var rows: [Row] = []
        for group in groups {
            rows.append(.day(group.day))
            for (index, entry) in group.entries.enumerated() { rows.append(.entry(entry, isFirst: index == 0)) }
        }
        self.rows = rows
        deletableIDs = Set(shown.filter(\.isDeletable).map(\.id))
    }
}

/// What the Statistics page shows, worked out once per change instead of on
/// every evaluation of the page. A new snapshot is made only when the
/// records change (`HackResults.revision`), keeping is switched, the range's
/// handles move, the time zone changes, or the page's minute timeline
/// ticks; otherwise the last one is returned as it is.
@MainActor
final class StatisticsPageModel {
    struct Snapshot {
        /// When it was made: the page's now until the next one.
        let now: Date
        let history: StatisticsHistory
        let range: StatisticsRange
        let statistics: HackStatistics
        let ticks: [StatisticsTimeline.Tick]
        let list: StatisticsList
    }

    private struct Key: Equatable {
        let revision: Int
        let keepsResults: Bool
        let selection: StatisticsSelection
        /// The minute timeline's last tick.
        let tick: Date
        /// The wall-clock minute, so a snapshot never outlives its minute.
        let minute: Int
        let timeZone: TimeZone
    }

    /// How many snapshots were made, and how many times every record was
    /// sorted: once per change of the records, not per evaluation.
    private(set) var snapshots = 0
    private(set) var sorts = 0

    private var key: Key?
    private var snapshot: Snapshot?
    private var sortedRevision: Int?
    private var sorted: [StatisticsEntry] = []

    init() {}

    func snapshot(of results: HackResults, selection: StatisticsSelection, tick: Date, now: Date = Date(),
                  calendar: Calendar = .current) -> Snapshot {
        snapshot(revision: results.revision, records: results.records, drops: results.drops,
                 keepsResults: results.keepsResults, selection: selection, tick: tick, now: now, calendar: calendar)
    }

    /// `revision` must change whenever `records` or `drops` do.
    func snapshot(revision: Int, records: [HackResultRecord], drops: [GearDropRecord], keepsResults: Bool,
                  selection: StatisticsSelection, tick: Date, now: Date = Date(),
                  calendar: Calendar = .current) -> Snapshot {
        let key = Key(revision: revision, keepsResults: keepsResults, selection: selection, tick: tick,
                      minute: Int((now.timeIntervalSinceReferenceDate / 60).rounded(.down)),
                      timeZone: calendar.timeZone)
        if let snapshot, key == self.key { return snapshot }
        if sortedRevision != revision {
            sorted = StatisticsList.sorted(records: records, drops: drops)
            sortedRevision = revision
            sorts += 1
        }
        let history = StatisticsHistory(records: records, drops: drops, keepsResults: keepsResults, now: now,
                                        calendar: calendar)
        let range = selection.range(now: now, oldest: history.oldest, calendar: calendar)
        let made = Snapshot(
            now: now, history: history, range: range,
            statistics: HackStatistics(records: records, drops: drops, range: range, history: history, now: now,
                                       calendar: calendar),
            ticks: StatisticsTimeline.Tick.ticks(records.map(\.date)),
            list: StatisticsList(all: sorted, range: range, calendar: calendar))
        self.key = key
        snapshot = made
        snapshots += 1
        return made
    }
}
