import Foundation
import Testing

@Suite("Statistics timeline")
struct StatisticsTimelineTests {
    let now = Date(timeIntervalSinceReferenceDate: 814_363_200)
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
    func scale(_ age: Double, zoom: StatisticsTimeline.Zoom? = nil) -> StatisticsTimeline {
        StatisticsTimeline(oldest: ago(age), now: now, width: 337, zoom: zoom, calendar: calendar)
    }

    @Test("Zone thresholds and proportions", arguments: [3600.0, 3601, 86400, 86401, 90 * 86400])
    func zones(age: Double) {
        let bar = scale(age)
        let count = age > 86400 ? 3 : age > 3600 ? 2 : 1
        #expect(bar.zones.count == count)
        #expect(bar.zones.first?.minX == 0)
        #expect(bar.zones.last?.maxX == 337)
        #expect(abs(bar.zones.map(\.width).reduce(0, +) + Double(count - 1) * 4 - 337) < 0.001)
        let shares = count == 3 ? [0.46, 0.30, 0.24] : count == 2 ? [0.56, 0.44] : [1.0]
        for (zone, share) in zip(bar.zones, shares) {
            #expect(abs(zone.width / (337 - Double(count - 1) * 4) - share) < 0.001)
        }
    }

    @Test("Mapping round-trips and gaps map to shared boundaries")
    func mapping() {
        let bar = scale(90 * 86400)
        for zone in bar.zones {
            for f in [0.1, 0.5, 0.9] {
                let x = zone.minX + f * zone.width
                #expect(abs(bar.x(for: bar.date(atX: x)) - x) < 0.0001)
            }
        }
        for pair in zip(bar.zones, bar.zones.dropFirst()) {
            let x = (pair.0.maxX + pair.1.minX) / 2
            #expect(bar.date(atX: x) == pair.0.end)
            #expect(bar.distance(fromX: x, to: pair.0.end) == 0)
        }
    }

    @Test("Empty and very recent stores remain safe")
    func empty() {
        let bar = StatisticsTimeline(oldest: nil, now: now, width: 337)
        #expect(bar.isEmpty && bar.zones.count == 1 && bar.edges.isEmpty)
        let recent = scale(1)
        #expect(recent.lower == ago(60))
        let selection = StatisticsSelection.preset(.day, now: now, oldest: ago(1), calendar: calendar)
        #expect(selection.start == ago(60))
    }

