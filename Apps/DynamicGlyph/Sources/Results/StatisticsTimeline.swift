import Foundation

/// The Statistics timeline bar's scale, without SwiftUI: which zones it has
/// and how wide, where a time sits on it and back, what a handle snaps to,
/// the grid between snaps, and the zoomed scale when the handles are close.
///
/// Positions are points from the bar's left end (0) to its right end
/// (`width`), the knob insets left out. Time runs linearly inside each
/// zone, and a point in the gap between two zones belongs to their shared
/// edge.
struct StatisticsTimeline: Equatable, Sendable {
    enum ZoneKind: Hashable, Sendable {
        /// The normal bar: the oldest record to now − 24 h, to now − 1 h, to now.
        case older, lastDay, lastHour
        /// The zoomed bar: before the focus window, the window, after it.
        case leftStrip, focus, rightStrip
    }

    /// Where a handle lands when nothing is near enough to snap to.
    enum Grid: Hashable, Sendable {
        case minute, quarterHour, midnight
    }

    enum Handle: Hashable, Sendable {
        case start, end
    }

    struct Zone: Hashable, Sendable {
        let kind: ZoneKind
        let start: Date
        let end: Date
        let minX: Double
        let maxX: Double

        var width: Double { maxX - minX }
        var isStrip: Bool { kind == .leftStrip || kind == .rightStrip }

        var grid: Grid {
            switch kind {
            case .older, .leftStrip: return .midnight
            case .lastDay, .rightStrip: return .quarterHour
            case .lastHour, .focus: return .minute
            }
        }

        /// The label over the zone on the normal bar.
        var label: StatisticsRange.Preset? {
            switch kind {
            case .older: return .all
            case .lastDay: return .last24Hours
            case .lastHour: return .lastHour
            case .leftStrip, .focus, .rightStrip: return nil
            }
        }

        func contains(_ date: Date) -> Bool { start <= date && date <= end }

        func x(for date: Date) -> Double {
            let length = end.timeIntervalSince(start)
            guard length > 0 else { return minX }
            let fraction = min(max(date.timeIntervalSince(start) / length, 0), 1)
            return minX + fraction * width
        }

        func date(atX x: Double) -> Date {
            guard width > 0 else { return start }
            let fraction = min(max((x - minX) / width, 0), 1)
            return start.addingTimeInterval(fraction * end.timeIntervalSince(start))
        }
    }

    /// A section edge, which the handles snap to: the bar's left end (All),
    /// now − 24 h and now − 1 h.
    struct Edge: Hashable, Sendable {
        let preset: StatisticsRange.Preset
        let date: Date
    }

    /// The records of one minute, which share a tick.
    struct Tick: Hashable, Sendable, Identifiable {
        /// The minute, to the second.
        let minute: Date
        /// The earliest and latest record in it.
        let first: Date
        let last: Date

        var id: Date { minute }
        /// A start snapped here includes every record of the minute.
        var startTarget: Date { first }
        /// An end snapped here is the next whole minute, so every record of
        /// the minute is included, the end being left out.
        var endTarget: Date { minute.addingTimeInterval(60) }

        /// One tick per minute, oldest first.
        static func ticks(_ dates: [Date]) -> [Tick] {
            var byMinute: [Date: (Date, Date)] = [:]
            for date in dates {
                let minute = StatisticsTimeline.floorMinute(date)
                let known = byMinute[minute]
                byMinute[minute] = (min(known?.0 ?? date, date), max(known?.1 ?? date, date))
            }
            return byMinute.map { Tick(minute: $0.key, first: $0.value.0, last: $0.value.1) }
                .sorted { $0.minute < $1.minute }
        }
    }

    /// The zoomed bar's focus window, chosen when it zooms in.
    struct Zoom: Hashable, Sendable {
        let start: Date
        /// Nil follows now: the end was live.
        let end: Date?

        /// `span` is the range's length, `pad` half of it but at least 5
        /// minutes, on each side, within the oldest record and now.
        static func around(_ selection: StatisticsSelection, lower: Date, now: Date) -> Zoom {
            let end = selection.endDate(now: now)
            let pad = max(end.timeIntervalSince(selection.start) * 0.5, 5 * 60)
            let start = max(lower, selection.start.addingTimeInterval(-pad))
            return Zoom(start: start, end: selection.isLive ? nil : min(now, end.addingTimeInterval(pad)))
        }
    }

    /// What a dragged handle lands on, in the order it is looked for.
    enum Target: Hashable, Sendable {
        /// The end at the bar's right end: now, live.
        case live
        case edge(Edge)
        case hack(Tick)
        case grid(Date, Grid)
    }

