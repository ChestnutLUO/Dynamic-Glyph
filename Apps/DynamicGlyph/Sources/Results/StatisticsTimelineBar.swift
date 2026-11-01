import SwiftUI

/// The Statistics timeline: zone labels, the bar with its zones, the
/// selection fill and two handles, a tick per minute with records, and the
/// axis. One drag gesture moves the handle nearer the finger; it snaps to
/// the live edge, a section edge, a hack, or else the grid. When the
/// handles are close the bar zooms around them.
struct StatisticsTimelineBar: View {
    @Binding var selection: StatisticsSelection
    @Binding var draft: StatisticsSelection?
    @Binding var zoom: StatisticsTimeline.Zoom?
    @Binding var feedback: StatisticsTimelineFeedback
    let ticks: [StatisticsTimeline.Tick]
    let oldest: Date?
    let now: Date
    /// The preset the handles stand for, which its label shows selected.
    let matched: StatisticsRange.Preset?
    let choose: (StatisticsRange.Preset) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The container's width: the page less its insets.
    @State private var width: Double = 0
    @State private var drag: DragState?
    @State private var restTask: Task<Void, Never>?
    @State private var bubbleSize = CGSize.zero

    /// The knobs never clip: the bar is inset this much on each side.
    private static let inset = 12.0
    private static let labelRow = 22.0
    private static let labelGap = 8.0
    private static let barHeight = 44.0
    private static let tickGap = 6.0
    private static let tickHeight = 10.0
    private static let knob = 22.0
    /// Handle hit areas reach this far above the bar, over the knob.
    private static let handleReach = 20.0

    private struct DragState {
        let handle: StatisticsTimeline.Handle
        /// Presentation-only anchor during a dwell scale transition. It never
        /// changes hit testing or the scale's finger-to-time mapping.
        var presentationX: Double?
        var fingerX: Double
        /// Where the finger last moved 2 points or more from.
        var restAnchor: Double
        /// What it last snapped to, so each arrival plays once.
        var snap: Snap?
        var bubble = ""
        var bubbleDot = false
    }

    private enum Snap: Hashable {
        case live, edge(StatisticsRange.Preset), hack(Date), grid
    }

    private var barWidth: Double { max(width - 2 * Self.inset, 0) }
    private var showsLabels: Bool { !typeSize.isAccessibilitySize }
    private var barTop: Double { showsLabels ? Self.labelRow + Self.labelGap : Self.handleReach }
    private var shown: StatisticsSelection { draft ?? selection }

    private var timeline: StatisticsTimeline {
        StatisticsTimeline(oldest: oldest, now: now, width: barWidth, zoom: zoom)
    }

    private var normal: StatisticsTimeline {
        StatisticsTimeline(oldest: oldest, now: now, width: barWidth)
    }

