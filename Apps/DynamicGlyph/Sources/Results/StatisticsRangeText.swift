import Foundation

/// How a Statistics range reads: the readout over the cards, its spoken
/// form, the timeline's bubble and axis, the comparison's dates and Export's
/// scope. Dates follow the phone's locale, calendar, time zone and
/// 12/24-hour setting through the system's formatters; nothing is assembled
/// from month names or a fixed order.
enum StatisticsRangeText {
    /// The two lines under the timeline. Line 1 names a matched preset
    /// ("Last 7 days"), with the range on line 2 ("Oct 15, 12:00 AM – Now");
    /// any other range is line 1 alone. `isLive` adds the LIVE badge.
    struct Readout: Equatable {
        let line1: String
        let line2: String?
        let isLive: Bool
        /// One VoiceOver element: "Last 7 days, live. October 15, 12:00 AM to now."
        let spoken: String

        /// What Export says it holds: line 1, then line 2 in brackets.
        var exportScope: String {
            guard let line2 else { return line1 }
            return String(format: String(localized: "%1$@ (%2$@)",
                                         comment: "Export's scope: the Statistics readout's preset name, then its dates and times in brackets, such as Last 7 days (Oct 15, 12:00 AM – Now)."),
                          line1, line2)
        }
    }

    static func readout(_ selection: StatisticsSelection, now: Date, oldest: Date?,
                        calendar: Calendar = .current) -> Readout {
        let preset = selection.matchedPreset(now: now, oldest: oldest, calendar: calendar)
        let name = preset.map { String(localized: $0.readoutName) }
        let range: String, spokenRange: String
        if selection.isLive {
            let start = moment(selection.start, now: now, calendar: calendar, withDate: true)
            range = String(localized: "\(start) – Now",
                           comment: "Statistics readout: a range that keeps ending at the current time. The placeholder is its start date and time, such as Oct 15, 12:00 AM.")
            let spokenStart = spokenMoment(selection.start, now: now, calendar: calendar)
            spokenRange = String(localized: "\(spokenStart) to now",
                                 comment: "Statistics readout, for VoiceOver, when the range ends now: the placeholder is its spoken start date and time.")
        } else {
            let end = max(selection.endDate(now: now), selection.start.addingTimeInterval(1))
            range = timed(selection.start..<end, now: now, calendar: calendar)
            let thisYear = isThisYear(selection.start, now, calendar) && isThisYear(end, now, calendar)
            spokenRange = format(selection.start..<end, template: thisYear ? "MMMMdjmm" : "yMMMMdjmm",
                                 calendar: calendar, zone: zoneNeeded(selection.start..<end, calendar))
        }
        var spoken: String
        if selection.isLive {
            spoken = name.map { String(localized: "\($0), live",
                                       comment: "Statistics readout, for VoiceOver: the preset name of a range that keeps ending at the current time.") + ". " + spokenRange }
                ?? String(localized: "\(spokenRange), live",
                          comment: "Statistics readout, for VoiceOver: the preset name of a range that keeps ending at the current time.")
        } else {
            spoken = name.map { $0 + ". " + spokenRange } ?? spokenRange
        }
        if !spoken.hasSuffix(".") && !spoken.hasSuffix("。") { spoken += "." }
        return Readout(line1: name ?? range, line2: name == nil ? nil : range, isLive: selection.isLive,
                       spoken: spoken)
    }

