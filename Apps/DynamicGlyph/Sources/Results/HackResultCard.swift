import SwiftUI
import GlyphRecognition

/// One hack's conclusion as the game showed it, with our own input check
/// beside each Glyph. Wording comes from the recognition package so every
/// surface describes a result the same way.
struct HackResultCard: View {
    let record: HackResultRecord
    let table: GlyphTable?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = record.summary {
                // Before a result screen, or without one, there is nothing
                // read yet: show the sequence, not empty readings.
                let hasReadings = summary.state == .complete || summary.state == .partial
                header(summary)
                if hasReadings {
                    HStack(spacing: 12) {
                        BonusView(title: "Hacking Bonus", bonus: summary.hackingBonus)
                        BonusView(title: "Speed Bonus", bonus: summary.speedBonus)
                    }
                }
                if summary.hasProvisionalBonus {
                    Text("A value marked “last seen” was the last one read; the game may have shown a different final value.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.slots.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(summary.slots.indices, id: \.self) { index in
                            ResultSlotTile(summary: summary, index: index, table: table, showsOutcome: hasReadings)
                        }
                    }
                }
                ForEach(summary.disagreementLines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if hasReadings {
                    Text("Read from the game's result screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HackCommandLine(commands: summary.commands)
                if let gear = record.gear {
                    Divider()
                    HackGearSection(attachment: gear, record: record)
                }
            } else {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(.headline)
                Text("This result was saved in a format this version of the app can't show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard()
    }

    private func header(_ summary: HackResultSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.date, format: .dateTime.hour().minute())
                        .font(.headline)
                    // Localized by the recognition package.
                    Text(summary.glyphCountLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(summary.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: Self.symbol(summary.state))
                .foregroundStyle(Self.tint(summary.state))
                .accessibilityHidden(true)
        }
    }

    static func symbol(_ state: HackResult.State) -> String {
        switch state {
        case .awaiting: return "hourglass"
        case .complete: return "checkmark.seal.fill"
        case .partial: return "circle.lefthalf.filled"
        case .notObserved: return "eye.slash"
        }
    }

    static func tint(_ state: HackResult.State) -> Color {
        switch state {
        case .awaiting, .notObserved: return .secondary
        case .complete: return .green
        case .partial: return .orange
        }
    }
}

private struct BonusView: View {
    let title: LocalizedStringResource
    let bonus: HackResultSummary.Bonus?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let text = HackResultSummary.percentText(bonus) {
                Text(verbatim: text)
                    .font(.title2.bold().monospacedDigit())
            } else {
                Text(verbatim: "—")
                    .font(.title2.bold())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Not read"))
            }
            if bonus?.isFinal == false {
                Text("last seen")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ResultSlotTile: View {
    let summary: HackResultSummary
    let index: Int
    let table: GlyphTable?
    let showsOutcome: Bool

    private var slot: HackResultSummary.Slot { summary.slots[index] }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.6), lineWidth: slot.outcome == .unknown ? 1 : 2)
                if let name = slot.glyph, let path = table?.path(for: GlyphID(name)) {
                    ZStack {
                        GlyphArrayFrame()
                        GlyphDiagramShape(path: path)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                    .padding(4)
                } else {
                    Text(verbatim: "?").font(.title3.bold()).foregroundStyle(tint)
                }
            }
            .frame(height: 54)
            .overlay(alignment: .topTrailing) {
                // Fixed like the tile's labels: a badge that grew with the text
                // size would cover the diagram. VoiceOver carries the outcome.
                if showsOutcome {
                    Image(systemName: outcomeSymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(2)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
            // Glyph names stay as the game has them.
            Text(verbatim: slot.glyph ?? "?")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if showsOutcome {
                Text(HackResultSummary.outcomeLabel(slot.outcome))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(ourCheck)
                    .font(.system(size: 9))
                    .foregroundStyle(slot.comparison == .disagreement ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .modifier(SlotAccessibility(label: showsOutcome ? summary.accessibilityLabel(slot: index) : nil,
                                    name: slot.glyph ?? "?", value: showsOutcome ? ourCheck : nil))
    }

    private var tint: Color {
        guard showsOutcome else { return .secondary }
        switch slot.outcome {
        case .accepted: return .green
        case .rejected: return .red
        case .unknown: return .secondary
        }
    }

    private var outcomeSymbol: String {
        switch slot.outcome {
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// What our own input check said about the attempt the game judged.
    private var ourCheck: LocalizedStringResource {
        guard slot.comparison != .unknownAssociation, let check = slot.check else {
            return LocalizedStringResource("Not checked",
                                           comment: "Hack result tile: our input check has no verdict for this Glyph, e.g. the last one.")
        }
        switch check {
        case .matched:
            return LocalizedStringResource("Matched", comment: "Hack result tile: our input check found the drawing matched.")
        case .differs:
            return LocalizedStringResource("Warned", comment: "Hack result tile: our input check warned the drawing differed.")
        case .unavailable:
            return LocalizedStringResource("Couldn't tell", comment: "Hack result tile: our input check couldn't decide.")
        }
    }
}

/// Before any reading, a tile is just the expected Glyph.
private struct SlotAccessibility: ViewModifier {
    let label: String?
    let name: String
    let value: LocalizedStringResource?

    func body(content: Content) -> some View {
        if let label, let value {
            content.accessibilityLabel(label).accessibilityValue(Text(value))
        } else {
            content.accessibilityLabel(Text(verbatim: name))
        }
    }
}

/// The commands the game accepted before this hack, on one line, on every
/// card: what was seen, that none was, or that it may have been missed.
private struct HackCommandLine: View {
    /// Nil for a hack saved before commands were read.
    let commands: HackCommandSummary?

    var body: some View {
        Label {
            Text(verbatim: HackCommandSummary.cardText(commands))
        } icon: {
            Image(systemName: "command")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
