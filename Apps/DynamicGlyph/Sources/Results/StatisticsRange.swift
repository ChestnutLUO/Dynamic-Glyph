import Foundation

/// The span the Statistics page shows, resolved from the timeline's
/// handles at a moment: a preset (Day, 7 days, 30 days, All records, Last
/// 24 hours, Last hour) while the handles still stand for one, or any other
/// range. Every figure, chart, the results list and Export use the same
/// `interval`, start included and end left out.
///
/// Day, 7 days and 30 days are local calendar days, ending tonight: their
/// ends are local midnights, so a day across a daylight-saving change is 23
/// or 25 hours long, and they compare with the same calendar days before.
/// Every other range is timed and compares with the same elapsed length
/// just before it.
///
/// App only: the Home Screen widget keeps its own `StatisticsPeriod`.
struct StatisticsRange: Hashable, Sendable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case day, sevenDays, thirtyDays, all, last24Hours, lastHour
        var id: Self { self }

        /// The period segments above the timeline.
        static let segments: [Preset] = [.day, .sevenDays, .thirtyDays]
        /// The timeline's zone labels, oldest first.
        static let zoneLabels: [Preset] = [.all, .last24Hours, .lastHour]

        /// Local calendar days, ending today; nil for the others.
        var days: Int? {
            switch self {
            case .day: return 1
            case .sevenDays: return 7
            case .thirtyDays: return 30
            case .all, .last24Hours, .lastHour: return nil
            }
        }

        /// Elapsed length for Last 24 hours and Last hour; nil for the others.
        var duration: TimeInterval? {
            switch self {
            case .last24Hours: return 86_400
            case .lastHour: return 3_600
            case .day, .sevenDays, .thirtyDays, .all: return nil
            }
        }

        /// The widget's periods, for its link into Statistics.
        init(_ period: StatisticsPeriod) {
            switch period {
            case .today: self = .day
            case .week: self = .sevenDays
            case .all: self = .all
            }
        }

        /// Where the preset starts at `now`, before it is kept within the
        /// records: midnight for the days, `oldest` for All.
        func rawStart(now: Date, oldest: Date?, calendar: Calendar = .current) -> Date {
            let today = calendar.startOfDay(for: now)
            if let days {
                return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            }
            if let duration { return now.addingTimeInterval(-duration) }
            return oldest ?? today
        }

        /// Where tapping the preset puts the start: its own start, but never
        /// before the oldest record kept, and at least a minute before now.
        func start(now: Date, oldest: Date?, calendar: Calendar = .current) -> Date {
            var start = rawStart(now: now, oldest: oldest, calendar: calendar)
            if let oldest { start = max(start, oldest) }
            return min(start, now.addingTimeInterval(-StatisticsSelection.minimumLength))
        }
    }

    /// The preset the handles stand for; nil for any other range.
    let preset: Preset?
    /// Start included, end left out; nil for All records, which is everything kept.
    let interval: Range<Date>?
    /// Both ends are local midnights: Day, 7 days and 30 days.
    let wholeDays: Bool
    /// The end follows now.
    let isLive: Bool

    init(preset: Preset?, interval: Range<Date>?, wholeDays: Bool, isLive: Bool = false) {
        self.preset = preset
        self.interval = interval
        self.wholeDays = wholeDays
        self.isLive = isLive
    }

    static let all = StatisticsRange(preset: .all, interval: nil, wholeDays: true, isLive: true)

    /// The preset at `now`: Day, 7 days and 30 days as today and the days
    /// before it, through tonight; Last… as the hours ending `now`.
    static func preset(_ preset: Preset, endingOn now: Date, calendar: Calendar = .current) -> StatisticsRange {
        if let count = preset.days {
            return StatisticsRange(preset: preset, interval: days(endingOn: now, count: count, calendar: calendar),
                                   wholeDays: true, isLive: true)
        }
        if let duration = preset.duration {
            return StatisticsRange(preset: preset, interval: now.addingTimeInterval(-duration)..<now,
                                   wholeDays: false, isLive: true)
        }
        return .all
    }

    /// From `start` until `end`, which is left out: a timed range.
    static func timed(from start: Date, until end: Date, isLive: Bool = false) -> StatisticsRange? {
        guard start < end else { return nil }
        return StatisticsRange(preset: nil, interval: start..<end, wholeDays: false, isLive: isLive)
    }

    private static func days(endingOn day: Date, count: Int, calendar: Calendar) -> Range<Date> {
        let last = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: last) ?? last
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return start..<end
    }

    var isAll: Bool { interval == nil }

    func contains(_ date: Date) -> Bool { interval?.contains(date) ?? true }

    /// Calendar dates covered, both ends included; nil for All and a timed range.
    func dayCount(calendar: Calendar = .current) -> Int? {
        guard wholeDays, let interval else { return nil }
        return calendar.dateComponents([.day], from: interval.lowerBound, to: interval.upperBound).day
    }

    /// Elapsed seconds; nil for All.
    var duration: TimeInterval? { interval.map { $0.upperBound.timeIntervalSince($0.lowerBound) } }

    /// Up to 48 hours: charts count per hour and compare bonuses by length.
    /// Two calendar days count, even when a clock change makes them 49 hours.
    func isShort(calendar: Calendar = .current) -> Bool {
        if let days = dayCount(calendar: calendar) { return days <= 2 }
        return duration.map { $0 <= 48 * 3_600 } ?? false
    }

    /// The first day's midnight, or a timed range's start; nil for All.
    var firstDay: Date? { interval?.lowerBound }

    /// The last day included (its midnight); nil for All.
    func lastDay(calendar: Calendar = .current) -> Date? {
        guard let interval else { return nil }
        if wholeDays { return calendar.date(byAdding: .day, value: -1, to: interval.upperBound) }
        // A timed range ending at midnight doesn't reach into that day.
        return calendar.startOfDay(for: interval.upperBound.addingTimeInterval(-1))
    }

    /// The same length moved `steps` whole lengths: back when negative.
    /// Whole days move by the range's count of calendar days and keep their
    /// preset; a timed range moves by its elapsed seconds and is no preset
    /// and not live. Nil for All.
    func shifted(by steps: Int, calendar: Calendar = .current) -> StatisticsRange? {
        guard let interval else { return nil }
        if wholeDays {
            guard let count = dayCount(calendar: calendar),
                  let start = calendar.date(byAdding: .day, value: steps * count, to: interval.lowerBound),
                  let end = calendar.date(byAdding: .day, value: steps * count, to: interval.upperBound)
            else { return nil }
            return StatisticsRange(preset: preset, interval: start..<end, wholeDays: true)
        }
        let length = interval.upperBound.timeIntervalSince(interval.lowerBound) * Double(steps)
        return StatisticsRange(preset: nil, interval: interval.lowerBound.addingTimeInterval(length)
                                   ..< interval.upperBound.addingTimeInterval(length), wholeDays: false)
    }

    /// What the range is compared with: the same calendar days before Day,
    /// 7 days and 30 days, [start − length, start) for a timed range, its
    /// current length when live. Nil for All records.
    func comparisonInterval(calendar: Calendar = .current) -> Range<Date>? {
        if isLive, !wholeDays, let preset, preset.days != nil, let interval {
            return Self.preset(preset, endingOn: interval.upperBound, calendar: calendar)
                .shifted(by: -1, calendar: calendar)?.interval
        }
        if preset == .all { return nil }
        return shifted(by: -1, calendar: calendar)?.interval
    }

    /// The records and drops inside the range, as totals, charts, the list
    /// and Export all count them.
    func filter(records: [HackResultRecord], drops: [GearDropRecord]) -> ([HackResultRecord], [GearDropRecord]) {
        (records.filter { contains($0.date) }, drops.filter { contains($0.date) })
    }
}