    static let gap = 4.0
    static let snapRadius = 12.0
    static let liveEdge = 12.0
    /// On the normal bar, handles closer than this zoom in.
    static let closeDistance = 44.0
    static let stripShare = 0.08

    let zones: [Zone]
    let width: Double
    /// The bar's left end: the oldest record, or a minute before now if it
    /// is newer, so there is room for a range.
    let lower: Date
    let now: Date
    let isEmpty: Bool
    /// The section edges a handle snaps to on this bar.
    let edges: [Edge]
    let zoom: Zoom?
    let calendar: Calendar

    var isZoomed: Bool { zoom != nil }
    /// The zoomed bar's middle zone.
    var focus: Zone? { zones.first { $0.kind == .focus } }

    static func lowerBound(oldest: Date?, now: Date) -> Date {
        min(oldest ?? now, now.addingTimeInterval(-StatisticsSelection.minimumLength))
    }

    /// The normal bar, or the zoomed one with `zoom`. With nothing kept the
    /// bar is one empty zone.
    init(oldest: Date?, now: Date, width: Double, zoom: Zoom? = nil, calendar: Calendar = .current) {
        self.width = max(width, 0)
        self.now = now
        self.calendar = calendar
        let lower = Self.lowerBound(oldest: oldest, now: now)
        self.lower = lower
        isEmpty = oldest == nil
        let normal = Self.normalSections(lower: lower, now: now)
        guard oldest != nil, let zoom else {
            self.zoom = nil
            zones = Self.layout(oldest == nil ? [(.older, now, now, 1)] : normal.sections, width: self.width)
            edges = oldest == nil ? [] : normal.edges
            return
        }
        self.zoom = zoom
        let fb = min(zoom.end ?? now, now)
        let fa = min(max(zoom.start, lower), fb.addingTimeInterval(-StatisticsSelection.minimumLength))
        // A strip within a minute of its end is left out: the middle takes it.
        let left = fa.timeIntervalSince(lower) > 60
        let right = now.timeIntervalSince(fb) > 60
        let middleShare = 1 - Self.stripShare * Double((left ? 1 : 0) + (right ? 1 : 0))
        var sections: [(ZoneKind, Date, Date, Double)] = []
        if left { sections.append((.leftStrip, lower, fa, Self.stripShare)) }
        let middle = (left ? fa : lower)...(right ? fb : now)
        sections.append((.focus, middle.lowerBound, middle.upperBound, middleShare))
        if right { sections.append((.rightStrip, fb, now, Self.stripShare)) }
        zones = Self.layout(sections, width: self.width)
        // Section edges snap only inside the middle.
        edges = normal.edges.filter { middle.contains($0.date) }
    }

    /// 46 · 30 · 24 % over a day of history, 56 · 44 % over an hour, else one zone.
    private static func normalSections(lower: Date, now: Date)
        -> (sections: [(ZoneKind, Date, Date, Double)], edges: [Edge]) {
        let history = now.timeIntervalSince(lower)
        let dayAgo = now.addingTimeInterval(-86_400), hourAgo = now.addingTimeInterval(-3_600)
        let oldest = Edge(preset: .all, date: lower)
        if history > 86_400 {
            return ([(.older, lower, dayAgo, 0.46), (.lastDay, dayAgo, hourAgo, 0.30), (.lastHour, hourAgo, now, 0.24)],
                    [oldest, Edge(preset: .last24Hours, date: dayAgo), Edge(preset: .lastHour, date: hourAgo)])
        }
        if history > 3_600 {
            return ([(.older, lower, hourAgo, 0.56), (.lastHour, hourAgo, now, 0.44)],
                    [oldest, Edge(preset: .lastHour, date: hourAgo)])
        }
        return ([(.older, lower, now, 1)], [oldest])
    }

    private static func layout(_ sections: [(ZoneKind, Date, Date, Double)], width: Double) -> [Zone] {
        let total = max(width - gap * Double(sections.count - 1), 0)
        var x = 0.0
        return sections.enumerated().map { index, section in
            let zoneWidth = index == sections.count - 1 ? max(width - x, 0) : total * section.3
            defer { x += zoneWidth + gap }
            return Zone(kind: section.0, start: section.1, end: section.2, minX: x, maxX: x + zoneWidth)
        }
    }

    // MARK: Mapping

    /// The zone a time is drawn in: on an edge between two zones, the later one.
    func zone(for date: Date) -> Zone? {
        zones.last { $0.start <= date } ?? zones.first
    }

    func x(for date: Date) -> Double {
        zone(for: date)?.x(for: date) ?? 0
    }

