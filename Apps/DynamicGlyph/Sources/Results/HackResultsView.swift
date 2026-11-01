import SwiftUI
import CloudKit
import GlyphRecognition

/// Every hack result this app has read and kept, newest first, and the two
/// choices that control reading and keeping them.
struct HackResultsView: View {
    /// Not observed: the engine publishes several times a second while
    /// capturing, and the page needs only the values below, which
    /// ContentView passes in. The floating window preview and Result
    /// options observe it themselves.
    let engine: CaptureEngine
    /// Capturing with the floating window on: only then is the preview,
    /// which observes the engine, in the page at all.
    let showsFloatingWindowPreview: Bool
    let assistsGlyphs: Bool
    let sessionDiagnosticsEnabled: Bool
    let shapeTable: GlyphTable?
    @ObservedObject var results: HackResults
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingOptions = false
    @State private var showingSummary = false
    /// Where the timeline's handles stand, for the whole page; the Home
    /// Screen widget's link sets it too.
    @Binding var timelineSelection: StatisticsSelection
    @State private var selecting = false
    /// Entry ids, so a list that reorders or grows never shifts the choice.
    @State private var selection: Set<String> = []
    @State private var pendingDeletion: DeletionRequest?
    @State private var deletionError: String?
    @State private var exporting: ExportRequest?
    /// The sorted, grouped and totalled records, kept between evaluations.
    @State private var model = StatisticsPageModel()

    var body: some View {
        // A live end moves on each minute; the store's changes count at once.
        TimelineView(.everyMinute) { context in
            page(model.snapshot(of: results, selection: timelineSelection, tick: context.date))
        }
    }