/// Where the timeline's two handles stand: what the player chose, kept
/// apart from any moment. Resolved against now and the oldest record kept
/// into the `StatisticsRange` the page shows.
///
/// A live end keeps ending at now, so the range grows; a frozen end never
/// moves. The start never rolls: a preset stops being that preset once its
/// own start moves on (Last hour after a minute, Day at midnight), so
/// nothing moves under the player.
struct StatisticsSelection: Hashable, Sendable {
    enum End: Hashable, Sendable {
        case live
        case at(Date)
    }

    /// The start and end are always at least this far apart.
    static let minimumLength: TimeInterval = 60

    var start: Date
    var end: End
    /// The preset last tapped. Where the oldest record clamps several to the
    /// same start, this one keeps its name.
    var chosen: StatisticsRange.Preset?

    init(start: Date, end: End, chosen: StatisticsRange.Preset? = nil) {
        self.start = start
        self.end = end
        self.chosen = chosen
    }

    var isLive: Bool { end == .live }

    func endDate(now: Date) -> Date {
        switch end {
        case .live: return now
        case .at(let date): return date
        }
    }

    /// A preset tapped at `now`: its start, kept within the records, and a live end.
    static func preset(_ preset: StatisticsRange.Preset, now: Date, oldest: Date?,
                       calendar: Calendar = .current) -> StatisticsSelection {
        StatisticsSelection(start: preset.start(now: now, oldest: oldest, calendar: calendar), end: .live,
                            chosen: preset)
    }

