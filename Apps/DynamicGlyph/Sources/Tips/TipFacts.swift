import Foundation
import GlyphRecognition

/// What the in-app tips' rules read, worked out from the same saved-hack
/// facts as the review prompt. Pure, so it is tested without TipKit; the
/// app copies it into the tips' parameters (`AppTips.update`).
struct TipFacts: Equatable {
    /// Finished hacks saved on this iPhone (or synced to it).
    var savedHackCount = 0
    /// Not capturing, preparing or stopping, and the setup cover is down.
    var isIdle = true
    /// The Floating window switch on Home.
    var floatingWindowOn = true
    /// Game language is set to Automatic in Settings.
    var gameLanguageAutomatic = true
    /// A saved hack, or automatic reading, found the game in Chinese or
    /// Japanese.
    var chineseOrJapaneseDetected = false
    /// Tip 2 (Move the floating window) is done: closed, shown its one
    /// time, or its action taken. TipKit's status, read by the app.
    var floatingWindowTipDone = false
    /// Tip 4 (Start without opening the app) is done, the same way.
    var shortcutsTipDone = false

    /// Thresholds of the tips' rules, as the product plan sets them. The
    /// rules themselves repeat these numbers: TipKit's `#Rule` takes literals.
    static let floatingWindowAfter = 1
    static let gameLanguageAfter = 1
    static let shortcutsAfter = 3
    static let appearanceAfter = 5

    init(savedHackCount: Int = 0, isIdle: Bool = true, floatingWindowOn: Bool = true,
         gameLanguageAutomatic: Bool = true, chineseOrJapaneseDetected: Bool = false,
         floatingWindowTipDone: Bool = false, shortcutsTipDone: Bool = false) {
        self.savedHackCount = savedHackCount
        self.isIdle = isIdle
        self.floatingWindowOn = floatingWindowOn
        self.gameLanguageAutomatic = gameLanguageAutomatic
        self.chineseOrJapaneseDetected = chineseOrJapaneseDetected
        self.floatingWindowTipDone = floatingWindowTipDone
        self.shortcutsTipDone = shortcutsTipDone
    }

    init(saved: [HackResultRecord], isIdle: Bool, floatingWindowOn: Bool,
         chosenGameLanguage: GameLanguage?, detectedGameLanguage: GameLanguage?,
         floatingWindowTipDone: Bool = false, shortcutsTipDone: Bool = false) {
        let finished = ReviewPromptPolicy.finishedHacks(saved)
        let detectedInHack = finished.contains { record in
            guard let origin = record.summary?.origin, origin.gameLanguageSource == .detected,
                  let language = origin.gameLanguage else { return false }
            return Self.isChineseOrJapanese(language)
        }
        self.init(savedHackCount: finished.count, isIdle: isIdle, floatingWindowOn: floatingWindowOn,
                  gameLanguageAutomatic: chosenGameLanguage == nil,
                  chineseOrJapaneseDetected: detectedInHack
                      || (!finished.isEmpty && detectedGameLanguage.map(Self.isChineseOrJapanese) == true),
                  floatingWindowTipDone: floatingWindowTipDone, shortcutsTipDone: shortcutsTipDone)
    }

    static func isChineseOrJapanese(_ language: GameLanguage) -> Bool {
        language == .simplifiedChinese || language == .traditionalChinese || language == .japanese
    }

    /// Tip 3's language condition, one parameter for TipKit: rules in a
    /// tip are all required, and a rule reads one parameter.
    var gameLanguageRelevant: Bool { chineseOrJapaneseDetected || gameLanguageAutomatic }

    /// Home's order, by rules rather than a group: tip 4 waits for tip 2 to
    /// be done, unless the Floating window switch is off (then tip 2 can't
    /// come). One parameter for TipKit, like `gameLanguageRelevant`.
    var shortcutsTipUnblocked: Bool { floatingWindowTipDone || !floatingWindowOn }
    /// Tip 5 waits for tip 4 to be done. Tips 1 and 3 wait for nothing.
    var appearanceTipUnblocked: Bool { shortcutsTipDone }

    // MARK: - The rules, as plain logic

    /// Mirrors each tip's `rules`, for tests and for the review prompt's
    /// "is a tip showing" check. TipKit adds its own limits on top: one tip
    /// a day across the app, each shown once, and gone once closed.
    var startEligible: Bool { isIdle && savedHackCount == 0 }
    var floatingWindowEligible: Bool { isIdle && floatingWindowOn && savedHackCount >= Self.floatingWindowAfter }
    var gameLanguageEligible: Bool {
        isIdle && savedHackCount >= Self.gameLanguageAfter && gameLanguageRelevant
    }
    var shortcutsEligible: Bool { isIdle && savedHackCount >= Self.shortcutsAfter && shortcutsTipUnblocked }
    var appearanceEligible: Bool { isIdle && savedHackCount >= Self.appearanceAfter && appearanceTipUnblocked }
}