    @ViewBuilder
    private func page(_ snapshot: StatisticsPageModel.Snapshot) -> some View {
        let now = snapshot.now, history = snapshot.history, range = snapshot.range
        let statistics = snapshot.statistics, list = snapshot.list
        let readout = StatisticsRangeText.readout(timelineSelection, now: now, oldest: history.oldest)
        ScrollView {
            // Outside the lazy stack, which would drop the preview, and with it
            // the layer, once it scrolled out of view.
            if showsFloatingWindowPreview {
                FloatingWindowPreview(engine: engine).padding([.horizontal, .top])
            }
            LazyVStack(alignment: .leading, spacing: 16) {
                StatisticsRangeHeader(selection: $timelineSelection, history: history,
                                      ticks: snapshot.ticks, now: now)
                ItemsDroppedCard(statistics: statistics, range: range, history: history,
                                 empty: emptyReason(history.drops, history, range), problem: results.problem)
                    .animation(reduceMotion ? nil : .default, value: statistics.items)
                // Drops only, with Glyph help off: no hacks to show.
                if assistsGlyphs {
                    HacksCard(statistics: statistics, range: range, history: history,
                              empty: emptyReason(history.hacks, history, range), problem: results.problem)
                        .animation(reduceMotion ? nil : .default, value: statistics.hacks)
                }
                StatisticsRowsCard(optionsStatus: optionsStatus, showSummary: { showingSummary = true },
                                   showOptions: { showingOptions = true })
                if let problem = results.problem {
                    // Already localized by HackResults.
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Results", comment: "Statistics: the header over the hacks and drops in the shown range.")
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(verbatim: list.shown.count.formatted())
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.top, 8)
                if results.records.isEmpty && results.drops.isEmpty {
                    Text(!assistsGlyphs
                         ? LocalizedStringResource("No drops yet. After each hack, the gear the game showed appears here.")
                         : results.readsResults
                         ? LocalizedStringResource("No results yet. After each Glyph hack, its result appears here.")
                         : LocalizedStringResource("Reading results is off."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                // One lazy row per heading and card, so a long day's cards
                // are made as they scroll in, not all at once.
                ForEach(list.rows) { item in
                    switch item {
                    case .day(let day):
                        Text(day, format: .dateTime.weekday(.wide).month().day())
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    case .entry(let entry, let isFirst):
                        // 12 pt between one day's cards; the page's 16 around them.
                        row(entry, in: list)
                            .padding(.top, isFirst ? 0 : -4)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Statistics")
        .toolbar {
            let state = StatisticsToolbarState(shownEntries: list.shown.count, selecting: selecting)
            // Off rather than gone on an empty range, so the bar doesn't jump.
            if state.showsExport {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Export", systemImage: "square.and.arrow.up") {
                        export(list.shown, scope: readout.exportScope)
                    }
                        .disabled(!state.exportEnabled)
                        .accessibilityHint(Text("Exports the gear of the period shown above."))
                }
            }
            if state.showsSelect {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? LocalizedStringResource("Done") : LocalizedStringResource("Select")) {
                        selecting.toggle()
                        selection = []
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar(list) }
        }
        // Records can arrive, close or leave through iCloud while selecting;
        // the choice keeps only those still here and deletable.
        .onChange(of: list.deletableIDs) { _, ids in
            selection.formIntersection(ids)
            if list.shown.isEmpty { selecting = false }
        }
        .closesForControlStart($pendingDeletion)
        .closesForControlStart($deletionError)
        .closesForControlStart($exporting)
        .closesForControlStart($showingOptions)
        .closesForControlStart($showingSummary)
        .confirmationDialog("Delete from Statistics?",
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { request in
            Button("Delete", role: .destructive) { delete(request) }
        } message: { request in
            Text(verbatim: deletionMessage(request))
        }
        .sheet(item: $exporting) { request in
            GearExportView(snapshot: request.snapshot, scope: request.scope)
        }
        .alert("Nothing was deleted",
               isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deletionError ?? "")
        }
        // With iCloud sync on, this also asks iCloud for other iPhones' results.
        .refreshable {
            await results.refresh()
        }
        .sheet(isPresented: $showingOptions) {
            ResultOptionsView(engine: engine, results: results)
        }
        .sheet(isPresented: $showingSummary) {
            HackStatisticsView(statistics: statistics,
                               dateLine: ([readout.line1] + [readout.line2].compactMap { $0 }).joined(separator: "\n"),
                               showsAccuracy: sessionDiagnosticsEnabled, keepsResults: results.keepsResults)
        }
    }

    private var showsGear: Bool { results.readsGear && assistsGlyphs }

    /// Why a card's empty range is empty, by its own stream's history.
    private func emptyReason(_ stream: StatisticsHistory.Stream?, _ history: StatisticsHistory,
                             _ range: StatisticsRange) -> StatisticsEmptyReason {
        StatisticsEmptyReason(range: range, stream: stream, history: history, keepsResults: results.keepsResults,
                              storeProblem: results.problem != nil)
    }
    /// Without Glyph assistance only item panels are read.
    private var readsSomething: Bool { results.readsResults || !assistsGlyphs }

    /// The Options row's status: what is kept and read, or that reading is off.
    private var optionsStatus: String {
        guard readsSomething else { return String(localized: "Result reading is off") }
        return summaryDetail
    }

    private var summaryDetail: String {
        var parts = [results.keepsResults
                     ? String(localized: "Kept for 90 days", comment: "Statistics page summary: results are saved after the app closes.")
                     : String(localized: "Not kept after the app closes", comment: "Statistics page summary.")]
        if case .failed = results.syncState {
            parts.append(String(localized: "iCloud sync paused", comment: "Statistics page summary: iCloud sync is on but failing; Result options say why."))
        } else if results.syncsWithICloud {
            parts.append(String(localized: "iCloud sync on", comment: "Statistics page summary: saved results sync through iCloud."))
        }
        if showsGear {
            parts.append(String(localized: "Reading gear", comment: "Statistics page summary: the gear-reading test feature is on."))
        }
        return parts.joined(separator: " · ")
    }

    /// A hack, or a drop group no hack claimed, in one list.
    private typealias Entry = StatisticsEntry

    private struct ExportRequest: Identifiable {
        let id = UUID()
        let snapshot: GearExport.Snapshot
        let scope: String
    }

    /// The hacks and drops to delete, fixed when the player asks, so the
    /// confirmation acts on what they chose even if the list changes.
    private struct DeletionRequest {
        let hacks: Set<String>
        let drops: Set<String>
        let hasPictures: Bool
    }

    @ViewBuilder
    private func row(_ entry: Entry, in list: StatisticsList) -> some View {
        let card = Group {
            switch entry {
            case .hack(let record): HackResultCard(record: record, table: shapeTable)
            case .drop(let record): GearDropCard(record: record)
            }
        }
        if selecting {
            let selected = selection.contains(entry.id)
            // The card's own buttons and sheets are out of reach while
            // selecting: one button over the whole row selects it.
            HStack(spacing: 12) {
                Image(systemName: !entry.isDeletable ? "circle.dashed"
                      : selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                card.allowsHitTesting(false)
            }
            .accessibilityHidden(true)
            .overlay {
                Button {
                    if selected { selection.remove(entry.id) } else { selection.insert(entry.id) }
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.isDeletable)
                .accessibilityLabel(Text(verbatim: entry.label))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(entry.isDeletable
                                   ? Text("Selects it to export or delete.")
                                   : Text("Still being read. It can be deleted once it finishes."))
            }
        } else {
            card.contextMenu {
                if entry.isExportable {
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        export([entry], scope: GearExport.scope(of: entry.kind))
                    }
                }
                if entry.isDeletable {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        requestDeletion([entry.id], in: list)
                    }
                }
            }
        }
    }

    private func selectionBar(_ list: StatisticsList) -> some View {
        let all = list.deletableIDs
        let allSelected = !all.isEmpty && selection.isSuperset(of: all)
        return HStack {
            Button(allSelected ? LocalizedStringResource("Deselect All") : LocalizedStringResource("Select All")) {
                selection = allSelected ? [] : all
            }
            .disabled(all.isEmpty)
            Spacer()
            Text("\(selection.count) selected",
                 comment: "Statistics, selecting: how many hacks and drops are chosen.")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("Export", systemImage: "square.and.arrow.up") {
                export(list.shown.filter { selection.contains($0.id) },
                       scope: String(localized: "\(selection.count) selected",
                                     comment: "Statistics, selecting: how many hacks and drops are chosen."))
            }
            .labelStyle(.iconOnly)
            .disabled(selection.isEmpty)
            Button("Delete", systemImage: "trash", role: .destructive) {
                requestDeletion(selection, in: list)
            }
            .labelStyle(.iconOnly)
            .disabled(selection.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    /// Copies the chosen records now: what arrives later isn't in this file.
    private func export(_ chosen: [Entry], scope: String) {
        var records: [HackResultRecord] = [], drops: [GearDropRecord] = []
        for entry in chosen {
            switch entry {
            case .hack(let record): records.append(record)
            case .drop(let record): drops.append(record)
            }
        }
        exporting = ExportRequest(snapshot: GearExport.Snapshot(records: records, drops: drops), scope: scope)
    }

    private func requestDeletion(_ ids: Set<String>, in list: StatisticsList) {
        let chosen = list.shown.filter { ids.contains($0.id) && $0.isDeletable }
        guard !chosen.isEmpty else { return }
        var hacks: Set<String> = [], drops: Set<String> = []
        for entry in chosen {
            switch entry {
            case .hack(let record): hacks.insert(record.id)
            case .drop(let record): drops.insert(record.id)
            }
        }
        pendingDeletion = DeletionRequest(hacks: hacks, drops: drops, hasPictures: chosen.contains(where: \.hasPictures))
    }

    private func delete(_ request: DeletionRequest) {
        do {
            try results.delete(hacks: request.hacks, drops: request.drops)
            selection.subtract(request.hacks.map { "hack/\($0)" } + request.drops.map { "drop/\($0)" })
            if selection.isEmpty { selecting = false }
        } catch {
            // The choice stays, so the player can try again.
            deletionError = error.localizedDescription
        }
    }

    private func deletionMessage(_ request: DeletionRequest) -> String {
        var lines: [String] = []
        if !request.hacks.isEmpty {
            lines.append(String(localized: "Hack results: \(request.hacks.count)",
                                comment: "Statistics, delete confirmation: how many hacks are chosen."))
        }
        if !request.drops.isEmpty {
            lines.append(String(localized: "Drops: \(request.drops.count)",
                                comment: "Statistics, delete confirmation: how many drop groups no hack claimed are chosen."))
        }
        var notes: [String] = []
        if !request.hacks.isEmpty {
            notes.append(String(localized: "Deleting a hack result also deletes its gear reading, and statistics change to match.",
                                comment: "Statistics, delete confirmation."))
        }
        if results.syncsWithICloud {
            notes.append(String(localized: "Saved ones are also deleted from iCloud, and from your other iPhones once they sync.",
                                comment: "Statistics, delete confirmation, with iCloud sync on."))
        }
        if request.hasPictures {
            notes.append(String(localized: "Panel pictures stay in the session's logs until you delete them under Settings › Session logs and reports.",
                                comment: "Statistics, delete confirmation: deleting history leaves the session's picture files."))
        }
        notes.append(String(localized: "This can't be undone.", comment: "Statistics, delete confirmation."))
        return lines.joined(separator: "\n") + "\n\n" + notes.joined(separator: " ")
    }
}

/// The result reading switches, with their explanations as footers.
private struct ResultOptionsView: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var results: HackResults
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var confirmingSync = false
    /// Nil until iCloud has answered, and while sync is off.
    @State private var iCloudStatus: CKAccountStatus?

    private var isBusy: Bool { engine.isCapturing || engine.isPreparing || engine.isStopping }

    var body: some View {
        NavigationStack {
            Form {
                if engine.assistsGlyphs {
                    Section {
                        Toggle("Read results from the game", isOn: $results.readsResults).disabled(isBusy)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(results.syncsWithICloud
                                 ? LocalizedStringResource("After each hack, reads the bonuses and which Glyphs the game accepted from its result screen. Saved results stay on your phone and in your iCloud.")
                                 : LocalizedStringResource("After each hack, reads the bonuses and which Glyphs the game accepted from its result screen. Everything stays on your phone."))
                            if isBusy { Text("Changes to reading apply the next time you tap Start.") }
                        }
                    }
                } else {
                    Section {
                        // With no Glyph list there is no switch in Settings to point to.
                        Text(engine.hasGlyphList
                             ? LocalizedStringResource("Glyph assistance is off in Settings, so only the item panels are read after each hack.")
                             : LocalizedStringResource("After each hack, the item panels are read and their gear is counted.",
                                                       comment: "Statistics options, in place of result reading, when no Glyph list is loaded."))
                            .foregroundStyle(.secondary)
                    }
                }
                if results.readsResults || !engine.assistsGlyphs {
                    Section {
                        Toggle("Keep results after the app closes", isOn: $results.keepsResults)
                        // Turning it on asks first: results then leave this iPhone.
                        Toggle("Sync with iCloud", isOn: Binding(
                            get: { results.syncsWithICloud },
                            set: { on in
                                if on { confirmingSync = true } else { results.syncsWithICloud = false }
                            }))
                            .alert("Sync results with iCloud?", isPresented: $confirmingSync) {
                                Button("Turn On Sync") { results.syncsWithICloud = true }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Saved hack results and gear readings will be uploaded to your private iCloud, so they leave this iPhone. They sync to your other iPhones signed in to the same Apple Account and use your iCloud storage. Pictures of the screen and item panels stay on this iPhone. Turning sync off later stops syncing but doesn't remove what's already in iCloud.")
                            }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keeps up to 1,000 hacks and 1,000 item drops for 90 days. Only what was read is kept, never pictures of the screen.")
                            Text("iCloud sync keeps saved results and gear readings in your private iCloud, on each iPhone signed in to it. Item panel pictures stay on the iPhone that took them.")
                            // The account comes first: without one, no sync event says why.
                            if let problem = iCloudProblem {
                                Text(problem).foregroundStyle(.orange)
                            } else if let state = results.syncState {
                                ICloudSyncLine(state: state)
                                Text("Results sync by themselves. Pull down on the Statistics page to show what has arrived.")
                            }
                        }
                    }
                    .task(id: results.syncsWithICloud) {
                        iCloudStatus = nil
                        guard results.syncsWithICloud else { return }
                        iCloudStatus = try? await CKContainer(identifier: HackResultStore.cloudContainer).accountStatus()
                    }
                    Section {
                        if engine.assistsGlyphs {
                            Toggle("Read gear", isOn: $results.readsGear).disabled(isBusy)
                        }
                        if results.readsGear || !engine.assistsGlyphs {
                            // Pictures live in the session's logs folder.
                            Toggle("Save item panel pictures", isOn: Binding(
                                get: { results.savesGearPictures && engine.sessionDiagnosticsEnabled },
                                set: { results.savesGearPictures = $0 }))
                                .disabled(isBusy || !engine.sessionDiagnosticsEnabled)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reads the item panels after each hack and shows the items here. With “Save logs and screenshots” on in Settings, each reading also goes into the session's logs for your report.")
                            if results.readsGear || !engine.assistsGlyphs {
                                if engine.sessionDiagnosticsEnabled {
                                    Text("Keeps a picture of each item panel, title hidden, so you can check a reading against what the game showed. Deleting the session's logs deletes them.")
                                } else {
                                    Text("Panel pictures need “Save logs and screenshots” in Settings.")
                                }
                            }
                        }
                    }
                }
                if !results.records.isEmpty || !results.drops.isEmpty {
                    Section {
                        Button("Clear results", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .navigationTitle("Result options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .closesForControlStart($confirmingClear)
            .closesForControlStart($confirmingSync)
            .confirmationDialog("Clear all hack results?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear results", role: .destructive) { results.clear() }
            } message: {
                Text(results.syncsWithICloud
                     ? LocalizedStringResource("This removes every saved result from this iPhone, from iCloud, and from your other iPhones that sync with it. It can't be undone.")
                     : LocalizedStringResource("This removes every saved result from this iPhone. It can't be undone."))
            }
        }
    }

    private var iCloudProblem: LocalizedStringResource? {
        switch iCloudStatus {
        case .noAccount:
            return LocalizedStringResource("Sign in to iCloud in Settings to sync. Results are kept on this iPhone meanwhile.")
        case .restricted:
            return LocalizedStringResource("iCloud is restricted on this iPhone, so results aren't syncing.")
        case .temporarilyUnavailable:
            return LocalizedStringResource("iCloud is unavailable right now. Results sync once it's back.")
        case .available, .couldNotDetermine, nil:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// The latest sync, or why it stopped and what to do.
private struct ICloudSyncLine: View {
    let state: ICloudSyncState

    var body: some View {
        switch state {
        case .starting:
            Text("Setting up iCloud sync…")
        case .syncing:
            Text("Syncing with iCloud…")
        case .synced(let date):
            Text("Last synced at \(date.formatted(date: .omitted, time: .shortened)).",
                 comment: "Result options: the time iCloud sync last finished without error.")
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 2) {
                Text(message(problem)).foregroundStyle(.orange)
                if let detail = detail(problem) {
                    // CloudKit's words, left untranslated, like the app's logs.
                    Text(verbatim: detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func message(_ problem: ICloudSyncProblem) -> LocalizedStringResource {
        switch problem {
        case .storageFull:
            return LocalizedStringResource("Your iCloud storage is full, so results aren't syncing. They're kept on this iPhone. Free up space or upgrade in Settings > your name > iCloud; results sync once there's room.")
        case .notSignedIn:
            return LocalizedStringResource("Sign in to iCloud in Settings to sync. Results are kept on this iPhone meanwhile.")
        case .offline:
            return LocalizedStringResource("No internet connection, so results aren't syncing. They sync once you're back online.")
        case .busy(let retryAfter):
            guard let retryAfter, retryAfter > 0 else {
                return LocalizedStringResource("iCloud is busy. Sync tries again shortly.")
            }
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return LocalizedStringResource("iCloud is busy. Sync tries again in about \(minutes) min.",
                                           comment: "Result options: CloudKit asked the app to wait before syncing again.")
        case .rejected(let code, _):
            return LocalizedStringResource("iCloud refused this app's data (CloudKit error \(code)), so results aren't syncing. It needs a fix in the app, not on your iPhone; please report it. Results are kept on this iPhone.",
                                           comment: "Result options: CloudKit rejected the app's records or setup. The placeholder is CloudKit's error code.")
        case .other(let code, _):
            return LocalizedStringResource("iCloud sync failed (CloudKit error \(code)). Results are kept on this iPhone, and sync tries again later.",
                                           comment: "Result options. The placeholder is CloudKit's error code, for a report.")
        }
    }

    /// CloudKit's message, as it sent it, for a report.
    private func detail(_ problem: ICloudSyncProblem) -> String? {
        switch problem {
        case .rejected(_, let detail), .other(_, let detail): return detail
        case .storageFull, .notSignedIn, .offline, .busy: return nil
        }
    }
}