    /// Whether the handles still stand for `preset`: the end is live and the
    /// start is the preset's start. A preset whose own start is at or before
    /// the oldest record matches any start there. Last 24 hours and Last hour
    /// match only while their displayed minute bounds still span that duration.
    func matches(_ preset: StatisticsRange.Preset, now: Date, oldest: Date?, calendar: Calendar = .current) -> Bool {
        guard isLive else { return false }
        let expected = preset.start(now: now, oldest: oldest, calendar: calendar)
        if preset.duration != nil {
            let behind = expected.timeIntervalSince(start)
            // The readout hides seconds. Once the displayed start and end
            // span more than the preset, show the actual live range instead.
            return behind >= 0 && calendar.dateInterval(of: .minute, for: expected)?.start
                == calendar.dateInterval(of: .minute, for: start)?.start
        }
        return start == expected
    }

    /// The preset the readout names and the segment or label selected: the
    /// one last tapped while it matches, else the first that does.
    func matchedPreset(now: Date, oldest: Date?, calendar: Calendar = .current) -> StatisticsRange.Preset? {
        if let chosen {
            return matches(chosen, now: now, oldest: oldest, calendar: calendar) ? chosen : nil
        }
        let order: [StatisticsRange.Preset] = [.all, .last24Hours, .lastHour, .day, .sevenDays, .thirtyDays]
        return order.first { matches($0, now: now, oldest: oldest, calendar: calendar) }
    }

    /// The range shown at `now`. A matched Day, 7 days or 30 days is its
    /// whole calendar days, even where the records start later.
    func range(now: Date, oldest: Date?, calendar: Calendar = .current) -> StatisticsRange {
        guard let preset = matchedPreset(now: now, oldest: oldest, calendar: calendar) else {
            let end = max(endDate(now: now), start.addingTimeInterval(1))
            return StatisticsRange(preset: nil, interval: start..<end, wholeDays: false, isLive: isLive)
        }
        return StatisticsRange(preset: preset, interval: start..<max(endDate(now: now), start.addingTimeInterval(1)),
                               wholeDays: false, isLive: isLive)
    }
}

