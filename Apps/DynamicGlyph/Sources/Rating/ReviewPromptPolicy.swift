import Foundation
import GlyphRecognition

/// When the app may ask iOS to show its rating sheet. Pure: every fact comes
/// in through `Input`, so the rules are tested without a store, a screen or
/// StoreKit. iOS still decides whether its sheet actually appears.
///
/// All of these must hold:
/// - at least `minimumSavedHacks` finished hacks saved, on at least
///   `minimumDistinctDays` different local calendar days;
/// - the latest saved hack is clean: no unrecognized item and no error;
/// - the player is on Home or Statistics, has already seen the latest
///   result there, and nothing else is going on: no capture (preparing,
///   running or stopping), no floating window, no setup cover, no sheet
///   or alert of the app's, and no tip on screen;
/// - this is not the first launch after an update (or install);
/// - not asked in this app version, and at least `minimumDaysBetweenAsks`
///   since the last ask.
enum ReviewPromptPolicy {
    static let minimumSavedHacks = 5
    static let minimumDistinctDays = 3
    static let minimumDaysBetweenAsks = 30

    enum Screen: Equatable { case home, statistics, other }

    struct Input: Equatable {
        /// Finished hacks in the store; this run's unsaved ones don't count.
        var savedHackCount: Int
        /// Distinct local calendar days those hacks were made on.
        var savedHackDays: Int
        /// Whether the newest saved hack is clean (see `isClean`). False
        /// when nothing is saved.
        var latestHackIsClean: Bool
        var screen: Screen
        /// The newest saved result was already on screen before this arrival.
        var hasViewedLatestResult: Bool
        /// Preparing, capturing or stopping: a broadcast is or may be active.
        var isCaptureActive: Bool
        /// Picture in Picture is up or opening.
        var isFloatingWindowUp: Bool
        /// The setup cover, or any sheet, alert or dialog of the app's.
        var isPresentingSomething: Bool
        /// A tip is on the screen the player is looking at.
        var isTipShowing: Bool
        var isFirstLaunchAfterUpdate: Bool
        /// CFBundleShortVersionString of the running app.
        var appVersion: String
        var lastAskedVersion: String?
        var lastAskedDate: Date?
        var now: Date
    }

    static func shouldAsk(_ input: Input) -> Bool {
        reasonsNotToAsk(input).isEmpty
    }

    /// Every rule that fails, for tests and logs. Empty means ask.
    static func reasonsNotToAsk(_ input: Input) -> [Reason] {
        var reasons: [Reason] = []
        if input.savedHackCount < minimumSavedHacks { reasons.append(.tooFewHacks) }
        if input.savedHackDays < minimumDistinctDays { reasons.append(.tooFewDays) }
        if !input.latestHackIsClean { reasons.append(.latestHackNotClean) }
        if input.screen == .other { reasons.append(.wrongScreen) }
        if !input.hasViewedLatestResult { reasons.append(.resultNotViewed) }
        if input.isCaptureActive { reasons.append(.capturing) }
        if input.isFloatingWindowUp { reasons.append(.floatingWindowUp) }
        if input.isPresentingSomething { reasons.append(.presenting) }
        if input.isTipShowing { reasons.append(.tipShowing) }
        if input.isFirstLaunchAfterUpdate { reasons.append(.firstLaunchAfterUpdate) }
        if let version = input.lastAskedVersion, version == input.appVersion { reasons.append(.askedThisVersion) }
        if let last = input.lastAskedDate,
           input.now < last.addingTimeInterval(TimeInterval(minimumDaysBetweenAsks) * 24 * 60 * 60) {
            reasons.append(.askedRecently)
        }
        return reasons
    }

    enum Reason: Equatable {
        case tooFewHacks, tooFewDays, latestHackNotClean, wrongScreen, resultNotViewed, capturing,
             floatingWindowUp, presenting, tipShowing, firstLaunchAfterUpdate, askedThisVersion, askedRecently
    }

    // MARK: - Facts from the saved hacks

    /// Saved hacks that finished. A record in a format this build can't
    /// read is saved and closed, so it counts.
    static func finishedHacks(_ saved: [HackResultRecord]) -> [HackResultRecord] {
        saved.filter { $0.summary?.isClosed ?? true }
    }

    /// Different local calendar days among `records`.
    static func distinctDays(_ records: [HackResultRecord], calendar: Calendar = .current) -> Int {
        Set(records.map { calendar.startOfDay(for: $0.date) }).count
    }

    /// A hack with nothing for the player to frown at, as its card shows it:
    /// read in full (the green seal, not partial or unseen), no slot where
    /// the input check and the game disagreed, and, when gear was read, no
    /// Unrecognized item, no partly read panel and no gear that failed to be
    /// read. A record this build can't show is not clean.
    static func isClean(_ record: HackResultRecord) -> Bool {
        guard let summary = record.summary, summary.isClosed, summary.state == .complete else { return false }
        if summary.slots.contains(where: { $0.comparison == .disagreement }) { return false }
        if record.gearUnreadable { return false }
        switch record.gear?.reading {
        case nil:
            return true
        case .notRead?:
            return false
        case .read(let drop)?:
            return drop.panels.allSatisfy { panel in
                !panel.partial && panel.entries.allSatisfy { $0.item != nil }
            }
        }
    }

    /// Whether a launch of `current` is the first since an update: the last
    /// launched version differs, or none was recorded (a fresh install, or
    /// the first launch of the build that started recording it).
    static func isFirstLaunchAfterUpdate(lastLaunchedVersion: String?, current: String) -> Bool {
        lastLaunchedVersion != current
    }
}

/// This launch's one fact the prompt can't read later: whether it is the
/// first since an update. Set once, as the app starts.
@MainActor
enum ReviewPromptSession {
    static var isFirstLaunchAfterUpdate = true
}

/// The review prompt's memory, on this iPhone only: which version last
/// asked and when, and which version last launched. Nothing leaves the
/// device.
struct ReviewPromptRecord {
    static let lastAskedVersionKey = "review.lastAskedVersion"
    static let lastAskedDateKey = "review.lastAskedDate"
    static let lastLaunchedVersionKey = "review.lastLaunchedVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastAskedVersion: String? { defaults.string(forKey: Self.lastAskedVersionKey) }
    var lastAskedDate: Date? { defaults.object(forKey: Self.lastAskedDateKey) as? Date }

    func recordAsk(version: String, at date: Date) {
        defaults.set(version, forKey: Self.lastAskedVersionKey)
        defaults.set(date, forKey: Self.lastAskedDateKey)
    }

    /// Called once per launch: whether this launch is the first of
    /// `current`, and remembers `current` for the next one.
    func registerLaunch(version current: String) -> Bool {
        let previous = defaults.string(forKey: Self.lastLaunchedVersionKey)
        // Written only when it changes: a launch of the same version stores nothing.
        if previous != current { defaults.set(current, forKey: Self.lastLaunchedVersionKey) }
        return ReviewPromptPolicy.isFirstLaunchAfterUpdate(lastLaunchedVersion: previous, current: current)
    }

    /// CFBundleShortVersionString, such as "1.2".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
