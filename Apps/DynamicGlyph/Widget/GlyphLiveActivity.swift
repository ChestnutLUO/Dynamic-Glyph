import ActivityKit
import SwiftUI
import WidgetKit
import GlyphRecognition

@main
struct GlyphWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlyphLiveActivity()
        StartControl()
        SummaryWidget()
    }
}

/// The Dynamic Island and Lock Screen surfaces.
///
/// Rendering only: every judgement was made by the tracker and arrives already
/// reduced in the content state. The extension never decides that a Glyph was
/// observed, and it has no access to the capture, the tables or the app's files.
struct GlyphLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlyphActivityAttributes.self) { context in
            lockScreen(context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.65))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 6) {
                        Text(verbatim: gearMessage(context) ?? context.state.statusLine)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if context.state.gear != nil {
                            gearIcon(context).font(.title2)
                        } else {
                            slotRow(context.state, height: 52)
                            Text(verbatim: footnote(context.state))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                // The Glyph to draw keeps the whole region; before there is
                // one, the progress ring says what collection has reached.
                // One fixed box for all of them: the ring is 24 and the mark
                // 26, and the Island resized, visibly shaking, every time a
                // Glyph change switched between the two.
                // The order matters: `updateAnimation` must reach the Group
                // itself, which hands its identity transition to whichever
                // branch is inserted or removed. Put after `.frame`, it lands on
                // the frame instead, and a swap between badge, mark and gear
                // icon gets the system's default transition again.
                Group {
                    if context.state.gear != nil {
                        gearIcon(context)
                    } else if context.state.upcoming.isEmpty {
                        badge(context, side: 24)
                    } else {
                        mark(context, index: 0, side: 26)
                    }
                }
                .updateAnimation(context.state)
                .frame(width: Self.compactLeadingSide, height: Self.compactLeadingSide)
            } compactTrailing: {
                // The second Glyph when there is one, otherwise the slot
                // counter. On the last slot nothing follows, so the counter is
                // the honest thing to show.
                Group {
                    if let gear = context.state.gear {
                        // Items counted so far stay true once watching has lapsed.
                        Text(verbatim: context.isStale && gear.state != .watching ? "–" : gear.compactValue)
                            .font(.caption2.monospacedDigit()).foregroundStyle(statusColour(context))
                            .accessibilityLabel(gearMessage(context) ?? "")
                    } else if context.state.upcoming.count > 1, !context.isStale {
                        mark(context, index: 1, side: 20)
                            .frame(width: Self.compactTrailingSize.width,
                                   height: Self.compactTrailingSize.height)
                    } else {
                        // The same box as the mark, so swapping one for the
                        // other does not resize the Island.
                        Text(progress(context.state)).font(.caption2.monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(statusColour(context))
                            .frame(width: Self.compactTrailingSize.width,
                                   height: Self.compactTrailingSize.height)
                    }
                }
                // Each branch carries its own box, so nothing sits between
                // this and the Group and the transition reaches every branch.
                .updateAnimation(context.state)
            } minimal: {
                // Shown when another activity takes the Island. A phone
                // recording while capturing showed the compact form, with the
                // screen-recording chip as a separate bubble. See IslandProgress.
                // As in compactLeading: transition first, so it reaches the
                // branches, and the fixed box outside it.
                Group {
                    if context.state.gear != nil { gearIcon(context) }
                    else { badge(context, side: 24) }
                }
                .updateAnimation(context.state)
                .frame(width: Self.minimalSide, height: Self.minimalSide)
            }
            // The Island's own edge carries the status, as the Picture in
            // Picture window's edge does: seen at a glance in every
            // presentation, and needing no room the Glyphs could use.
            .keylineTint(statusColour(context))
        }
    }

    /// Fixed sizes for the compact and minimal regions. The Island sizes
    /// itself to its content, so anything that changes size between updates
    /// moves the whole Island.
    private static let compactLeadingSide: CGFloat = 26
    private static let compactTrailingSize = CGSize(width: 26, height: 20)
    private static let minimalSide: CGFloat = 24

    private func gearMessage(_ context: ActivityViewContext<GlyphActivityAttributes>) -> String? {
        guard let gear = context.state.gear else { return nil }
        guard context.isStale else { return gear.message(currentHackID: context.state.hackID) }
        if gear.state == .watching, let items = gear.itemCount, items > 0 {
            return String(localized: "Gear status paused · \(items) items so far",
                          comment: "Live Activity, gear-only capture: the screen feed stopped; the count is what was read before.")
        }
        return String(localized: "Gear status paused", comment: "Live Activity: the screen feed is no longer refreshing the gear status.")
    }

    private func gearIcon(_ context: ActivityViewContext<GlyphActivityAttributes>) -> some View {
        Image(systemName: context.isStale ? "pause.circle" : context.state.gear?.symbol ?? "shippingbox")
            .foregroundStyle(statusColour(context))
            .accessibilityLabel(gearMessage(context) ?? "")
    }

    /// The Picture in Picture edge colour for the same status, the values of
    /// `GlyphDisplayRenderer.Palette`, which the extension does not link. An activity
    /// past its stale date is old news whatever it was last told, which the
    /// window shows in its warning colour too.
    private func statusColour(_ context: ActivityViewContext<GlyphActivityAttributes>) -> Color {
        let tone = context.isStale ? .warning : StatusTone(rawValue: context.state.statusTone) ?? .idle
        switch tone {
        case .warning: return Color(red: 1.00, green: 0.42, blue: 0.42)
        case .tentative: return Color(red: 1.00, green: 0.78, blue: 0.30)
        case .idle: return Color(red: 0.42, green: 0.44, blue: 0.52)
        case .collecting: return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .drawing: return Color(red: 0.80, green: 0.78, blue: 1.00)
        case .done: return Color(red: 0.95, green: 0.95, blue: 1.00)
        }
    }

    /// The Glyph at `index` of the guidance window, or the plain status icon
    /// when there is no guidance. Stale content greys and keeps its dash
    /// pattern, so line style still separates observed from predicted rather
    /// than colour having to carry it alone.
    @ViewBuilder
    private func mark(_ context: ActivityViewContext<GlyphActivityAttributes>,
                      index: Int, side: CGFloat) -> some View {
        if index < context.state.upcoming.count {
            let slot = context.state.upcoming[index]
            let colour: Color = context.isStale ? .secondary : tint(slot.provenance)
            ZStack {
                if let path = slot.path {
                    GlyphDiagramShape(path: path, layout: GlyphDiagramLayout(inset: 0.06))
                        .stroke(colour, style: StrokeStyle(lineWidth: side * 0.07, lineCap: .round,
                                                           lineJoin: .round,
                                                           dash: dashed(slot.provenance)
                                                               ? [side * 0.1, side * 0.08] : []))
                } else {
                    Text(verbatim: "?").font(.system(size: side * 0.62, weight: .semibold))
                        .foregroundStyle(colour)
                }
            }
            .frame(width: side, height: side)
            .opacity(context.isStale ? 0.45 : 1)
            .accessibilityLabel(label(slot, index: index))
            .accessibilityValue(qualifier(slot, stale: context.isStale))
        } else {
            Image(systemName: context.state.isProvisional ? "eye" : "hexagon")
                .foregroundStyle(context.state.isProvisional ? .orange : .purple)
        }
    }

    /// The progress ring with the next Glyph, the Glyph on screen, or a status
    /// icon inside it. Before the game has shown a slot count there is no
    /// ring, and the centre gets the whole region.
    private func badge(_ context: ActivityViewContext<GlyphActivityAttributes>,
                       side: CGFloat) -> some View {
        let progress = IslandProgress(context.state)
        let inner = progress.marks.isEmpty ? side : side * 0.64
        return ZStack {
            if !progress.marks.isEmpty {
                ring(progress, side: side)
                    .opacity(context.isStale ? 0.45 : 1)
            }
            centre(context, progress: progress, side: inner)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .combine)
        .accessibilityValue(progressDescription(progress))
    }

    /// One segment per slot, clockwise from the top like the game's row from
    /// the left. The emphasised segment is drawn thicker, so position does not
    /// depend on colour alone.
    private func ring(_ progress: IslandProgress, side: CGFloat) -> some View {
        let count = progress.marks.count
        let gap = count > 1 ? 0.04 : 0
        let thick = side * 0.14, thin = side * 0.08
        return ZStack {
            ForEach(Array(progress.marks.enumerated()), id: \.offset) { index, mark in
                Circle()
                    .trim(from: Double(index) / Double(count) + gap / 2,
                          to: Double(index + 1) / Double(count) - gap / 2)
                    .stroke(colour(mark), lineWidth: index == progress.current ? thick : thin)
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(thick / 2)
    }

    @ViewBuilder
    private func centre(_ context: ActivityViewContext<GlyphActivityAttributes>,
                        progress: IslandProgress, side: CGFloat) -> some View {
        switch progress.centre {
        case .next:
            mark(context, index: 0, side: side)
        case .slot(let index):
            let slot = context.state.slots[index]
            if let path = slot.path {
                GlyphDiagramShape(path: path, layout: GlyphDiagramLayout(inset: 0.06))
                    .stroke(context.isStale ? .secondary : tint(slot.provenance),
                            style: StrokeStyle(lineWidth: max(1, side * 0.08), lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
                    .opacity(context.isStale ? 0.45 : 1)
            }
        case .covered:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: side * 0.62))
                .foregroundStyle(.yellow)
                .accessibilityLabel(String(localized: "The slot row is covered",
                                           comment: "VoiceOver label in the Dynamic Island: a window or banner hides the game's slot row."))
        case .waiting(let provisional):
            Image(systemName: provisional ? "eye" : "hexagon")
                .foregroundStyle(provisional ? .orange : .purple)
        }
    }

    private func colour(_ mark: IslandProgress.Mark) -> Color {
        switch mark {
        case .held: return tint(.observed)
        case .seeing: return tint(.observing)
        case .lost: return tint(.uncertain)
        case .predicted: return tint(.predicted).opacity(0.7)
        case .ahead: return Color.secondary.opacity(0.35)
        }
    }

    /// Spoken after whatever the centre says. Empty until there is a ring.
    private func progressDescription(_ progress: IslandProgress) -> String {
        guard !progress.marks.isEmpty else { return "" }
        let held = progress.marks.filter { $0 == .held }.count
        return String(localized: "Collected: \(held) of \(progress.marks.count)",
                      comment: "VoiceOver value for the Dynamic Island progress ring. First placeholder: Glyphs collected; second: slots in the hack.")
    }

    /// The compact regions have no room for words, so the words go here.
    /// Glyph names are the game's own and stay untranslated.
    private func label(_ slot: GlyphActivityAttributes.ContentState.Slot,
                       index: Int) -> String {
        let name = slot.name ?? String(localized: "an unknown Glyph",
                                       comment: "Spoken in place of a Glyph name that could not be read.")
        return index == 0
            ? String(localized: "Next to draw: \(name)",
                     comment: "VoiceOver label in the Dynamic Island. The placeholder is a Glyph name.")
            : String(localized: "Then: \(name)",
                     comment: "VoiceOver label in the Dynamic Island for the Glyph after the next one.")
    }

    /// Spoken after the label as its own phrase, so no translation has to be
    /// glued together from fragments.
    private func qualifier(_ slot: GlyphActivityAttributes.ContentState.Slot, stale: Bool) -> String {
        switch (slot.provenance == .predicted, stale) {
        case (true, true):
            return String(localized: "Predicted, may be out of date",
                          comment: "VoiceOver value: the Glyph comes from the sequence list and the display is old.")
        case (true, false):
            return String(localized: "Predicted", comment: "VoiceOver value: the Glyph comes from the sequence list.")
        case (false, true):
            return String(localized: "May be out of date", comment: "VoiceOver value: the display is old.")
        case (false, false):
            return ""
        }
    }

    private func lockScreen(_ context: ActivityViewContext<GlyphActivityAttributes>) -> some View {
        let state = context.state
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: gearMessage(context) ?? state.statusLine).font(.headline).lineLimit(1)
            if state.gear != nil { gearIcon(context) }
            else {
                slotRow(state, height: 64)
                Text(verbatim: footnote(state)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slotRow(_ state: GlyphActivityAttributes.ContentState, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            if state.slots.isEmpty {
                Text("Waiting for a Glyph hack").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(state.slots.enumerated()), id: \.offset) { index, slot in
                    VStack(spacing: 2) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(tint(slot.provenance).opacity(0.3), lineWidth: 1)
                            if let path = slot.path {
                                ZStack {
                                    GlyphArrayFrame(nodeRadius: 1.2)
                                    GlyphDiagramShape(path: path)
                                        .stroke(tint(slot.provenance),
                                                style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                                   lineJoin: .round,
                                                                   dash: dashed(slot.provenance) ? [3, 2] : []))
                                }
                                .padding(3)
                            } else {
                                Text(verbatim: "?").font(.caption.bold()).foregroundStyle(tint(slot.provenance))
                            }
                        }
                        .frame(height: height)
                        .overlay(alignment: .topTrailing) {
                            if let check = slot.inputCheck, check.showsSymbol {
                                Text(verbatim: check.verdict.symbol).font(.caption.bold())
                                    .foregroundStyle(check.verdict == .differs ? Color.red : Color.secondary)
                                    .padding(3).background(.black, in: Circle())
                            }
                        }
                        .overlay {
                            if slot.inputCheck?.verdict == .differs {
                                RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: 2)
                            }
                        }
                        .accessibilityLabel(slot.inputCheck?.message(slotNumber: index + 1) ?? slot.name ?? "")
                        Text(slot.name ?? "—")
                            .font(.system(size: 8))
                            .foregroundStyle(tint(slot.provenance))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
        }
    }

    /// Observed slots out of however many the game showed. Never a percentage:
    /// there is no measured probability anywhere in this model.
    private func progress(_ state: GlyphActivityAttributes.ContentState) -> String {
        guard let expected = state.expectedSlotCount else { return "\(state.observedCount)/?" }
        return "\(state.observedCount)/\(expected)"
    }

    private func footnote(_ state: GlyphActivityAttributes.ContentState) -> String {
        if state.isProvisional {
            return String(localized: "Shapes as seen, not yet a confirmed sequence",
                          comment: "Island footnote while the display is only showing what it sees.")
        }
        // Only while the player is drawing, and only while the slot's own mark
        // is shown: a match stops being news when its check mark expires.
        let shownChecks = state.slots.enumerated().compactMap { index, slot in
            slot.inputCheck.flatMap { $0.showsSymbol ? (slotNumber: index + 1, check: $0) : nil }
        }
        if state.phase == TrackingState.input.rawValue,
           let latest = shownChecks.max(by: { $0.check.sourceTime < $1.check.sourceTime }) {
            return latest.check.message(slotNumber: latest.slotNumber)
        }
        switch state.predictionState {
        case "unavailable":
            return String(localized: "Predictions off", comment: "Island footnote: no sequence list is loaded.")
        case "unobserved":
            return String(localized: "Waiting for the first Glyph", comment: "Island footnote.")
        case "ambiguous":
            return String(localized: "\(state.candidateCount) sequences still possible",
                          comment: "Island footnote: how many sequences fit what has been seen.")
        case "resolved":
            return String(localized: "One sequence matches what was seen", comment: "Island footnote.")
        case "contradicted":
            return String(localized: "Doesn't match any known sequence", comment: "Island footnote.")
        case "lengthConflict":
            return String(localized: "Length doesn't fit what was seen",
                          comment: "Island footnote: the number of slots disagrees with the Glyphs seen.")
        default: return state.predictionState
        }
    }

    private func tint(_ provenance: GlyphActivityAttributes.ContentState.Slot.Provenance) -> Color {
        switch provenance {
        case .observed: return Color(red: 0.80, green: 0.78, blue: 1.00)
        case .observing: return Color(red: 1.00, green: 0.78, blue: 0.30)
        case .predicted: return Color(red: 0.35, green: 0.75, blue: 0.90)
        case .uncertain, .missing: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .pending: return .secondary
        }
    }

    private func dashed(_ provenance: GlyphActivityAttributes.ContentState.Slot.Provenance) -> Bool {
        provenance != .observed
    }
}

private extension View {
    /// Live Activity updates animate by default. On a phone, every update to
    /// the compact Island, even one that changed nothing visible, slid its
    /// content about 4 points right and back over 0.3 s, and a new Glyph
    /// cross-faded with the old one. Unless the player turns the animation on,
    /// these presentations switch instantly.
    ///
    /// Apply it directly to a `Group` of conditional branches, before any
    /// `.frame` or other wrapper: only then does each branch get the identity
    /// transition when it is inserted or removed.
    @ViewBuilder
    func updateAnimation(_ state: GlyphActivityContentState) -> some View {
        if state.animatesUpdates {
            self
        } else {
            contentTransition(.identity)
                .transition(.identity)
                .animation(nil, value: state)
        }
    }
}