    /// A time on the bar: "2:42 PM" today, "Oct 18, 2:42 PM" on other days,
    /// with the year outside this one. `withDate` keeps the date today too.
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current, withDate: Bool = false) -> String {
        let today = calendar.isDate(date, inSameDayAs: now)
        let template = today && !withDate ? "jmm" : isThisYear(date, now, calendar) ? "MMMdjmm" : "yMMMdjmm"
        return single(date, template: template, calendar: calendar)
    }

    /// A day on the bar: "Oct 8", "Sep 20, 2025".
    static func shortDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !isThisYear(date, now, calendar) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// A handle's value for VoiceOver: "October 21, 2:42 PM".
    static func spokenMoment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        single(date, template: isThisYear(date, now, calendar) ? "MMMMdjmm" : "yMMMMdjmm", calendar: calendar)
    }

    /// The interval compared with, as the readout would show it: "Up 2
    /// from Yesterday", "Down 1 from Oct 16, 6:00 – 10:00 PM". Nil for All.
    static func previous(_ range: StatisticsRange, history: StatisticsHistory, calendar: Calendar = .current) -> String? {
        guard range.preset != .all else { return nil }
        let source: StatisticsRange
        if range.isLive, let preset = range.preset, preset.days != nil {
            source = .preset(preset, endingOn: history.now, calendar: calendar)
        } else { source = range }
        guard let previous = source.shifted(by: -1, calendar: calendar), let interval = previous.interval else { return nil }
        if !previous.wholeDays {
            return timed(interval, now: history.now, calendar: calendar, timeOnlyToday: range.preset?.duration != nil)
        }
        return wholeDays(interval.lowerBound, previous.lastDay(calendar: calendar) ?? interval.lowerBound,
                         now: history.now, calendar: calendar)
    }

    // MARK: - Comparisons

    /// "Up 2 from Yesterday", "Down 3 pts from Oct 13 – 19", "Same as
    /// Yesterday": `amount` is already formatted, without its sign.
    static func change(_ amount: String, sign: Int, previous: String) -> String {
        String(changeAttributed(amount, sign: sign, previous: previous).characters)
    }

    /// The localized template marks the delta itself as emphasized. It stays
    /// attached to that argument through word-order changes and pluralization.
    /// Never search the rendered sentence: 8:28 may contain the same number.
    static func changeAttributed(_ amount: String, sign: Int, previous: String,
                                 locale: Locale = .current, bundle: Bundle = .main) -> AttributedString {
        if sign > 0 {
            return AttributedString(localized: "Up **\(amount)** from \(previous)",
                                    bundle: bundle, locale: locale,
                                    comment: "Statistics change. The first placeholder is the amount, the second the interval compared with, as the date line shows it, such as Yesterday or Oct 13 – 19.")
        }
        if sign < 0 {
            return AttributedString(localized: "Down **\(amount)** from \(previous)",
                                    bundle: bundle, locale: locale,
                                    comment: "Statistics change. The first placeholder is the amount, the second the interval compared with, as the date line shows it, such as Yesterday or Oct 13 – 19.")
        }
        // No emphasis here: the only argument is a date, not a delta.
        return AttributedString(localized: "Same as \(previous)", bundle: bundle, locale: locale,
                                comment: "Statistics change: none against the interval compared with, as the date line shows it.")
    }

    /// The Items dropped card's: "Up 12 items from Yesterday".
    static func itemChange(_ difference: Int, previous: String) -> String {
        String(itemChangeAttributed(difference, previous: previous).characters)
    }

    static func itemChangeAttributed(_ difference: Int, previous: String,
                                     locale: Locale = .current, bundle: Bundle = .main) -> AttributedString {
        let amount = abs(difference)
        if difference > 0 {
            return AttributedString(localized: "Up **\(amount)** items from \(previous)",
                                    bundle: bundle, locale: locale,
                                    comment: "Statistics, Items dropped: more items than in the interval compared with, as the date line shows it.")
        }
        if difference < 0 {
            return AttributedString(localized: "Down **\(amount)** items from \(previous)",
                                    bundle: bundle, locale: locale,
                                    comment: "Statistics, Items dropped: fewer items than in the interval compared with, as the date line shows it.")
        }
        return changeAttributed("", sign: 0, previous: previous, locale: locale, bundle: bundle)
    }

    /// The gear row's Other slot, for VoiceOver: "1 other item", "15 other
    /// items", by the items left, not the kinds.
    static func otherItems(_ count: Int) -> String {
        String(localized: "\(count) other items",
               comment: "Statistics gear row, for VoiceOver: the items of every kind not shown on its own.")
    }

    /// A chart bar's count, for VoiceOver: "0 items", "1 item".
    static func items(_ count: Int) -> String {
        String(localized: "\(count) items", comment: "Statistics gear: items recognized in the period.")
    }

    /// The part of its hour or day a chart bar covers, for VoiceOver:
    /// "4:43 – 5:00 PM" for a Last… choice's first hour, "2 – 3 PM" for a
    /// whole one, with the date where the chart crosses midnight; a whole
    /// day as "Oct 13", a part of one with its times.
    static func slotSpan(_ slot: HackStatistics.ItemSlot, hourly: Bool, withDate: Bool, now: Date = Date(),
                         calendar: Calendar = .current) -> String {
        let span = slot.span
        let zone = zoneNeeded(span, calendar)
        func onTheHour(_ date: Date) -> Bool {
            let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
            return parts.minute == 0 && parts.second == 0 && (parts.nanosecond ?? 0) < 1_000_000
        }
        if hourly {
            let time = onTheHour(span.lowerBound) && onTheHour(span.upperBound) ? "j" : "jmm"
            // A day's last hour ends at the next midnight. On a one-day chart
            // it reads like every other bar, "11 PM – 12 AM", times only.
            let crosses = !calendar.isDate(span.lowerBound, inSameDayAs: span.upperBound)
            if crosses && !withDate && !zone {
                return timesOnly(span, template: time, calendar: calendar)
            }
            return format(span, template: (withDate || crosses ? "MMMd" : "") + time, calendar: calendar, zone: zone)
        }
        let whole = calendar.dateInterval(of: .day, for: slot.start).map { $0.start..<$0.end == span } ?? true
        guard whole else {
            return format(span, template: isThisYear(span.lowerBound, now, calendar) ? "MMMdjmm" : "yMMMdjmm",
                          calendar: calendar, zone: zone)
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !isThisYear(slot.start, now, calendar) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return slot.start.formatted(style)
    }

    /// A history line's date, with its year: "Jul 23, 2026".
    static func historyDate(_ date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Labels only on actual bucket starts. Automatic ticks may fall on
    /// half-hours and then print the same hour twice with an hour-only format.
    /// At most four evenly spaced labels, retaining the first and last bucket.
    static func itemAxisDates(slots: [HackStatistics.ItemSlot]) -> [Date] {
        guard slots.count > 4 else { return slots.map(\.start) }
        return (0..<4).map { index in
            slots[Int((Double(index) * Double(slots.count - 1) / 3).rounded())].start
        }
    }

    // MARK: - Pieces

    /// One day as the date line says it, or both ends, with years where
    /// either isn't this year.
    static func wholeDays(_ first: Date, _ last: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(first, inSameDayAs: last) { return day(last, now: now, calendar: calendar) }
        let thisYear = isThisYear(first, now, calendar) && isThisYear(last, now, calendar)
        return format(first..<last, template: thisYear ? "MMMd" : "yMMMd", calendar: calendar)
    }

    static func day(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", comment: "Statistics date line: the day before today.")
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if !isThisYear(day, now, calendar) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// A timed range: the date once and both times on one day, date and
    /// time at both ends across midnight, years outside this year. A Last…
    /// choice within today shows only its times.
    static func timed(_ interval: Range<Date>, now: Date, calendar: Calendar, timeOnlyToday: Bool = false) -> String {
        let zone = zoneNeeded(interval, calendar)
        let end = interval.upperBound.addingTimeInterval(-1)
        if timeOnlyToday, calendar.isDate(interval.lowerBound, inSameDayAs: now),
           calendar.isDate(end, inSameDayAs: now) || calendar.isDate(interval.upperBound, inSameDayAs: now) {
            return format(interval, template: "jmm", calendar: calendar, zone: zone)
        }
        let thisYear = isThisYear(interval.lowerBound, now, calendar) && isThisYear(interval.upperBound, now, calendar)
        return format(interval, template: thisYear ? "MMMdjmm" : "yMMMdjmm", calendar: calendar, zone: zone)
    }

    /// Either end within an hour of a clock change, where a local time can
    /// stand for two instants (or none): both ends then name the zone.
    static func zoneNeeded(_ interval: Range<Date>, _ calendar: Calendar) -> Bool {
        let zone = calendar.timeZone
        return [interval.lowerBound, interval.upperBound].contains { instant in
            guard let change = zone.nextDaylightSavingTimeTransition(after: instant.addingTimeInterval(-3_600))
            else { return false }
            return abs(change.timeIntervalSince(instant)) < 3_600
        }
    }

    private static func isThisYear(_ date: Date, _ now: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }

    /// An interval that ends on the next date, written with times only:
    /// each end formatted on its own, joined by the separator the system
    /// interval formatter uses for this language ("–", "～", "至").
    static func timesOnly(_ interval: Range<Date>, template: String, calendar: Calendar,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? "j"
        let single = DateFormatter()
        single.calendar = calendar
        single.timeZone = calendar.timeZone
        single.locale = locale
        single.dateFormat = pattern
        let from = single.string(from: interval.lowerBound), to = single.string(from: interval.upperBound)
        // The separator, from a same-day morning-to-afternoon interval so
        // neither end's day period is merged away.
        let day = calendar.startOfDay(for: interval.lowerBound)
        let a = calendar.date(byAdding: .hour, value: 10, to: day) ?? day
        let b = calendar.date(byAdding: .hour, value: 14, to: day) ?? day
        let reference = DateIntervalFormatter()
        reference.calendar = calendar
        reference.timeZone = calendar.timeZone
        reference.locale = locale
        reference.dateTemplate = template
        let sample = reference.string(from: a, to: b)
        let ra = single.string(from: a), rb = single.string(from: b)
        var separator = "\u{2009}–\u{2009}"
        if sample.hasPrefix(ra), sample.hasSuffix(rb), sample.count > ra.count + rb.count {
            separator = String(sample.dropFirst(ra.count).dropLast(rb.count))
        }
        return from + separator + to
    }

    private static func single(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func format(_ interval: Range<Date>, template: String, calendar: Calendar,
                               zone: Bool = false) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateTemplate = zone ? template + "z" : template
        return formatter.string(from: interval.lowerBound, to: interval.upperBound)
    }
}

extension StatisticsRange.Preset {
    /// The segment's or zone label's name. Day and 7 days have their own
    /// keys: the widget's and Home's words for them are translated
    /// differently.
    var title: LocalizedStringResource {
        switch self {
        case .day: return LocalizedStringResource("statistics.range.day", defaultValue: "Day",
                                                  comment: "Statistics period segment: one calendar day.")
        case .sevenDays: return LocalizedStringResource("statistics.range.sevenDays", defaultValue: "7 days",
                                                        comment: "Statistics period segment: seven days ending on the shown day, not a calendar week.")
        case .thirtyDays: return LocalizedStringResource("30 days",
                                                         comment: "Statistics period segment: thirty days ending on the shown day, not a calendar month.")
        case .all: return LocalizedStringResource("All")
        case .last24Hours: return LocalizedStringResource("Last 24 hours", comment: "Statistics: the 24 elapsed hours ending now, a timeline zone label and the readout's name for it.")
        case .lastHour: return LocalizedStringResource("Last hour", comment: "Statistics: the 60 minutes ending now, a timeline zone label and the readout's name for it.")
        }
    }

    /// The readout's line 1, and the zone label's VoiceOver name.
    var readoutName: LocalizedStringResource {
        switch self {
        case .day: return LocalizedStringResource("Today")
        case .sevenDays: return LocalizedStringResource("Last 7 days", comment: "Statistics readout: the 7 days segment, today and the 6 days before it.")
        case .thirtyDays: return LocalizedStringResource("Last 30 days", comment: "Statistics readout: the 30 days segment, today and the 29 days before it.")
        case .all: return LocalizedStringResource("All records", comment: "Statistics readout and VoiceOver: every record kept on this iPhone, the All zone of the timeline.")
        case .last24Hours, .lastHour: return title
        }
    }
}
