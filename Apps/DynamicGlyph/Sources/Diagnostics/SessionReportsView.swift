import SwiftUI
import UIKit

/// Past sessions, newest first, each one a folder a tester can read or send.
struct SessionReportsView: View {
    /// The running session's folder, which is still being written and so can
    /// be neither shared nor deleted yet.
    let activeFolder: String?

    private let store = SessionReportStore()
    @State private var reports: [SessionReport] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(.orange)
            } else if reports.isEmpty {
                Text("No sessions saved. Turn on Save logs and screenshots in Settings to keep a report of each session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                NavigationLink {
                    SessionReportDetailView(report: report, store: store,
                                            isActive: report.name == activeFolder) { reload() }
                } label: {
                    ReportRow(report: report, isActive: report.name == activeFolder)
                }
                .deleteDisabled(report.name == activeFolder)
            }
            .onDelete { offsets in
                for report in offsets.map({ reports[$0] }) {
                    do { try store.delete(report) }
                    catch {
                        loadError = String(localized: "Couldn't delete \(report.name): \(error.localizedDescription)",
                                           comment: "First: the report's folder name. Second: the system's error message.")
                    }
                }
                reload()
            }
        }
        .navigationTitle("Session reports")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        do {
            reports = try store.reports()
            loadError = nil
        } catch {
            loadError = String(localized: "Couldn't read the reports: \(error.localizedDescription)",
                               comment: "The placeholder is the system's error message.")
        }
    }
}

private struct ReportRow: View {
    let report: SessionReport
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(report.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? report.name)
            HStack(spacing: 6) {
                Text(ByteCountFormatter.string(fromByteCount: report.byteCount, countStyle: .file))
                if report.hasScreenRecording { Label("Video", systemImage: "video") }
                if isActive { Text("Running").foregroundStyle(.green) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct SessionReportDetailView: View {
    let report: SessionReport
    let store: SessionReportStore
    let isActive: Bool
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sharing: SharedArchive?
    /// Kept apart from `sharing`, which is already nil by the time the sheet
    /// reports that it went away.
    @State private var preparedArchive: URL?
    @State private var isPreparing = false
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var note = ""

    var body: some View {
        List {
            Section {
                TextField("Note for the report (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(isActive)
                Button {
                    Task { await share() }
                } label: {
                    HStack {
                        Label("Share report…", systemImage: "square.and.arrow.up")
                        if isPreparing { Spacer(); ProgressView() }
                    }
                }
                .disabled(isActive || isPreparing)
                Button("Delete report", role: .destructive) { confirmingDelete = true }
                    .disabled(isActive)
            } footer: {
                Text(footer)
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.orange) }
            }
            Section("Event log") {
                // The log itself is technical and stays as written.
                Group {
                    if let log = store.eventLog(for: report) { Text(verbatim: log) }
                    else { Text("This session wrote no event log.") }
                }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(report.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? report.name)
        .navigationBarTitleDisplayMode(.inline)
        .closesForControlStart($sharing)
        .closesForControlStart($confirmingDelete)
        .sheet(item: $sharing, onDismiss: removePreparedArchive) { archive in
            ActivityView(items: [archive.url]) { _ in sharing = nil }
        }
        .confirmationDialog("Delete this report?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try store.delete(report)
                    onDelete()
                    dismiss()
                } catch {
                    problem = String(localized: "Couldn't delete it: \(error.localizedDescription)",
                                     comment: "The placeholder is the system's error message.")
                }
            }
        } message: {
            Text("Its logs, screenshots and any recording are removed from this phone.")
        }
    }

    private var footer: LocalizedStringResource {
        if isActive {
            return LocalizedStringResource("This session is still running. Stop it to share or delete its report.")
        }
        return report.hasScreenRecording
            ? LocalizedStringResource("The report is a zip of this session's logs, screenshots and screen recording, with your note if you wrote one. Screenshots can show your location and anything else on screen, so check it before sending.")
            : LocalizedStringResource("The report is a zip of this session's logs and screenshots, with your note if you wrote one. Screenshots can show your location and anything else on screen, so check it before sending.")
    }

    private func share() async {
        isPreparing = true
        problem = nil
        defer { isPreparing = false }
        let store = self.store
        let report = self.report
        let note = self.note
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Reports")
        // Zipping a session with a recording can take a moment; keep it off
        // the main thread.
        let result = await Task.detached { Result { try store.archive(report, note: note, into: directory) } }.value
        switch result {
        case .success(let url):
            preparedArchive = url
            sharing = SharedArchive(url: url)
        case .failure(let error):
            problem = String(localized: "Couldn't prepare the report: \(error.localizedDescription)",
                             comment: "The placeholder is the system's error message.")
        }
    }
}

extension SessionReportDetailView {
    /// The zip is a copy made only for sending; the session folder stays.
    fileprivate func removePreparedArchive() {
        if let preparedArchive { try? FileManager.default.removeItem(at: preparedArchive) }
        preparedArchive = nil
    }
}

/// A zip made only for sending, shown in the share sheet.
struct SharedArchive: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet. SwiftUI's `ShareLink` needs the file to exist
/// before the button is drawn, and this one is made on demand.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// Whether the player sent it, rather than closing the sheet.
    let onComplete: (_ completed: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