    /// The zone under `x`; in a gap, the nearer of the two.
    func zone(atX x: Double) -> Zone? {
        if let inside = zones.first(where: { $0.minX <= x && x <= $0.maxX }) { return inside }
        guard let first = zones.first, let last = zones.last else { return nil }
        if x < first.minX { return first }
        if x > last.maxX { return last }
        let before = zones.last { $0.maxX < x }, after = zones.first { $0.minX > x }
        guard let before, let after else { return before ?? after }
        return x - before.maxX <= after.minX - x ? before : after
    }

    /// The time under `x`. A point in a gap is the edge the two zones share.
    func date(atX x: Double) -> Date {
        zone(atX: x)?.date(atX: x) ?? now
    }

    /// Points from `x` to `date` on the bar: 0 anywhere in the gap at an
    /// edge between zones, which both sides of count as the edge.
    func distance(fromX x: Double, to date: Date) -> Double {
        let xs = zones.filter { $0.contains(date) }.map { $0.x(for: date) }
        guard let low = xs.min(), let high = xs.max() else { return .infinity }
        if low <= x && x <= high { return 0 }
        return min(abs(x - low), abs(x - high))
    }

    func grid(for date: Date) -> Grid {
        if !isZoomed && now.timeIntervalSince(lower) <= 3600 { return .minute }
        return zone(for: date)?.grid ?? .minute
    }

    // MARK: Snapping

    /// What a handle dragged to `x` lands on: for the end, the live edge
    /// first; then a section edge within 12 points, unless a hack is
    /// nearer; then the nearest hack within 12 points; else the grid.
    func target(for handle: Handle, atX x: Double, ticks: [Tick]) -> Target {
        if handle == .end && x >= width - Self.liveEdge { return .live }
        let edge = edges.map { ($0, distance(fromX: x, to: $0.date)) }
            .filter { $0.1 <= Self.snapRadius }
            .min { $0.1 < $1.1 }
        let hack = ticks.map { ($0, abs(self.x(for: $0.first) - x)) }
            .filter { $0.1 <= Self.snapRadius }
            .min { $0.1 < $1.1 }
        // An edge as near as a hack wins.
        if let edge, edge.1 <= (hack?.1 ?? .infinity) { return .edge(edge.0) }
        if let hack { return .hack(hack.0) }
        let zone = zone(atX: x)
        let grid: Grid = !isZoomed && now.timeIntervalSince(lower) <= 3600 ? .minute : zone?.grid ?? .minute
        let raw = date(atX: x)
        var snapped = Self.nearest(raw, on: grid, calendar: calendar)
        if let zone { snapped = min(max(snapped, zone.start), zone.end) }
        return .grid(snapped, grid)
    }

    /// The handle a touch at `x` takes: the nearer one; on a tie, the start
    /// if the touch is left of it, otherwise the end.
    static func handle(nearestTo x: Double, startX: Double, endX: Double) -> Handle {
        let toStart = abs(x - startX), toEnd = abs(x - endX)
        if toStart != toEnd { return toStart < toEnd ? .start : .end }
        return x < startX ? .start : .end
    }

    // MARK: Zoom

    /// Whether the handles are less than 44 points apart on the normal bar:
    /// the one rule for zooming in and out.
    func isClose(_ selection: StatisticsSelection) -> Bool {
        abs(x(for: selection.endDate(now: now)) - x(for: selection.start)) < Self.closeDistance
    }

    /// The zoom once a drag ends with a handle at `x` on this bar: out when
    /// it ends in a side strip, else in around the handles where they are
    /// close on `normal`, else out.
    func zoomAfterRelease(_ selection: StatisticsSelection, atX x: Double?,
                          normal: StatisticsTimeline) -> Zoom? {
        if isZoomed, let x, zone(atX: x)?.isStrip == true { return nil }
        return normal.isClose(selection) ? Zoom.around(selection, lower: normal.lower, now: normal.now) : nil
    }

    /// The zoom after the finger rests 0.4 s at `x` mid-drag: in where the
    /// handles are close on the normal bar, out in a side strip; nil where
    /// it stays as it is.
    func zoomAfterRest(_ selection: StatisticsSelection, atX x: Double,
                       normal: StatisticsTimeline) -> Zoom?? {
        if isZoomed {
            return zone(atX: x)?.isStrip == true ? .some(nil) : nil
        }
        return normal.isClose(selection) ? .some(Zoom.around(selection, lower: normal.lower, now: normal.now)) : nil
    }

    // MARK: VoiceOver

