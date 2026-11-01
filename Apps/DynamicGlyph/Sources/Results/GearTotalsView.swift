import SwiftUI
import GlyphRecognition

/// The period's gear as one row per item, split into level or rarity chips,
/// so a player can count what they got.
struct GearTotalsView: View {
    let statistics: HackStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: GearSummary.displayLine(statistics))
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: GearSummary.line(statistics)))
            ForEach(statistics.gear) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            // Game terms, printed as the English game prints them.
                            Text(verbatim: group.item)
                        } icon: {
                            Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                        }
                        Spacer()
                        Text(verbatim: "\(group.total)").font(.body.bold()).monospacedDigit()
                    }
                    if !group.chips.isEmpty || group.multiplied > 0 {
                        FlowLayout(spacing: 6) {
                            ForEach(group.chips) { chip in GearChip(chip: chip) }
                            if group.multiplied > 0 {
                                Text("\(group.multiplied) multiplied",
                                     comment: "Statistics summary card: how many of those items came from drops the game multiplied, as on the first hack of the day.")
                                    .font(.caption).foregroundStyle(.red)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.red.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.leading, 30)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if statistics.gearIncomplete > 0 {
                Label {
                    Text("\(statistics.gearIncomplete) of \(statistics.gearComplete + statistics.gearIncomplete) gear readings weren't complete, so totals may be low.",
                         comment: "Statistics gear totals: coverage note. A reading is one hack's or one drop group's item panels.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "● L8 40", in the game's level colours or the rarity meter's.
private struct GearChip: View {
    let chip: HackStatistics.GearGroup.Chip

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: "\(label) \(chip.quantity)").monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private var label: String {
        switch chip.split {
        case .level(let level): return "L\(level)"
        case .levelUnread: return "L?"
        case .rarity(let rarity): return rarity.label
        }
    }

    private var color: Color {
        switch chip.split {
        case .level(let level): return Self.levelColors[min(max(level, 1), 8) - 1]
        case .levelUnread, .rarity(.unreadable): return .gray
        case .rarity(.common): return Color(red: 0.25, green: 0.73, blue: 0.59)
        case .rarity(.rare): return Color(red: 0.67, green: 0.45, blue: 0.96)
        case .rarity(.veryRare): return Color(red: 0.94, green: 0.27, blue: 0.73)
        }
    }

    /// The game's level colours, L1 to L8.
    private static let levelColors: [Color] = [
        Color(red: 0.996, green: 0.808, blue: 0.353), Color(red: 1.0, green: 0.651, blue: 0.188),
        Color(red: 1.0, green: 0.451, blue: 0.082), Color(red: 0.894, green: 0.0, blue: 0.0),
        Color(red: 0.992, green: 0.161, blue: 0.573), Color(red: 0.922, green: 0.149, blue: 0.804),
        Color(red: 0.757, green: 0.141, blue: 0.878), Color(red: 0.588, green: 0.153, blue: 0.957),
    ]
}

/// Lays chips out in rows, wrapping at the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