    @Test("One tick per minute, exact inclusion targets")
    func ticks() throws {
        let minute = StatisticsTimeline.floorMinute(ago(1800))
        let ticks = StatisticsTimeline.Tick.ticks([minute.addingTimeInterval(40), minute, minute.addingTimeInterval(20)])
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.first == minute && tick.last == minute.addingTimeInterval(40))
        #expect(tick.startTarget == minute && tick.endTarget == minute.addingTimeInterval(60))
        var selection = StatisticsSelection(start: ago(3600), end: .at(ago(60)))
        selection.place(.end, on: .hack(tick), lower: ago(86400), now: now)
        #expect(selection.range(now: now, oldest: ago(86400)).contains(tick.last))
        #expect(!selection.range(now: now, oldest: ago(86400)).contains(tick.endTarget))
    }

    @Test("Live edge beats hacks, section edges win ties and both gap sides snap")
    func priorities() {
        let bar = scale(90 * 86400)
        let edge = bar.edges[1]
        let ticks = StatisticsTimeline.Tick.ticks([edge.date])
        #expect(bar.target(for: .start, atX: bar.x(for: edge.date), ticks: ticks) == .edge(edge))
        #expect(bar.target(for: .start, atX: bar.zones[0].maxX, ticks: ticks) == .edge(edge))
        #expect(bar.target(for: .end, atX: 330, ticks: StatisticsTimeline.Tick.ticks([ago(10)])) == .live)
        let hackDate = ago(1800)
        let tick = StatisticsTimeline.Tick.ticks([hackDate])[0]
        #expect(bar.target(for: .start, atX: bar.x(for: hackDate), ticks: [tick]) == .hack(tick))
    }

    @Test("Nearest handle and tie rule")
    func nearestHandle() {
        #expect(StatisticsTimeline.handle(nearestTo: 10, startX: 20, endX: 100) == .start)
        #expect(StatisticsTimeline.handle(nearestTo: 60, startX: 20, endX: 100) == .end)
        #expect(StatisticsTimeline.handle(nearestTo: 19, startX: 20, endX: 20) == .start)
    }

    @Test("Handles clamp without crossing; live grows and frozen does not")
    func clampingAndLive() {
        var selection = StatisticsSelection(start: ago(1800), end: .live)
        let startHeld = selection.place(.start, at: now, lower: ago(86400), now: now)
        #expect(startHeld)
        #expect(selection.start == ago(60))
        selection.place(.start, at: ago(1800), lower: ago(86400), now: now)
        let endHeld = selection.place(.end, at: ago(3600), lower: ago(86400), now: now)
        #expect(endHeld)
        #expect(selection.endDate(now: now) == ago(1740))
        let frozen = selection.range(now: now, oldest: ago(86400))
        #expect(selection.range(now: now.addingTimeInterval(120), oldest: ago(86400)) == frozen)
        selection.place(.end, at: nil, lower: ago(86400), now: now)
        #expect(selection.range(now: now.addingTimeInterval(120), oldest: ago(86400)).interval?.upperBound == now.addingTimeInterval(120))
        #expect(selection.start == ago(1800))
    }

    @Test("Preset names expire without moving the start")
    func presetExpiry() {
        let old = ago(90 * 86400)
        let hour = StatisticsSelection.preset(.lastHour, now: now, oldest: old, calendar: calendar)
        #expect(hour.matchedPreset(now: now, oldest: old, calendar: calendar) == .lastHour)
        #expect(hour.matchedPreset(now: now.addingTimeInterval(60), oldest: old, calendar: calendar) == nil)
        let day = StatisticsSelection.preset(.day, now: now, oldest: old, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        #expect(day.matchedPreset(now: tomorrow, oldest: old, calendar: calendar) == nil)
        #expect(day.range(now: now, oldest: old, calendar: calendar).interval == day.start..<now)
        #expect(day.range(now: tomorrow, oldest: old, calendar: calendar).interval?.lowerBound == day.start)
    }

    @Test("Clamped presets keep the tapped name and exact downstream bounds")
    func clampedPresets() {
        for preset in StatisticsRange.Preset.allCases {
            let selection = StatisticsSelection.preset(preset, now: now, oldest: ago(600), calendar: calendar)
            #expect(selection.matchedPreset(now: now, oldest: ago(600), calendar: calendar) == preset)
            #expect(selection.range(now: now, oldest: ago(600), calendar: calendar).interval == ago(600)..<now)
        }
    }

    @Test("Zoom padding, strip shares, omission and live focus")
    func zoomGeometry() throws {
        let selection = StatisticsSelection(start: ago(7200), end: .at(ago(7140)))
        let zoom = StatisticsTimeline.Zoom.around(selection, lower: ago(86400), now: now)
        #expect(zoom.start == ago(7500) && zoom.end == ago(6840))
        let bar = scale(86400, zoom: zoom)
        #expect(bar.zones.map(\.kind) == [.leftStrip, .focus, .rightStrip])
        #expect(abs(bar.zones[0].width / 329 - 0.08) < 0.00001)
        let focus = try #require(bar.focus)
        #expect(bar.edges.allSatisfy { focus.contains($0.date) })
        let live = StatisticsSelection(start: ago(60), end: .live)
        let liveZoom = StatisticsTimeline.Zoom.around(live, lower: ago(86400), now: now)
        #expect(liveZoom.end == nil)
        #expect(scale(86400, zoom: liveZoom).zones.last?.kind == .focus)
        #expect(scale(120, zoom: liveZoom).zones.count == 1)
    }

    @Test("Close threshold drives both directions and strips force zoom out")
    func zoomRules() throws {
        let normal = scale(90 * 86400)
        let selection = StatisticsSelection(start: ago(10 * 86400), end: .at(ago(10 * 86400 - 60)))
        #expect(normal.isClose(selection))
        let zoom = try #require(normal.zoomAfterRelease(selection, atX: nil, normal: normal))
        let bar = scale(90 * 86400, zoom: zoom)
        #expect(bar.zoomAfterRelease(selection, atX: 1, normal: normal) == nil)
        #expect(normal.zoomAfterRelease(StatisticsSelection(start: normal.lower, end: .live), atX: nil, normal: normal) == nil)
        #expect(normal.zoomAfterRest(selection, atX: 100, normal: normal) != nil)
        #expect(bar.zoomAfterRest(selection, atX: bar.focus!.minX + 30, normal: normal) == nil)
    }

    @Test("VoiceOver steps hacks with inclusive end and makes end live past the last hack")
    func accessibleSteps() {
        let bar = scale(86400)
        let ticks = StatisticsTimeline.Tick.ticks([ago(3600), ago(1800), ago(600)])
        var selection = StatisticsSelection(start: ago(7200), end: .at(ago(1200)))
        selection = bar.stepped(selection, .start, forward: true, ticks: ticks)
        #expect(selection.start == ticks[0].startTarget)
        selection = bar.stepped(selection, .end, forward: true, ticks: ticks)
        #expect(selection.endDate(now: now) == ticks[2].endTarget)
        selection = bar.stepped(selection, .end, forward: true, ticks: ticks)
        #expect(selection.isLive)
        selection = bar.stepped(selection, .end, forward: false, ticks: ticks)
        #expect(selection.endDate(now: now) == ticks[2].endTarget && !selection.isLive)
    }

    @Test("Calendar midnight grid handles 23 and 25 hour days")
    func dstGrid() {
        var c = calendar
        c.timeZone = TimeZone(identifier: "America/New_York")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = c.date(from: DateComponents(year: 2026, month: month, day: day))!
            let next = StatisticsTimeline.next(after: start, on: .midnight, calendar: c)
            #expect(next.timeIntervalSince(start) == Double(hours * 3600))
            #expect(StatisticsTimeline.previous(before: next, on: .midnight, calendar: c) == start)
            #expect(StatisticsTimeline.nearest(start.addingTimeInterval(60), on: .midnight, calendar: c) == start)
        }
    }

    @Test("The 44 point threshold is strict, and a wider release zooms out")
    func exactZoomThreshold() {
        let bar = StatisticsTimeline(oldest: ago(3600), now: now, width: 3600, calendar: calendar)
        for distance in [43.9, 44.0, 44.1] {
            let selection = StatisticsSelection(start: bar.date(atX: 100), end: .at(bar.date(atX: 100 + distance)))
            #expect(bar.isClose(selection) == (distance < 44))
        }
    }

    @Test("A short store uses minute grid steps, not calendar days")
    func shortHistoryGrid() {
        let bar = scale(3600)
        let date = ago(1200)
        #expect(bar.grid(for: date) == .minute)
        let selection = StatisticsSelection(start: date, end: .live)
        let stepped = bar.stepped(selection, .start, forward: true, ticks: [])
        #expect(stepped.start == StatisticsTimeline.next(after: date, on: .minute, calendar: calendar))
        if case .grid(_, let grid) = bar.target(for: .start, atX: 150, ticks: []) {
            #expect(grid == .minute)
        } else { Issue.record("An empty part of the short bar must use the minute grid") }
    }

    @Test("Live calendar presets keep calendar comparisons; custom windows compare equal elapsed lengths")
    func comparisons() {
        let oldest = ago(90 * 86400)
        for preset in StatisticsRange.Preset.segments {
            let selection = StatisticsSelection.preset(preset, now: now, oldest: oldest, calendar: calendar)
            let range = selection.range(now: now, oldest: oldest, calendar: calendar)
            #expect(range.comparisonInterval(calendar: calendar) == StatisticsRange.preset(preset, endingOn: now, calendar: calendar).shifted(by: -1, calendar: calendar)?.interval)
        }
        let all = StatisticsSelection.preset(.all, now: now, oldest: oldest, calendar: calendar)
        #expect(all.range(now: now, oldest: oldest, calendar: calendar).comparisonInterval(calendar: calendar) == nil)
        let custom = StatisticsSelection(start: ago(1800), end: .live).range(now: now, oldest: oldest, calendar: calendar)
        #expect(custom.comparisonInterval(calendar: calendar) == ago(3600)..<ago(1800))
    }

    @Test("VoiceOver in an old zoomed focus uses minute steps when no hacks exist")
    func zoomedAccessibleGrid() {
        let selection = StatisticsSelection(start: ago(10 * 86400), end: .at(ago(10 * 86400 - 600)))
        let zoom = StatisticsTimeline.Zoom.around(selection, lower: ago(90 * 86400), now: now)
        let bar = scale(90 * 86400, zoom: zoom)
        let stepped = bar.stepped(selection, .start, forward: true, ticks: [])
        #expect(stepped.start == selection.start.addingTimeInterval(60))
        #expect(bar.zoom == zoom)
        #expect(bar.target(for: .end, atX: bar.width, ticks: []) == .live)
        #expect(bar.zone(atX: 0)?.kind == .leftStrip)
        #expect(bar.zone(atX: bar.width)?.kind == .rightStrip)
    }

    @Test("Readout and export share bounds, preset name, live and frozen semantics")
    func readout() {
        let selection = StatisticsSelection.preset(.sevenDays, now: now, oldest: ago(90 * 86400), calendar: calendar)
        let text = StatisticsRangeText.readout(selection, now: now, oldest: ago(90 * 86400), calendar: calendar)
        #expect(text.line1 == "Last 7 days" && text.line2 != nil && text.isLive)
        #expect(text.spoken.contains("live") && text.exportScope.contains(text.line1))
        let frozen = StatisticsSelection(start: ago(3600), end: .at(ago(60)))
        let custom = StatisticsRangeText.readout(frozen, now: now, oldest: ago(86400), calendar: calendar)
        #expect(custom.line2 == nil && !custom.isLive && custom.exportScope == custom.line1)
    }
}
