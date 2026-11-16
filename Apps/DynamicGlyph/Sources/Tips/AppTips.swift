import SwiftUI
import TipKit

/// The five one-time tips (design spec §0–1). Local only: TipKit keeps its
/// datastore in the app's own container, and nothing is synced.
///
/// Each tip shows at most once (`MaxDisplayCount(1)`), is gone once closed,
/// and with `.displayFrequency(.daily)` the app shows at most one new tip a
/// day. The rules read `AppTips`' parameters, which the app sets from the
/// saved hacks (`TipFacts`); none shows while capturing, preparing or in
/// setup (`isIdle`).
enum AppTips {
    @Parameter static var savedHackCount: Int = 0
    @Parameter static var isIdle: Bool = true
    @Parameter static var floatingWindowOn: Bool = true
    /// Game language on Automatic, or the game found in Chinese or Japanese.
    @Parameter static var gameLanguageRelevant: Bool = true
    /// Tip 2 done, or the Floating window off (`TipFacts.shortcutsTipUnblocked`).
    @Parameter static var shortcutsTipUnblocked: Bool = false
    /// Tip 4 done (`TipFacts.appearanceTipUnblocked`).
    @Parameter static var appearanceTipUnblocked: Bool = false

    /// Debug builds only, for screenshots, as launch arguments or from the
    /// Simulator's Settings section (`ScreenshotDemoSection`):
    /// `-DGShowAllTips YES` shows every tip whatever its rules; `-DGShowTip
    /// <id>` shows just the tip with that id; `-DGResetTips YES` starts from
    /// an empty tips datastore. Capture, preparing and setup still hide them.
    static let showAllKey = "DGShowAllTips"
    static let showOneKey = "DGShowTip"
    static let resetKey = "DGResetTips"
    static let testingIDs = [StartTip().id, FloatingWindowTip().id, GameLanguageTip().id, ShortcutsTip().id,
                             AppearanceTip().id]

    /// At launch, before any view.
    @MainActor
    static func configure() {
        #if DEBUG
        let options = UserDefaults.standard
        if options.bool(forKey: resetKey) {
            try? Tips.resetDatastore()
            options.removeObject(forKey: LiveTipDatastore.retiredKey)
        }
        var forcedID: String?
        if options.bool(forKey: showAllKey) {
            Tips.showAllTipsForTesting()
        } else if let id = options.string(forKey: showOneKey) {
            let types: [any Tip.Type] = [StartTip.self, FloatingWindowTip.self, GameLanguageTip.self,
                                         ShortcutsTip.self, AppearanceTip.self]
            if let index = testingIDs.firstIndex(of: id) {
                Tips.showTipsForTesting([types[index]])
                forcedID = id
            }
        }
        #endif
        try? Tips.configure([.displayFrequency(.daily), .datastoreLocation(.applicationDefault)])
        #if DEBUG
        // Testing mode lifts the daily limit, so tips eligible by their rules
        // would show beside the forced one. Close them for this datastore;
        // "Reset tips at launch" brings them back.
        if let forcedID { closeAll(except: forcedID) }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func closeAll(except id: String) {
        let tips: [any Tip] = [StartTip(), FloatingWindowTip(), GameLanguageTip(), ShortcutsTip(), AppearanceTip()]
        // Already closed ones stay as they are: each write is a datastore save.
        for tip in tips where tip.id != id && !isDone(tip.status) { tip.invalidate(reason: .tipClosed) }
    }
    #endif

    /// Whether a tip is done for good: closed, shown its one time
    /// (`MaxDisplayCount`), or its action taken.
    static func isDone(_ status: Tips.Status) -> Bool {
        if case .invalidated = status { return true }
        return false
    }

    /// Copies the facts into the parameters, writing only what changed, and
    /// retires Start here once a hack is saved. Runs on every change of the
    /// saved hacks, so with nothing new it writes nothing (`TipDatastore`).
    @MainActor
    static func update(_ facts: TipFacts, in datastore: (any TipDatastore)? = nil) {
        // Not a default argument: those are evaluated off the main actor.
        (datastore ?? LiveTipDatastore.shared).apply(facts)
    }

    /// The tip's suggestion was followed. Nothing is written for a tip that
    /// is already done.
    @MainActor
    static func retire(_ tip: AppTip, in datastore: (any TipDatastore)? = nil) {
        (datastore ?? LiveTipDatastore.shared).retire(tip)
    }
}

/// TipKit's own datastore, through `AppTips`' parameters and the tips.
@MainActor
final class LiveTipDatastore: TipDatastore {
    static let shared = LiveTipDatastore()

    /// Tips the app has retired, kept beside TipKit's own record: early in
    /// a launch a tip's `status` is still `.pending`, even for one
    /// invalidated long ago, so it alone would retire Start here again at
    /// every launch. It also holds in the Debug "show tips" testing modes,
    /// where `status` doesn't say invalidated.
    static let retiredKey = "tips.retired"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var retired: Set<AppTip> {
        Set((defaults.stringArray(forKey: Self.retiredKey) ?? []).compactMap(AppTip.init(rawValue:)))
    }

