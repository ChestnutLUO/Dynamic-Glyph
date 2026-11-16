import Foundation

/// The five tips, by what the app does to them.
enum AppTip: String, CaseIterable, Hashable {
    case start, floatingWindow, gameLanguage, shortcuts, appearance
}

/// What the app writes into TipKit: the tips' parameters (`AppTips`) and
/// "done" for a tip. The app goes through this, never TipKit directly, so
/// tests can count the writes (`AppTips.update`, `AppTips.retire`).
///
/// Every write is a save of TipKit's Core Data datastore, and every save
/// posts `NSPersistentStoreRemoteChange` to the whole process. When
/// `HackResults` reloaded the saved hacks on every such post, the reload
/// brought the app back to `AppTips.update`, and the update wrote again: a
/// loop. So the list reloads only for its own store, and the app writes only what differs
/// from what is there.
@MainActor
protocol TipDatastore: AnyObject {
    var savedHackCount: Int { get set }
    var isIdle: Bool { get set }
    var floatingWindowOn: Bool { get set }
    var gameLanguageRelevant: Bool { get set }
    var shortcutsTipUnblocked: Bool { get set }
    var appearanceTipUnblocked: Bool { get set }

    /// Already done for good: closed, shown its one time, or its action taken.
    func isInvalidated(_ tip: AppTip) -> Bool
    /// Marks the tip's action taken.
    func invalidate(_ tip: AppTip)
}

extension TipDatastore {
    /// Copies the facts into the parameters, writing only what changed, and
    /// retires Start here once a hack is saved.
    func apply(_ facts: TipFacts) {
        if savedHackCount != facts.savedHackCount { savedHackCount = facts.savedHackCount }
        if isIdle != facts.isIdle { isIdle = facts.isIdle }
        if floatingWindowOn != facts.floatingWindowOn { floatingWindowOn = facts.floatingWindowOn }
        if gameLanguageRelevant != facts.gameLanguageRelevant { gameLanguageRelevant = facts.gameLanguageRelevant }
        if shortcutsTipUnblocked != facts.shortcutsTipUnblocked { shortcutsTipUnblocked = facts.shortcutsTipUnblocked }
        if appearanceTipUnblocked != facts.appearanceTipUnblocked {
            appearanceTipUnblocked = facts.appearanceTipUnblocked
        }
        if facts.savedHackCount > 0 { retire(.start) }
    }

    /// The tip's action is taken: invalidates it, unless it is already done.
    func retire(_ tip: AppTip) {
        guard !isInvalidated(tip) else { return }
        invalidate(tip)
    }
}
