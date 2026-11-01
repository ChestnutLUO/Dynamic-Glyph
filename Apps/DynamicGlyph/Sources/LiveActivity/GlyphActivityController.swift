import ActivityKit
import Foundation
import GlyphRecognition
import GlyphRecognitionImages

/// Runs the Live Activity alongside Picture in Picture.
///
/// The two are independent display choices: if the Island lags behind a
/// presentation, Picture in Picture is still the usable surface and this one
/// can simply be turned off. Nothing here is allowed to disturb capture — every
/// failure is logged and swallowed.
@MainActor
final class GlyphActivityController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Live Activity off"
    // Diagnostics counters. Deliberately not published: each change would
    // rebuild every screen observing the engine, for numbers only the
    // Diagnostics page reads, and it is refreshed by other updates anyway.
    private(set) var updatesSent = 0
    private(set) var updatesCoalesced = 0
    /// Of `updatesSent`: those whose `semanticKey` differed from the last
    /// content sent, and those sent only to renew the stale date with the
    /// same key. The two add up to `updatesSent`.
    private(set) var updatesChangedKey = 0
    private(set) var updatesRenewalOnly = 0
    /// Of `updatesSent`: those that changed what the compact or minimal
    /// Island draws (`compactKey`), whichever of the two above they were.
    private(set) var updatesChangedCompact = 0
    /// Uptime of the last update request and of its completion, so the cost of
    /// an update can be measured rather than assumed.
    private(set) var lastUpdateMilliseconds = 0.0

    var onEvent: ((String) -> Void)?
    /// Sent with every state; see `GlyphActivityContentState.animatesUpdates`.
    var animatesUpdates = false

    private var activity: Activity<GlyphActivityAttributes>?
    private var schedule = ActivityUpdateSchedule<GlyphActivityAttributes.ContentState>()
    private var flushTask: Task<Void, Never>?
    /// Keys of the content last handed to the system, for the counters above.
    private var lastSentKey: String?
    private var lastSentCompactKey: String?
    /// How long a "draw this now" claim stays good if our updates stop
    /// arriving. Long enough to cover the throttle and a slow system update,
    /// short enough that it cannot outlive the slot it refers to by much.

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Ends anything left over from a previous launch. An activity still on the
    /// Lock Screen after a crash would imply capture is running when it is not.
    func reconcileLeftovers() {
        let leftovers = Activity<GlyphActivityAttributes>.activities
        guard !leftovers.isEmpty else { return }
        log("ending \(leftovers.count) leftover activities from a previous launch")
        for stale in leftovers {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(with snapshot: GlyphDisplaySnapshot, table: GlyphTable?) {
        guard activity == nil else { return }
        guard areActivitiesEnabled else {
            status = "Live Activities are turned off for this app"
            log("activities disabled")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var state = GlyphActivityAttributes.ContentState(snapshot, table: table, atUptime: now)
        state.animatesUpdates = animatesUpdates
        let expiry = state.freshnessLifetime.map { snapshot.evidenceArrivalUptime + $0 }
        do {
            activity = try Activity.request(
                attributes: GlyphActivityAttributes(captureSessionID: snapshot.captureSessionID.rawValue),
                content: ActivityContent(state: state, staleDate: expiry.map {
                    Date().addingTimeInterval($0 - now)
                }))
            schedule = ActivityUpdateSchedule()
            schedule.didSend(key: state.semanticKey, at: now)
            lastSentKey = state.semanticKey
            lastSentCompactKey = state.compactKey
            isRunning = true
            status = "Live Activity running"
            log("started")
        } catch {
            // An unsupported device or a refused request must not stop capture.
            status = "Live Activity could not start: \(error.localizedDescription)"
            log("start failed: \(error)")
        }
    }

    func update(_ snapshot: GlyphDisplaySnapshot, table: GlyphTable?) {
        guard activity != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var state = GlyphActivityAttributes.ContentState(snapshot, table: table, atUptime: now)
        state.animatesUpdates = animatesUpdates
        let expiry = state.freshnessLifetime.map { snapshot.evidenceArrivalUptime + $0 }
        let pace: ActivityUpdateSchedule<GlyphActivityAttributes.ContentState>.Pace =
            snapshot.state == .input ? .input : state.gear?.state == .watching ? .watching : .standard
        guard let delay = schedule.offer(state, key: state.semanticKey, freshUntil: expiry, at: now,
                                         pace: pace) else {
            flushTask?.cancel()
            flushTask = nil
            return
        }
        if delay > 0 {
            updatesCoalesced += 1
            schedulePendingFlush(after: delay)
            return
        }
        flush(at: now)
    }

    /// Sends the pending state if it is due. While an update is still with the
    /// system this does nothing; its completion sends the newest state then.
    private func flush(at now: Double) {
        guard let activity, let update = schedule.take(at: now) else { return }
        flushTask?.cancel()
        flushTask = nil
        updatesSent += 1
        if update.key == lastSentKey { updatesRenewalOnly += 1 } else { updatesChangedKey += 1 }
        let compactKey = update.content.compactKey
        if compactKey != lastSentCompactKey { updatesChangedCompact += 1 }
        lastSentKey = update.key
        lastSentCompactKey = compactKey
        let staleDate = update.freshUntil.map { Date().addingTimeInterval($0 - now) }
        let activityID = activity.id
        Task {
            await activity.update(ActivityContent(state: update.content, staleDate: staleDate))
            await MainActor.run { self.updateFinished(activityID: activityID, sentAt: now) }
        }
    }

    private func updateFinished(activityID: String, sentAt: Double) {
        guard activity?.id == activityID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastUpdateMilliseconds = (now - sentAt) * 1000
        schedule.sendFinished()
        guard let delay = schedule.delayUntilDue(at: now) else { return }
        if delay > 0 { schedulePendingFlush(after: delay) } else { flush(at: now) }
    }

    /// Sends whatever the newest held state is once the throttle window has
    /// passed. One timer at a time; a newer state simply replaces the old one.
    private func schedulePendingFlush(after delay: Double) {
        guard flushTask == nil, let activityID = activity?.id else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, delay))) }
            catch { return }
            guard !Task.isCancelled, let self, self.activity?.id == activityID else { return }
            self.flushTask = nil
            self.flush(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        isRunning = false
        schedule = ActivityUpdateSchedule()
        lastSentKey = nil
        lastSentCompactKey = nil
        flushTask?.cancel()
        flushTask = nil
        status = "Live Activity off"
        log("ending")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func log(_ message: String) {
        onEvent?("activity: \(message)")
    }
}