    var savedHackCount: Int {
        get { AppTips.savedHackCount }
        set { AppTips.savedHackCount = newValue }
    }
    var isIdle: Bool {
        get { AppTips.isIdle }
        set { AppTips.isIdle = newValue }
    }
    var floatingWindowOn: Bool {
        get { AppTips.floatingWindowOn }
        set { AppTips.floatingWindowOn = newValue }
    }
    var gameLanguageRelevant: Bool {
        get { AppTips.gameLanguageRelevant }
        set { AppTips.gameLanguageRelevant = newValue }
    }
    var shortcutsTipUnblocked: Bool {
        get { AppTips.shortcutsTipUnblocked }
        set { AppTips.shortcutsTipUnblocked = newValue }
    }
    var appearanceTipUnblocked: Bool {
        get { AppTips.appearanceTipUnblocked }
        set { AppTips.appearanceTipUnblocked = newValue }
    }

    func isInvalidated(_ tip: AppTip) -> Bool {
        retired.contains(tip) || AppTips.isDone(Self.tip(tip).status)
    }

    func invalidate(_ tip: AppTip) {
        let retired = retired
        if !retired.contains(tip) {
            defaults.set(retired.union([tip]).map(\.rawValue).sorted(), forKey: Self.retiredKey)
        }
        Self.tip(tip).invalidate(reason: .actionPerformed)
    }

    static func tip(_ tip: AppTip) -> any Tip {
        switch tip {
        case .start: StartTip()
        case .floatingWindow: FloatingWindowTip()
        case .gameLanguage: GameLanguageTip()
        case .shortcuts: ShortcutsTip()
        case .appearance: AppearanceTip()
        }
    }
}

/// Tip 1: Home, above Start, until the first hack is saved.
struct StartTip: Tip {
    var id: String { "home.start" }
    var title: Text { Text("Start here", comment: "Tip on Home, above the Start button. Title.") }
    var message: Text? {
        Text("Tap Start and share your screen, then open a Glyph hack in the game.",
             comment: "Tip on Home, above the Start button.")
    }
    var image: Image? { Image(systemName: "hand.tap") }
    var rules: [Rule] {
        #Rule(AppTips.$isIdle) { $0 == true }
        #Rule(AppTips.$savedHackCount) { $0 == 0 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

/// Tip 2: Home, above the display choices, once a hack is saved and the
/// floating window is on.
struct FloatingWindowTip: Tip {
    var id: String { "home.floatingWindow" }
    var title: Text { Text("Move the floating window", comment: "Tip on Home, above the Floating window switch. Title.") }
    var message: Text? {
        Text("Drag it away from the game's slot row and item panels so they can be read. Pinch to resize it.",
             comment: "Tip on Home, above the Floating window switch.")
    }
    var image: Image? { Image(systemName: "pip") }
    var rules: [Rule] {
        #Rule(AppTips.$isIdle) { $0 == true }
        #Rule(AppTips.$floatingWindowOn) { $0 == true }
        #Rule(AppTips.$savedHackCount) { $0 >= 1 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

/// Tip 3: Statistics, above the items, after a hack, while the game
/// language is Automatic or the game was found in Chinese or Japanese.
struct GameLanguageTip: Tip {
    var id: String { "statistics.gameLanguage" }
    var title: Text { Text("Item names in your game language", comment: "Tip on Statistics, above the items. Title.") }
    var message: Text? {
        Text("Item names follow the language your game is in. Change it in Settings › Game language.",
             comment: "Tip on Statistics, above the items. Keep the Settings path as the app names it.")
    }
    var image: Image? { Image(systemName: "character.bubble") }
    var rules: [Rule] {
        #Rule(AppTips.$isIdle) { $0 == true }
        #Rule(AppTips.$savedHackCount) { $0 >= 1 }
        #Rule(AppTips.$gameLanguageRelevant) { $0 == true }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

/// Tip 4: Home, under Start, after three saved hacks, once tip 2 is done
/// or the Floating window is off.
struct ShortcutsTip: Tip {
    var id: String { "home.shortcuts" }
    var title: Text { Text("Start without opening the app", comment: "Tip on Home, under the Start button. Title.") }
    var message: Text? {
        Text("Start and stop from Control Center or Shortcuts, and see your Statistics in a Home Screen widget.",
             comment: "Tip on Home, under the Start button.")
    }
    var image: Image? { Image(systemName: "switch.2") }
    var rules: [Rule] {
        #Rule(AppTips.$isIdle) { $0 == true }
        #Rule(AppTips.$savedHackCount) { $0 >= 3 }
        #Rule(AppTips.$shortcutsTipUnblocked) { $0 == true }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

/// Tip 5: Home, in tip 4's place, after five saved hacks, once tip 4 is
/// done.
struct AppearanceTip: Tip {
    var id: String { "home.appearance" }
    var title: Text { Text("Themes and app icons", comment: "Tip on Home, under the Start button. Title.") }
    var message: Text? {
        Text("Pick a color theme and an app icon in Settings › Appearance. They're all free.",
             comment: "Tip on Home, under the Start button. Keep the Settings path as the app names it.")
    }
    var image: Image? { Image(systemName: "paintpalette") }
    var rules: [Rule] {
        #Rule(AppTips.$isIdle) { $0 == true }
        #Rule(AppTips.$savedHackCount) { $0 >= 5 }
        #Rule(AppTips.$appearanceTipUnblocked) { $0 == true }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}