    /// One adjustable step: to the next or previous hack, by the snapping
    /// rule; with none that way, one grid unit of the zone the handle is in.
    /// The end stepped past the last hack is live. Kept within the bar and
    /// a minute apart.
    func stepped(_ selection: StatisticsSelection, _ handle: Handle, forward: Bool,
                 ticks: [Tick]) -> StatisticsSelection {
        var moved = selection
        switch handle {
        case .start:
            let current = selection.start
            let hack = forward ? ticks.map(\.startTarget).filter { $0 > current }.min()
                : ticks.map(\.startTarget).filter { $0 < current }.max()
            let grid = grid(for: current)
            let date = hack ?? (forward ? Self.next(after: current, on: grid, calendar: calendar)
                                : Self.previous(before: current, on: grid, calendar: calendar))
            moved.place(.start, at: date, lower: lower, now: now)
        case .end:
            let current = selection.endDate(now: now)
            if forward {
                guard !selection.isLive else { return selection }
                if let hack = ticks.map(\.endTarget).filter({ $0 > current }).min(), hack < now {
                    moved.place(.end, at: hack, lower: lower, now: now)
                } else {
                    moved.place(.end, at: nil, lower: lower, now: now)
                }
            } else {
                let grid = grid(for: current)
                let date = ticks.map(\.endTarget).filter { $0 < current }.max()
                    ?? Self.previous(before: current, on: grid, calendar: calendar)
                moved.place(.end, at: date, lower: lower, now: now)
            }
        }
        return moved
    }

    // MARK: Grid

    static func floorMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// The grid point at or before `date`: local minutes, quarter hours and
    /// calendar midnights.
    static func floor(_ date: Date, on grid: Grid, calendar: Calendar) -> Date {
        switch grid {
        case .minute:
            return calendar.dateInterval(of: .minute, for: date)?.start ?? floorMinute(date)
        case .quarterHour:
            let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            return hour.addingTimeInterval((date.timeIntervalSince(hour) / 900).rounded(.down) * 900)
        case .midnight:
            return calendar.startOfDay(for: date)
        }
    }

    /// The grid point after the grid point `point`: midnights by calendar
    /// day, so a daylight-saving day is 23 or 25 hours.
    private static func step(_ point: Date, on grid: Grid, by sign: Int, calendar: Calendar) -> Date {
        switch grid {
        case .minute: return point.addingTimeInterval(Double(sign) * 60)
        case .quarterHour: return point.addingTimeInterval(Double(sign) * 900)
        case .midnight:
            let day = calendar.date(byAdding: .day, value: sign, to: point) ?? point.addingTimeInterval(Double(sign) * 86_400)
            return calendar.startOfDay(for: day)
        }
    }

    static func nearest(_ date: Date, on grid: Grid, calendar: Calendar) -> Date {
        let below = floor(date, on: grid, calendar: calendar)
        let above = step(below, on: grid, by: 1, calendar: calendar)
        return date.timeIntervalSince(below) <= above.timeIntervalSince(date) ? below : above
    }

    static func next(after date: Date, on grid: Grid, calendar: Calendar) -> Date {
        step(floor(date, on: grid, calendar: calendar), on: grid, by: 1, calendar: calendar)
    }

    static func previous(before date: Date, on grid: Grid, calendar: Calendar) -> Date {
        let below = floor(date, on: grid, calendar: calendar)
        return below < date ? below : step(below, on: grid, by: -1, calendar: calendar)
    }
}

extension StatisticsSelection {
    /// Moves one handle to `date` (nil: the end live), kept within `lower`
    /// … `now` and at least a minute from the other. Any move leaves the
    /// preset tapped. Returns whether the handle was held back.
    @discardableResult
    mutating func place(_ handle: StatisticsTimeline.Handle, at date: Date?, lower: Date, now: Date) -> Bool {
        chosen = nil
        switch handle {
        case .start:
            let wanted = date ?? now
            let limit = endDate(now: now).addingTimeInterval(-Self.minimumLength)
            start = min(max(wanted, lower), limit)
            return start != wanted
        case .end:
            guard let date else {
                end = .live
                return false
            }
            let placed = max(min(date, now), start.addingTimeInterval(Self.minimumLength))
            end = .at(placed)
            return placed != date
        }
    }

    /// Moves one handle to what it snapped to.
    @discardableResult
    mutating func place(_ handle: StatisticsTimeline.Handle, on target: StatisticsTimeline.Target,
                        lower: Date, now: Date) -> Bool {
        switch target {
        case .live:
            return place(handle, at: handle == .end ? nil : now, lower: lower, now: now)
        case .edge(let edge):
            return place(handle, at: edge.date, lower: lower, now: now)
        case .hack(let tick):
            return place(handle, at: handle == .start ? tick.startTarget : tick.endTarget, lower: lower, now: now)
        case .grid(let date, _):
            return place(handle, at: date, lower: lower, now: now)
        }
    }
}