/// What history this iPhone keeps, stream by stream. Hacks are every hack
/// result kept. Drops are the gear drops kept: a hack's gear reading, or a
/// group of item panels no hack claimed. Items come from both, so a drop
/// comparison needs both stores complete; each store is trimmed on its own,
/// at 90 days or 1,000 records, so one reaching back says nothing about the
/// other.
struct StatisticsHistory: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        /// The local day of the oldest record kept.
        let oldestDay: Date
        /// The oldest record's own time.
        let oldest: Date
        /// Older records may have been removed, so the oldest day itself may
        /// be only partly kept.
        let mayBeTrimmed: Bool

        init(oldestDay: Date, oldest: Date? = nil, mayBeTrimmed: Bool) {
            self.oldestDay = oldestDay
            self.oldest = oldest ?? oldestDay
            self.mayBeTrimmed = mayBeTrimmed
        }
    }

    let hacks: Stream?
    let drops: Stream?
    /// From here on, the drops kept can be taken as complete: both stores
    /// that hold gear are, from their own trimmed days on.
    let dropsCompleteFrom: Date?
    /// The local day of the newest record either keeps.
    let newestDay: Date?
    /// Midnight starting today.
    let today: Date
    /// When the history was read: a timed range can't end after it.
    let now: Date

    init(hacks: Stream?, drops: Stream?, newestDay: Date?, now: Date, dropsCompleteFrom: Date? = nil,
         calendar: Calendar = .current) {
        self.hacks = hacks
        self.drops = drops
        self.newestDay = newestDay
        self.now = now
        self.dropsCompleteFrom = dropsCompleteFrom ?? Self.completeFrom(drops, calendar: calendar)
        today = calendar.startOfDay(for: now)
    }

    /// `keepsResults` off: only this run's results are here, so nothing
    /// before them can be assumed complete.
    init(records: [HackResultRecord], drops: [GearDropRecord], keepsResults: Bool,
         retention: HackResultStore.Retention = HackResultStore.Retention(), now: Date,
         calendar: Calendar = .current) {
        let cutoffDay = calendar.startOfDay(for: now.addingTimeInterval(-retention.maximumAge))
        func stream(_ dates: [Date], count: Int) -> Stream? {
            guard let oldest = dates.min() else { return nil }
            let day = calendar.startOfDay(for: oldest)
            return Stream(oldestDay: day, oldest: oldest,
                          mayBeTrimmed: !keepsResults || count >= retention.maximumCount || day <= cutoffDay)
        }
        let hackStream = stream(records.map(\.date), count: records.count)
        let dropRecords = stream(drops.map(\.date), count: drops.count)
        // A hack's gear is a drop: hacks with a reading, read or not.
        let gearDates = records.filter { $0.gear != nil }.map(\.date) + drops.map(\.date)
        var dropStream: Stream?
        if let oldest = gearDates.min() {
            let trimmed = [hackStream, dropRecords].contains { $0?.mayBeTrimmed == true }
            dropStream = Stream(oldestDay: calendar.startOfDay(for: oldest), oldest: oldest, mayBeTrimmed: trimmed)
        }
        // Where either store was trimmed, its removed records may have held
        // gear: drops are complete only after both trimmed days.
        let complete = ([dropStream.map(\.oldestDay)]
            + [hackStream, dropRecords].map { stream -> Date? in
                guard let stream, stream.mayBeTrimmed else { return nil }
                return Self.completeFrom(stream, calendar: calendar)
            }).compactMap { $0 }.max()
        let dates = records.map(\.date) + drops.map(\.date)
        self.init(hacks: hackStream, drops: dropStream, newestDay: dates.max().map(calendar.startOfDay), now: now,
                  dropsCompleteFrom: complete, calendar: calendar)
    }

    /// The oldest day either stream keeps: as far back as the page goes.
    /// Not proof that both are complete from there.
    var oldestDay: Date? { [hacks?.oldestDay, drops?.oldestDay].compactMap { $0 }.min() }
    /// The oldest record kept, of either stream.
    var oldest: Date? { [hacks?.oldest, drops?.oldest].compactMap { $0 }.min() }
    var isEmpty: Bool { hacks == nil && drops == nil }

    /// From here on, `stream` can be taken as complete: its oldest day, or
    /// the day after where that day may be partly removed.
    static func completeFrom(_ stream: Stream?, calendar: Calendar = .current) -> Date? {
        guard let stream else { return nil }
        return stream.mayBeTrimmed ? calendar.date(byAdding: .day, value: 1, to: stream.oldestDay) : stream.oldestDay
    }

    /// Whether the hacks just before `range` are all kept, so its figures
    /// can be compared with them. False for All, which has nothing before it.
    func hacksComparable(_ range: StatisticsRange, calendar: Calendar = .current) -> Bool {
        guard let previous = range.comparisonInterval(calendar: calendar),
              let complete = Self.completeFrom(hacks, calendar: calendar) else { return false }
        return previous.lowerBound >= complete
    }

    /// The same for the drops, whose items the Items dropped card compares.
    func dropsComparable(_ range: StatisticsRange, calendar: Calendar = .current) -> Bool {
        guard let previous = range.comparisonInterval(calendar: calendar), let dropsCompleteFrom else { return false }
        return previous.lowerBound >= dropsCompleteFrom
    }
}

/// What a card says when the range has none of its records. "No hacks in
/// this period." only where the range is kept and loaded: never for days
/// before the stream's history, with saving off before this run's first
/// record, with nothing saved, or when the store failed.
enum StatisticsEmptyReason: Equatable {
    /// Kept and loaded, and nothing there: "No hacks in this period."
    case noRecords
    /// The range ends before the stream's oldest record kept: "No hack
    /// history for this period."
    case beforeHistory
    /// Nothing kept yet: "No saved history yet."
    case nothingSaved
    /// Saving is off and the range reaches before this run's first record.
    case notKept
    /// The store reported a problem, so the records may be incomplete.
    case unavailable

    /// `stream` is the card's own: hacks for Hacks, drops for Items dropped.
    init(range: StatisticsRange, stream: StatisticsHistory.Stream?, history: StatisticsHistory,
         keepsResults: Bool, storeProblem: Bool) {
        if storeProblem {
            self = .unavailable
        } else if !keepsResults {
            // Only this run's records: nothing before the first is known.
            guard let first = history.oldest, let start = range.interval?.lowerBound, start >= first else {
                self = .notKept
                return
            }
            self = .noRecords
        } else if history.isEmpty {
            self = .nothingSaved
        } else if let stream, let end = range.interval?.upperBound, end <= stream.oldest {
            self = .beforeHistory
        } else {
            self = .noRecords
        }
    }
}

/// The Statistics toolbar. Export stays where it is and is only turned off
/// on an empty range, so the bar doesn't jump; Select needs something to
/// select.
struct StatisticsToolbarState: Equatable {
    let showsExport: Bool
    let exportEnabled: Bool
    let showsSelect: Bool

    init(shownEntries: Int, selecting: Bool) {
        showsExport = !selecting
        exportEnabled = shownEntries > 0
        showsSelect = shownEntries > 0
    }
}
