import SwiftUI
import UIKit
import GlyphRecognition

/// The items read from the game's panels after one hack, or in one drop
/// group no hack claimed, for testers to compare with what the game showed.
/// Item names stay as the game prints them.
struct HackGearSection: View {
    let reading: HackGearAttachment.Reading
    let pictures: [HackGearPicture]
    let portalLevel: PortalLevelEstimate?
    /// A drop group no Glyph hack claimed: no Bonus panel is expected of it,
    /// and no portal level is matched to it.
    let isDrop: Bool
    /// Nil beside the pictures. With pictures the report is offered in their
    /// sheet, where the player has just compared them; without, on the card.
    let report: GearReportSubject?
    @State private var showsPictures = false
    @State private var reporting = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(attachment: HackGearAttachment, record: HackResultRecord) {
        reading = attachment.reading
        pictures = attachment.panelPictures
        portalLevel = attachment.portalLevel
        isDrop = false
        report = .hackGear(attachment, recordID: record.id, date: record.date, hack: record.summary)
    }

    init(drop: GearDrop, record: GearDropRecord) {
        reading = .read(drop.summary)
        pictures = drop.panelPictures
        portalLevel = nil
        isDrop = true
        report = .drop(drop, recordID: record.id, date: record.date)
    }

    /// The same reading without its pictures, beside them in the sheet.
    fileprivate init(reading: HackGearAttachment.Reading, portalLevel: PortalLevelEstimate?, isDrop: Bool) {
        self.reading = reading
        pictures = []
        self.portalLevel = portalLevel
        self.isDrop = isDrop
        report = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !isDrop { PortalLevelLine(estimate: portalLevel) }
            switch reading {
            case .read(let summary):
                ForEach(summary.panels.indices, id: \.self) { index in
                    panel(summary.panels[index])
                }
                if summary.association == .orderedWithoutBonus {
                    Text("No Bonus items panel was shown for this hack.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .notRead(let reason):
                Text(reason == "captureStopped"
                     ? LocalizedStringResource("Capture stopped before the item panels appeared.")
                     : LocalizedStringResource("The item panels didn't appear while this hack was waiting for them."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !pictures.isEmpty {
                Button {
                    showsPictures = true
                } label: {
                    Label("Check against the panels (\(pictures.count))", systemImage: "photo.on.rectangle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
            if report != nil, pictures.isEmpty {
                Button {
                    reporting = true
                } label: {
                    Label("Report this reading…", systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
            Text("Read from the game's item panels. Details are in the session's logs.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .closesForControlStart($showsPictures)
        .closesForControlStart($reporting)
        .sheet(isPresented: $showsPictures) {
            GearPicturesView(content: GearCheckContent(
                section: HackGearSection(reading: reading, portalLevel: portalLevel, isDrop: isDrop),
                pictures: pictures, portalLevel: portalLevel), report: report)
        }
        .sheet(isPresented: $reporting) {
            if let report { GearReportView(subject: report) }
        }
    }

    /// The heading beside how the reading went; at accessibility sizes the
    /// heading takes a line of its own, so it never breaks inside the word.
    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Label("Gear", systemImage: "shippingbox")
                    .font(.subheadline.bold())
                Text(headline).font(.subheadline).foregroundStyle(headlineStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Label("Gear", systemImage: "shippingbox")
                    .font(.subheadline.bold())
                Spacer()
                Text(headline).font(.subheadline).foregroundStyle(headlineStyle)
            }
        }
    }

    /// Every panel shown read in full; a hack's gear also needs its Bonus panel.
    private func isComplete(_ summary: GearDropSummary) -> Bool {
        isDrop ? summary.panelsReadInFull : summary.bothPanelsRead && summary.unidentifiedQuantity == 0
    }

    private var headline: String {
        guard case .read(let summary) = reading else {
            return String(localized: "Gear not read", comment: "Hack card, gear section: no item panels were read.")
        }
        let count = summary.recognizedQuantity
        if isComplete(summary) {
            return String(localized: "\(count) items recognized",
                          comment: "Hack card, gear section: both item panels were read in full.")
        }
        return String(localized: "Gear partly read",
                      comment: "Hack card, gear section: some item rows or a panel could not be read.")
    }

    private var headlineStyle: Color {
        guard case .read(let summary) = reading else { return .secondary }
        return isComplete(summary) ? .primary : .orange
    }

    private func panel(_ panel: GearDropSummary.Panel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(panel.stage == .bonus
                     ? LocalizedStringResource("Bonus items")
                     : LocalizedStringResource("From the portal"))
                if panel.partial {
                    Text("· partly read").foregroundStyle(.orange)
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(panel.effects ?? [], id: \.self) { effect in
                Text("Applied effect: \(effect)", comment: "Hack item panel. The placeholder is a game term such as ITO EN (+), kept in English.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if panel.entries.isEmpty {
                Text("No items read").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(panel.entries.indices, id: \.self) { index in
                entry(panel.entries[index])
            }
        }
    }

    private func entry(_ entry: GearDropEntry) -> some View {
        HStack(spacing: 6) {
            if let item = entry.item {
                VStack(alignment: .leading, spacing: 2) {
                    // Game terms, printed as the English game prints them.
                    Text(verbatim: entry.level.map { "L\($0) \(item)" } ?? item)
                    // A fixed rarity also corrects readings saved before it was known.
                    if let rarity = entry.intrinsicRarity ?? entry.rarity {
                        Text(verbatim: rarity.label).font(.caption)
                            .foregroundStyle(rarity == .unreadable ? Color.orange : .secondary)
                    }
                    if entry.levelState == .unreadable {
                        Text("level unread").font(.caption).foregroundStyle(.orange)
                    }
                    if entry.multiplied == true {
                        Text("multiplied", comment: "Hack card, one item: the game showed its quantity in red, as on the first hack of the day.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            } else {
                Text("Unrecognized item").foregroundStyle(.orange)
            }
            Spacer()
            // Red, as the game prints a multiplied quantity.
            Text(verbatim: "×\(entry.quantity)").monospacedDigit()
                .foregroundStyle(entry.multiplied == true ? Color.red : .primary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// The saved panel pictures beside what was read from them, so a tester can
/// see where a reading went wrong, and report it from there.
private struct GearPicturesView: View {
    let content: GearCheckContent
    let report: GearReportSubject?
    @Environment(\.dismiss) private var dismiss
    @State private var reporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if report != nil {
                        Button {
                            reporting = true
                        } label: {
                            Label("Report this reading…", systemImage: "exclamationmark.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding()
            }
            .navigationTitle("Item panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .closesForControlStart($reporting)
            .sheet(isPresented: $reporting) {
                if let report { GearReportView(subject: report) }
            }
        }
    }
}

/// What the pictures sheet shows: the reading, then each panel picture. A
/// report carries a rendering of it, so it is its own view.
struct GearCheckContent: View {
    let section: HackGearSection
    let pictures: [HackGearPicture]
    let portalLevel: PortalLevelEstimate?
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init(section: HackGearSection, pictures: [HackGearPicture], portalLevel: PortalLevelEstimate?) {
        self.section = section
        self.pictures = pictures
        self.portalLevel = portalLevel
    }

    init(subject: GearReportSubject) {
        switch subject {
        case .hackGear(let gear, _, _, _):
            self.init(section: HackGearSection(reading: gear.reading, portalLevel: gear.portalLevel, isDrop: false),
                      pictures: gear.panelPictures, portalLevel: gear.portalLevel)
        case .drop(let drop, _, _):
            self.init(section: HackGearSection(reading: .read(drop.summary), portalLevel: nil, isDrop: true),
                      pictures: drop.panelPictures, portalLevel: nil)
        }
    }

    /// A PNG of the sheet's content, as the player saw it, for a report.
    @MainActor static func png(_ subject: GearReportSubject) -> Data? {
        let renderer = ImageRenderer(content: GearCheckContent(subject: subject)
            .padding()
            .frame(width: 400)
            .background(Color(.systemGroupedBackground)))
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section.card()
            if let level = portalLevel {
                PortalLevelSources(estimate: level).card()
            }
            ForEach(Array(pictures.enumerated()), id: \.offset) { _, picture in
                VStack(alignment: .leading, spacing: 6) {
                    Text(picture.stage == .bonus
                         ? LocalizedStringResource("Bonus items")
                         : LocalizedStringResource("From the portal"))
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    if let url = picture.url(in: root), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel(Text("Picture of the item panel"))
                    } else {
                        Text("This picture isn't on this iPhone. It was deleted with the session's logs, or taken on another iPhone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The panel's title is hidden in every picture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Portal L6", or a range when the sources leave several. How sure the
/// reading is stays in the logs and the pictures sheet, not on the card.
private struct PortalLevelLine: View {
    let estimate: PortalLevelEstimate?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            rows
        } else {
            line
        }
    }

    private var line: some View {
        Label {
            HStack(spacing: 6) {
                level
                if let faction = estimate?.faction {
                    Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                    // A game term, printed as the English game prints it.
                    Text(verbatim: faction.name).foregroundStyle(faction.color)
                }
            }
        } icon: {
            Image(systemName: "mappin.circle")
        }
        .font(.callout)
    }

    /// At accessibility sizes, side by side the level and the faction wrap
    /// into each other: one full-width row each, its name above it.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Portal", comment: "Hack card, gear section, at the largest text sizes: names the row below it, the portal's level such as L8.")
                } icon: {
                    Image(systemName: "mappin.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                levelValue
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let faction = estimate?.faction {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Faction", comment: "Hack card, gear section, at the largest text sizes: names the row below it, the portal's faction such as Enlightened.")
                        .font(.caption).foregroundStyle(.secondary)
                    // A game term, printed as the English game prints it.
                    Text(verbatim: faction.name).foregroundStyle(faction.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.callout)
    }

    /// "L8", or a range, under the row's name; game terms, as on the line.
    @ViewBuilder
    private var levelValue: some View {
        if let estimate, let level = estimate.level {
            Text(verbatim: "L\(level)")
        } else if let estimate {
            Text(verbatim: "L\(estimate.lowest)–L\(estimate.highest)")
        } else {
            Text("not read").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var level: some View {
        if let estimate, let level = estimate.level {
            Text("Portal L\(level)")
        } else if let estimate {
            Text("Portal L\(estimate.lowest)–L\(estimate.highest)")
        } else {
            Text("Portal level not read").foregroundStyle(.secondary)
        }
    }
}

/// The faction a portal screen's resonator bars were drawn in.
private extension PortalFaction {
    var name: String {
        switch self {
        case .resistance: return "Resistance"
        case .enlightened: return "Enlightened"
        case .machina: return "Machina"
        }
    }

    var color: Color {
        switch self {
        case .resistance: return .blue
        case .enlightened: return .green
        case .machina: return .red
        }
    }
}

/// What each source said about the portal's level, so a tester can see why
/// a level was chosen.
private struct PortalLevelSources: View {
    let estimate: PortalLevelEstimate
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How the portal level was read").font(.subheadline.bold())
            source("Resonators", value: resonators)
            source("Badge color", value: estimate.badgeLevels.map(range) ?? String(localized: "not read"))
            source("Glyphs in the hack", value: estimate.glyphCount.map { count in
                let levels = PortalLevelRules.levels(forGlyphCount: count)
                return levels.map { "\(count) → " + range(Array($0)) } ?? "\(count)"
            } ?? String(localized: "not read"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resonators: String {
        guard let levels = estimate.resonators, !levels.isEmpty else { return String(localized: "not read") }
        let read = levels.map { "L\($0)" }.joined(separator: " ")
        let unread = estimate.unreadSlots ?? 0
        return unread > 0 ? String(localized: "\(read), \(unread) unread") : read
    }

    private func range(_ levels: [Int]) -> String {
        guard let low = levels.min(), let high = levels.max() else { return "–" }
        return low == high ? "L\(low)" : "L\(low)–L\(high)"
    }

    /// Side by side; at accessibility sizes the source's name above what it
    /// said, so neither is squeezed.
    @ViewBuilder
    private func source(_ title: LocalizedStringResource, value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: value)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: value).multilineTextAlignment(.trailing)
            }
            .font(.callout)
        }
    }
}