extension GlyphActivityAttributes.ContentState {
    /// The one place a tile becomes a payload slot, so the row and the guidance
    /// window cannot end up describing the same slot differently.
    static func slot(_ style: TileStyle, table: GlyphTable?) -> Slot {
        switch style {
        case .confirmed(let id):
            return Slot(provenance: .observed, name: id.name, shape: table?.path(for: id)?.encoded)
        case .observing(let id):
            return Slot(provenance: .observing, name: id.name, shape: table?.path(for: id)?.encoded)
        case .inferred(let id):
            return Slot(provenance: .uncertain, name: id.name, shape: table?.path(for: id)?.encoded)
        case .predicted(let id):
            return Slot(provenance: .predicted, name: id.name, shape: table?.path(for: id)?.encoded)
        case .alternatives(let count):
            return Slot(provenance: .predicted,
                        name: String(localized: "\(count) options",
                                     comment: "Island slot caption: this many Glyphs could still fill the slot."),
                        shape: nil)
        case .uncertain: return Slot(provenance: .uncertain, name: nil, shape: nil)
        case .missing: return Slot(provenance: .missing, name: nil, shape: nil)
        case .pending: return Slot(provenance: .pending, name: nil, shape: nil)
        }
    }

    /// Built from the same snapshot and the same tile mapping every other
    /// surface uses, so the Island cannot show a different reading of the model.
    init(_ snapshot: GlyphDisplaySnapshot, table: GlyphTable?,
         atUptime now: Double = ProcessInfo.processInfo.systemUptime) {
        let slots = snapshot.tileStyles.enumerated().map { index, style in
            var slot = Self.slot(style, table: table)
            slot.inputCheck = snapshot.inputCheckDisplay(for: index, atUptime: now)
            return slot
        }
        let guidance = snapshot.isStale(atUptime: now, threshold: 1.5) ? nil : snapshot.upcomingGuidance()
        var provisional = false
        if case .provisionalOnly = snapshot.acceptance { provisional = true }
        self.init(slots: slots, phase: snapshot.state.rawValue,
                  statusLine: snapshot.statusLine(atUptime: now),
                  predictionState: snapshot.outlook.state.rawValue,
                  candidateCount: snapshot.outlook.candidateCount,
                  expectedSlotCount: snapshot.expectedSlotCount,
                  upcoming: guidance?.styles.map { Self.slot($0, table: table) } ?? [],
                  inputSlotNumber: guidance.map { $0.firstSlotIndex + 1 },
                  indicatorsObstructed: snapshot.indicatorsObstructed,
                  statusTone: (snapshot.visibleGear(atUptime: now)?.tone ?? snapshot.displayStatus(atUptime: now).tone).rawValue,
                  hackID: snapshot.hackID, revision: snapshot.revision,
                  isProvisional: provisional)
        gear = snapshot.visibleGear(atUptime: now)
    }
}
