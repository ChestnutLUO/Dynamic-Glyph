import SwiftUI
import GlyphRecognition
import GlyphRecognitionImages

/// The live sequence, with a status and a hint about what to do next.
struct SequenceCard: View {
    let snapshot: GlyphDisplaySnapshot
    let table: GlyphTable?
    let predictionsOn: Bool
    let now: Double

    var body: some View {
        let status = snapshot.displayStatus(atUptime: now)
        let styles = snapshot.tileStyles
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol(status))
                    .font(.title2)
                    .foregroundStyle(tint(status))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.statusLine(atUptime: now))
                        .font(.title3.bold())
                    Text(hint(status))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !styles.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(styles.enumerated()), id: \.offset) { index, style in
                        SlotTileView(index: index, style: style, table: table,
                                     isCurrent: snapshot.currentSlotIndex == index
                                         || snapshot.inputSlotIndex == index,
                                     note: snapshot.note(for: style),
                                     inputCheck: snapshot.inputCheckDisplay(for: index, atUptime: now))
                    }
                }
                if let latest = snapshot.inputChecks.max(by: { $0.sourceTime < $1.sourceTime }),
                   let check = snapshot.inputCheckDisplay(for: latest.slotIndex, atUptime: now),
                   check.showsSymbol {
                    Text(check.message(slotNumber: latest.slotIndex + 1))
                        .font(.caption)
                        .foregroundStyle(check.verdict == .differs ? Color.red : Color.secondary)
                }
                if predictionsOn {
                    Text(GlyphDisplayRenderer(table: nil).predictionLine(snapshot))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func symbol(_ status: DisplayStatus) -> String {
        switch status {
        case .stopped: return "power"
        case .waiting: return "hourglass"
        case .collecting: return "eye"
        case .yourTurn: return "hand.draw"
        case .complete: return "checkmark.seal"
        case .inferred, .provisional: return "questionmark.circle"
        case .stale, .obstructed, .conflicted, .unknownPhase: return "exclamationmark.triangle"
        }
    }

    private func tint(_ status: DisplayStatus) -> Color {
        switch status {
        case .stopped, .waiting: return .secondary
        case .collecting: return .cyan
        case .yourTurn: return .purple
        case .complete: return .green
        case .inferred, .provisional: return .yellow
        case .stale, .obstructed, .conflicted, .unknownPhase: return .orange
        }
    }

    private func hint(_ status: DisplayStatus) -> LocalizedStringResource {
        switch status {
        case .stopped: return "Tap Start, then open a Glyph hack in Ingress."
        case .waiting: return "Start a Glyph hack. The sequence is picked up automatically."
        case .collecting: return "Keep watching. Each Glyph is saved as the game shows it."
        case .yourTurn: return "Draw them in order. The highlighted slot is the one you're on."
        case .complete: return "All done. Start the next hack whenever you're ready."
        case .inferred: return "The slot row was hidden, so the order is a best guess."
        case .provisional: return "Starting up…"
        case .stale: return "The screen feed paused. If it doesn't come back, stop and start again."
        case .obstructed: return "Something is covering the slot row. Move the floating window or wait for the banner to go."
        case .conflicted: return "The number of slots changed during the hack. Check before you draw."
        case .unknownPhase: return "Keep the Glyph screen visible so the app can follow along."
        }
    }
}
