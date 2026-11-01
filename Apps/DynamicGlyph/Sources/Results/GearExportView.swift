import SwiftUI
import GlyphRecognition

/// What will be exported, what was left out, the one choice about time, and
/// the file itself to preview and share. Every option starts at its default
/// each time the sheet opens.
struct GearExportView: View {
    let snapshot: GearExport.Snapshot
    /// What was chosen, such as "Today" or "3 selected".
    let scope: String
    @Environment(\.dismiss) private var dismiss
    @State private var options = GearExport.Options()
    @State private var file: GearExport.File?
    @State private var sharing: SharedExport?
    @State private var problem: String?
    /// Kept apart from `sharing`, which is nil by the time the share
    /// sheet's dismissal runs.
    @State private var sharedFile: URL?

    var body: some View {
        NavigationStack {
            Form {
                if let file {
                    contents(file)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Export gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Made again whenever an option changes, so the counts, preview,
            // checksum and shared file always describe the same bytes.
            .task(id: options) { file = GearExport.make(snapshot, options: options) }
            .closesForControlStart($sharing)
            .closesForControlStart($problem)
            .sheet(item: $sharing, onDismiss: removeShared) { shared in
                ActivityView(items: [shared.item]) { _ in sharing = nil }
            }
            .alert("Couldn't prepare the file",
                   isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: problem ?? "")
            }
        }
    }

    @ViewBuilder
    private func contents(_ file: GearExport.File) -> some View {
        let counts = file.counts
        Section {
            LabeledContent("Exporting") { Text(verbatim: scope) }
            LabeledContent("Hack results") { Text(verbatim: "\(counts.hacks)") }
            LabeledContent("Drops") { Text(verbatim: "\(counts.drops)") }
            LabeledContent("Rows") { Text(verbatim: "\(counts.rows)") }
        } footer: {
            Text("Only what the app read is here: hacks and drops it didn't see, or read no items from, aren't counted.")
        }
        if counts.partlyRead + counts.notRead + counts.unavailable + counts.unsupported
            + counts.skipped + counts.inProgress > 0 {
            Section {
                line("Partly read", counts.partlyRead)
                line("Gear not read", counts.notRead)
                line("No gear reading", counts.unavailable)
                line("Gear in a format this version can't read", counts.unsupported)
                line("Left out: saved in a format this version can't read", counts.skipped)
                line("Left out: still being read", counts.inProgress)
            } header: {
                Text("Incomplete or left out")
            } footer: {
                Text("Records with no gear reading are in the file with their status, and blank item columns. Blank means unknown, never zero.")
            }
        }
        Section {
            Toggle("Include the hour", isOn: Binding(get: { options.timePrecision == .hour },
                                                     set: { options.timePrecision = $0 ? .hour : .day }))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Each record's time is the hour, or the day, around when the app received it, in the time zone of the iPhone that captured it. Records from before the app kept that use UTC, with no local date. No exact times, portal names, pictures or device details are included.")
                Text("Your faction, as set in Settings when each hack was captured, is included with the portal's faction.")
            }
        }
        Section {
            NavigationLink("Preview the file") { GearExportPreview(file: file) }
            Button("Share the file…", systemImage: "square.and.arrow.up") { share(file) }
            Button("Share a summary as text…", systemImage: "text.alignleft") {
                sharing = SharedExport(item: GearExport.text(snapshot, counts: counts, scope: scope,
                                                             options: options))
            }
        } footer: {
            Text(verbatim: file.fileName)
        }
        Section {
            Text(verbatim: file.checksum)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        } header: {
            Text("File checksum (SHA-256)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shows that a copy of the file wasn't changed on the way. It doesn't prove what the game showed.")
                Text("Each record's id is made from SHA-256 of a random code the app created when it saved the record. The same record has the same id in every export, from every iPhone it synced to, so it can be counted once. The id says nothing about you, your iPhone or where you played.")
            }
        }
    }

    @ViewBuilder
    private func line(_ title: LocalizedStringResource, _ count: Int) -> some View {
        if count > 0 {
            LabeledContent { Text(verbatim: "\(count)") } label: { Text(title) }
        }
    }

    private func share(_ file: GearExport.File) {
        do {
            let url = try GearExportFiles.write(file)
            sharedFile = url
            sharing = SharedExport(item: url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func removeShared() {
        // The text summary has no file; a prepared CSV is removed once the
        // share sheet closes.
        if let url = sharedFile { GearExportFiles.remove(url) }
        sharedFile = nil
    }
}

/// One thing in the share sheet: the CSV file or the summary text.
private struct SharedExport: Identifiable {
    let id = UUID()
    let item: Any

    init(item: URL) { self.item = item }
    init(item: String) { self.item = item }
}

/// The file's first lines exactly as they will be sent.
private struct GearExportPreview: View {
    let file: GearExport.File
    static let lineLimit = 300

    var body: some View {
        let lines = String(decoding: file.data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 8) {
                if lines.count > Self.lineLimit {
                    Text("The first \(Self.lineLimit) of \(lines.count) lines.",
                         comment: "Gear export preview: only the start of a long file is shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: lines.prefix(Self.lineLimit).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .padding()
        }
        .navigationTitle(Text(verbatim: file.fileName))
        .navigationBarTitleDisplayMode(.inline)
    }
}
