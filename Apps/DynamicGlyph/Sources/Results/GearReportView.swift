import SwiftUI
import UIKit

/// Lets a player say what was wrong with one gear reading and send it, with
/// its panel pictures and log lines, as a zip.
struct GearReportView: View {
    let subject: GearReportSubject

    @Environment(\.dismiss) private var dismiss
    @State private var problems: Set<GearReportProblem> = []
    @State private var note = ""
    /// On by default: a crop that missed a row is only seen in the whole frame.
    @State private var includesFullFrames = true
    @State private var isPreparing = false
    @State private var problem: String?
    @State private var sharing: SharedArchive?
    /// Kept apart from `sharing`, which is already nil by the time the sheet
    /// reports that it went away.
    @State private var preparedArchive: URL?
    @State private var sent = false

    private var canSend: Bool {
        !isPreparing && (!problems.isEmpty || GearReportBuilder.trimmed(note) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What was wrong?") {
                    ForEach(GearReportProblem.allCases, id: \.self) { item in
                        Toggle(isOn: Binding(
                            get: { problems.contains(item) },
                            set: { if $0 { problems.insert(item) } else { problems.remove(item) } })) {
                            Text(item.label)
                        }
                    }
                }
                Section("Note") {
                    TextField("What did the game show? (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Toggle("Include full screenshots", isOn: $includesFullFrames)
                } footer: {
                    Text("The whole screen at each panel picture, so a reader can see what the picture missed. They show the map and the portal's name, which can tell where you were.")
                }
                Section {
                    Button {
                        Task { await share() }
                    } label: {
                        HStack {
                            Label("Create and share report", systemImage: "square.and.arrow.up")
                            if isPreparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canSend)
                } footer: {
                    Text(includesFullFrames
                         ? LocalizedStringResource("The zip holds this reading, a picture of it as shown here, its item panel pictures, the full screenshots and its lines from the session's logs, with what you chose and your note. Nothing else from the session goes in.")
                         : LocalizedStringResource("The zip holds this reading, a picture of it as shown here, its item panel pictures and its lines from the session's logs, with what you chose and your note. Nothing else from the session goes in, and the panel titles are hidden in the pictures."))
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Report a gear reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .closesForControlStart($sharing)
            .sheet(item: $sharing, onDismiss: finishSharing) { archive in
                ActivityView(items: [archive.url]) { completed in
                    sent = completed
                    sharing = nil
                }
            }
        }
    }

    private func share() async {
        isPreparing = true
        problem = nil
        defer { isPreparing = false }
        let subject = self.subject, problems = self.problems, note = self.note
        let includesFullFrames = self.includesFullFrames
        // Drawn here, on the main actor; the rest is file work.
        let readingImage = GearCheckContent.png(subject)
        let app = SupportContact.appVersion
        let system = "iOS \(UIDevice.current.systemVersion) · \(SupportContact.hardware)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Reports")
        // Copying the pictures and reading the session's log stay off the main thread.
        let result = await Task.detached {
            Result {
                try GearReportBuilder().archive(subject, problems: problems, note: note, app: app,
                                                system: system, now: Date(), includesFullFrames: includesFullFrames,
                                                readingImage: readingImage, into: directory)
            }
        }.value
        switch result {
        case .success(let url):
            preparedArchive = url
            sharing = SharedArchive(url: url)
        case .failure(let error):
            problem = String(localized: "Couldn't prepare the report: \(error.localizedDescription)",
                             comment: "The placeholder is the system's error message.")
        }
    }

    /// The zip is a copy made only for sending. Once sent, the report is done;
    /// closing the share sheet without sending leaves it open to try again.
    private func finishSharing() {
        if let preparedArchive { try? FileManager.default.removeItem(at: preparedArchive) }
        preparedArchive = nil
        if sent { dismiss() }
    }
}

extension GearReportProblem {
    var label: LocalizedStringResource {
        switch self {
        case .missingItem: return LocalizedStringResource("An item is missing")
        case .wrongItem: return LocalizedStringResource("An item is wrong")
        case .wrongQuantity: return LocalizedStringResource("A quantity is wrong")
        case .wrongLevel: return LocalizedStringResource("A level or rarity is wrong")
        case .wrongHack: return LocalizedStringResource("It belongs to another hack")
        case .other: return LocalizedStringResource("Something else")
        }
    }
}