    var body: some View {
        let timeline = timeline
        VStack(spacing: 0) {
            graphic(timeline)
            axis(timeline)
                .padding(.top, 2)
            if !showsLabels && !timeline.isEmpty {
                accessibilityButtons(timeline)
                    .padding(.top, 8)
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .onDisappear {
            restTask?.cancel()
            restTask = nil
            drag = nil
            draft = nil
        }
        .accessibilityLabel(Text("Time range", comment: "Statistics: the timeline that chooses the range, for VoiceOver."))
    }

    // MARK: Drawing

    private func graphic(_ timeline: StatisticsTimeline) -> some View {
        let height = barTop + Self.barHeight + Self.tickGap + Self.tickHeight
        return ZStack(alignment: .topLeading) {
            if showsLabels && !timeline.isEmpty {
                labels(timeline)
            }
            drawing(timeline)
            if !timeline.isEmpty {
                hitArea(timeline)
                if reduceMotion {
                    handles(timeline).id(zoom).transition(.opacity)
                } else {
                    handles(timeline)
                }
                if let drag {
                    bubble(drag, timeline)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    /// Zones, fill and ticks. Under Reduce Motion a scale change replaces
    /// them with a crossfade rather than moving them.
    @ViewBuilder
    private func drawing(_ timeline: StatisticsTimeline) -> some View {
        let layers = ZStack(alignment: .topLeading) {
            bar(timeline)
            if !timeline.isEmpty {
                tickMarks(timeline)
            }
        }
        if reduceMotion {
            layers.id(zoom).transition(.opacity)
        } else {
            layers
        }
    }

    private func bar(_ timeline: StatisticsTimeline) -> some View {
        let zones = ZStack(alignment: .topLeading) {
            ForEach(Array(timeline.zones.enumerated()), id: \.offset) { _, zone in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .frame(width: max(zone.width, 0), height: Self.barHeight)
                    .offset(x: Self.inset + zone.minX)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        return ZStack(alignment: .topLeading) {
            zones.foregroundStyle(Color(.tertiarySystemFill))
            if !timeline.isEmpty {
                let start = displayX(.start, timeline), end = displayX(.end, timeline)
                // Masked by the zones, so the gaps stay empty.
                Color.accentColor.opacity(0.16)
                    .frame(width: max(end - start, 0), height: Self.barHeight)
                    .offset(x: Self.inset + start)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .mask(zones)
            }
        }
        .frame(height: Self.barHeight)
        .offset(y: barTop)
        .accessibilityHidden(true)
    }

    private func tickMarks(_ timeline: StatisticsTimeline) -> some View {
        let range = shown.range(now: now, oldest: oldest)
        return ZStack(alignment: .topLeading) {
            ForEach(ticks) { tick in
                let inside = range.contains(tick.first) || range.contains(tick.last)
                Rectangle()
                    .fill(inside ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 1, height: Self.tickHeight)
                    .offset(x: Self.inset + timeline.x(for: tick.first) - 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .offset(y: barTop + Self.barHeight + Self.tickGap)
        .accessibilityHidden(true)
    }

    // MARK: Labels

    @ViewBuilder
    private func labels(_ timeline: StatisticsTimeline) -> some View {
        if let focus = timeline.focus {
            HStack(spacing: 8) {
                Text("Zoomed in", comment: "Statistics timeline: the caption over the bar while it is zoomed in around the handles.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                zoomOutButton
                    .font(.caption.weight(.semibold))
            }
            .padding(.leading, Self.inset + focus.minX)
            .padding(.trailing, Self.inset)
            .frame(height: Self.labelRow)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(timeline.zones, id: \.kind) { zone in
                    if let preset = zone.label {
                        zoneLabel(preset, width: zone.width)
                            .offset(x: Self.inset + zone.minX)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.labelRow)
        }
    }

    private func zoneLabel(_ preset: StatisticsRange.Preset, width: Double) -> some View {
        let selected = matched == preset
        return Button { choose(preset) } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 12)
                Text(preset.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: max(width, 0), minHeight: Self.labelRow, alignment: .leading)
            // 44 points tall to touch, without spreading the row.
            .contentShape(Rectangle().inset(by: -11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.readoutName))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var zoomOutButton: some View {
        Button(action: zoomOut) {
            Label {
                Text("Zoom out", comment: "Statistics timeline: the button that shows the whole timeline again after it zoomed in around the handles.")
            } icon: {
                Image(systemName: "arrow.left.and.right")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .frame(minHeight: Self.labelRow)
            .contentShape(Rectangle().inset(by: -11))
        }
        .buttonStyle(.plain)
    }

    /// At accessibility sizes, under the axis: the zone labels' choices, and
    /// Zoom out while zoomed.
    private func accessibilityButtons(_ timeline: StatisticsTimeline) -> some View {
        let presets = normal.zones.compactMap(\.label)
        let buttons = Group {
            ForEach(presets) { preset in
                Button { choose(preset) } label: {
                    Text(preset == .all ? preset.readoutName : preset.title)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityAddTraits(matched == preset ? .isSelected : [])
            }
            if timeline.isZoomed {
                Button(action: zoomOut) {
                    Label {
                        Text("Zoom out", comment: "Statistics timeline: the button that shows the whole timeline again after it zoomed in around the handles.")
                    } icon: {
                        Image(systemName: "arrow.left.and.right")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) { buttons }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Axis

    private func axis(_ timeline: StatisticsTimeline) -> some View {
        let left = timeline.focus?.minX ?? 0, right = timeline.focus?.maxX ?? barWidth
        return HStack(spacing: 4) {
            if !timeline.isEmpty {
                Text(verbatim: leadingAxis(timeline))
                Spacer(minLength: 4)
                Text(verbatim: trailingAxis(timeline))
            }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        .lineLimit(1)
        .padding(.leading, Self.inset + left)
        .padding(.trailing, Self.inset + max(barWidth - right, 0))
        .frame(maxWidth: .infinity, minHeight: 14)
        .accessibilityHidden(true)
    }

    /// The bar's start date ("Sep 20"), or the zoomed middle's start time.
    private func leadingAxis(_ timeline: StatisticsTimeline) -> String {
        guard let focus = timeline.focus else { return StatisticsRangeText.shortDay(timeline.lower, now: now) }
        return StatisticsRangeText.moment(focus.start, now: now)
    }

    private func trailingAxis(_ timeline: StatisticsTimeline) -> String {
        guard let focus = timeline.focus, focus.end < now else {
            return String(localized: "Now", comment: "Statistics timeline: the right end of the bar, and the bubble at the live edge.")
        }
        return StatisticsRangeText.moment(focus.end, now: now)
    }

    /// Only the active handle is held at the touch during the scale change.
    /// The next touch sample uses the displayed scale directly: physical bar
    /// edges and side strips remain reachable, without a persistent offset.
    private func displayX(_ handle: StatisticsTimeline.Handle, _ timeline: StatisticsTimeline) -> Double {
        if let drag, drag.handle == handle, let x = drag.presentationX { return x }
        return timeline.x(for: handle == .start ? shown.start : shown.endDate(now: now))
    }

    // MARK: Handles

    private func handles(_ timeline: StatisticsTimeline) -> some View {
        ZStack(alignment: .topLeading) {
            handle(.start, x: displayX(.start, timeline))
            handle(.end, x: displayX(.end, timeline))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .offset(y: barTop - Self.handleReach)
    }

    /// The line over the bar under a white knob whose centre is 1 point
    /// above the bar, in a 44 × 64 point hit area.
    private func handle(_ handle: StatisticsTimeline.Handle, x: Double) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: Self.barHeight)
                .offset(y: Self.handleReach)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(y: Self.handleReach - 1 - Self.knob / 2)
        }
        .frame(width: 44, height: Self.handleReach + Self.barHeight, alignment: .top)
        .contentShape(Rectangle())
        .offset(x: Self.inset + x - 22)
        // The bar's gesture moves them.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(handle == .start
                            ? Text("Start time", comment: "Statistics timeline: the left handle, for VoiceOver.")
                            : Text("End time", comment: "Statistics timeline: the right handle, for VoiceOver. The end is left out of the range."))
        .accessibilityValue(Text(verbatim: spokenValue(handle)))
        .accessibilityAdjustableAction { direction in
            // Hack by hack, never zooming.
            let forward = direction == .increment
            guard forward || direction == .decrement else { return }
            selection = timeline.stepped(selection, handle, forward: forward, ticks: ticks)
        }
    }

    private func spokenValue(_ handle: StatisticsTimeline.Handle) -> String {
        if handle == .end && selection.isLive {
            return String(localized: "Now, live", comment: "Statistics timeline: the right handle's value for VoiceOver when the range keeps ending at the current time.")
        }
        let date = handle == .start ? selection.start : selection.endDate(now: now)
        return StatisticsRangeText.spokenMoment(date, now: now)
    }

    // MARK: Bubble

    private func bubble(_ drag: DragState, _ timeline: StatisticsTimeline) -> some View {
        let x = Self.inset + displayX(drag.handle, timeline)
        let half = bubbleSize.width / 2
        let center = min(max(x, half), max(width - half, half))
        return HStack(spacing: 4) {
            if drag.bubbleDot {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Color.accentColor)
            }
            Text(verbatim: drag.bubble)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
        // 8 points above the knob.
        .offset(x: center - half, y: barTop - 1 - Self.knob / 2 - 8 - bubbleSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Dragging

    /// The bar and both handles' hit areas take the one drag gesture.
    private func hitArea(_ timeline: StatisticsTimeline) -> some View {
        let startX = Self.inset + displayX(.start, timeline)
        let endX = Self.inset + displayX(.end, timeline)
        let shape = HitShape(bar: CGRect(x: 0, y: barTop, width: width,
                                         height: Self.barHeight + Self.tickGap + Self.tickHeight),
                             handles: [startX, endX].map {
                                 CGRect(x: $0 - 22, y: barTop - Self.handleReach, width: 44,
                                        height: Self.handleReach + Self.barHeight)
                             })
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in moved(to: value.location.x - Self.inset) }
                    .onEnded { value in released(at: value.location.x - Self.inset) }
            )
            .accessibilityHidden(true)
    }

    private func moved(to fingerX: Double) {
        let timeline = timeline
        if drag == nil {
            // The nearer handle takes the drag.
            let handle = StatisticsTimeline.handle(nearestTo: fingerX, startX: timeline.x(for: selection.start),
                                                   endX: timeline.x(for: selection.endDate(now: now)))
            drag = DragState(handle: handle, fingerX: fingerX, restAnchor: fingerX)
            draft = selection
            restartRest()
        }
        guard var state = drag else { return }
        state.fingerX = fingerX
        state.presentationX = nil
        if abs(fingerX - state.restAnchor) >= 2 {
            state.restAnchor = fingerX
            restartRest()
        }
        drag = state
        place(on: timeline)
    }

    /// Moves the dragged handle to what the finger is over, plays the snap's
    /// haptic once on arrival, and words the bubble.
    private func place(on timeline: StatisticsTimeline) {
        guard var state = drag else { return }
        let x = min(max(state.fingerX, 0), timeline.width)
        let target = timeline.target(for: state.handle, atX: x, ticks: ticks)
        var next = draft ?? selection
        let held = next.place(state.handle, on: target, lower: timeline.lower, now: now)
        let snap: Snap
        switch target {
        case .live: snap = .live
        case .edge(let edge): snap = held ? .grid : .edge(edge.preset)
        case .hack(let tick): snap = held ? .grid : .hack(tick.minute)
        case .grid: snap = .grid
        }
        if snap != state.snap {
            switch snap {
            case .hack: feedback.selection += 1
            case .edge, .live: feedback.edge += 1
            case .grid: break
            }
            state.snap = snap
        }
        let date = state.handle == .start ? next.start : next.endDate(now: now)
        state.bubbleDot = false
        switch (target, held) {
        case (.live, _):
            state.bubble = String(localized: "Now", comment: "Statistics timeline: the right end of the bar, and the bubble at the live edge.")
        case (.edge(let edge), false):
            state.bubble = String(localized: edge.preset.title) + " · " + StatisticsRangeText.moment(date, now: now)
        case (.hack, false):
            state.bubbleDot = true
            state.bubble = StatisticsRangeText.moment(date, now: now)
        case (.grid(_, .midnight), false):
            state.bubble = StatisticsRangeText.shortDay(date, now: now)
        default:
            state.bubble = StatisticsRangeText.moment(date, now: now)
        }
        drag = state
        draft = next
    }

    private func released(at fingerX: Double) {
        moved(to: fingerX)
        restTask?.cancel()
        restTask = nil
        guard let state = drag, let final = draft else {
            drag = nil
            draft = nil
            return
        }
        let timeline = timeline
        let x = min(max(fingerX, 0), timeline.width)
        let newZoom = timeline.zoomAfterRelease(final, atX: x, normal: normal)
        // The cards, charts and Results follow now.
        selection = final
        draft = nil
        drag = nil
        setZoom(newZoom)
    }

    private func restartRest() {
        restTask?.cancel()
        restTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            rested()
        }
    }

    /// The finger stayed within 2 points for 0.4 s: zoom in where the
    /// handles are close, out in a side strip. The drag goes on, the
    /// handle keeping its time.
    private func rested() {
        guard var state = drag, let current = draft else { return }
        let timeline = timeline
        let x = min(max(state.fingerX, 0), timeline.width)
        guard case .some(let newZoom) = timeline.zoomAfterRest(current, atX: x, normal: normal) else { return }
        state.presentationX = min(max(state.fingerX, 0), barWidth)
        drag = state
        setZoom(newZoom)
    }

    private func setZoom(_ newZoom: StatisticsTimeline.Zoom?) {
        guard newZoom != zoom else { return }
        let toggles = (newZoom == nil) != (zoom == nil)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3)) {
            zoom = newZoom
        }
        if toggles { feedback.zoom += 1 }
    }

    private func zoomOut() {
        setZoom(nil)
    }
}

/// The bar's rows and each handle's 44 × 64 point area, where the drag
/// starts; the zone labels above stay buttons.
private struct HitShape: Shape {
    let bar: CGRect
    let handles: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(bar)
        for handle in handles { path.addRect(handle) }
        return path
    }
}
