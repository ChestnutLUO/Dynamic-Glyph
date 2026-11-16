import Foundation
import Testing
import GlyphRecognition

@Suite("Tip facts")
struct TipFactsTests {
    let base = RatingFixtures.base

    func saved(_ count: Int) -> [HackResultRecord] {
        (0..<count).map { RatingFixtures.record($0, at: base.addingTimeInterval(Double($0) * 60)) }
    }

    func facts(_ records: [HackResultRecord], idle: Bool = true, floatingWindow: Bool = true,
               chosen: GameLanguage? = nil, detected: GameLanguage? = nil,
               floatingWindowTipDone: Bool = false, shortcutsTipDone: Bool = false) -> TipFacts {
        TipFacts(saved: records, isIdle: idle, floatingWindowOn: floatingWindow,
                 chosenGameLanguage: chosen, detectedGameLanguage: detected,
                 floatingWindowTipDone: floatingWindowTipDone, shortcutsTipDone: shortcutsTipDone)
    }

    @Test("Start here until the first hack is saved")
    func start() {
        #expect(facts(saved(0)).startEligible)
        #expect(!facts(saved(1)).startEligible)
    }

    @Test("Only finished hacks count")
    func onlyFinished() {
        let open = RatingFixtures.record(9, at: base, summary: RatingFixtures.summary(9, state: .awaiting, closed: false))
        #expect(facts([open]).savedHackCount == 0)
        #expect(facts([open]).startEligible)
    }

    @Test("The floating window tip after one saved hack, with the window switched on")
    func floatingWindow() {
        #expect(!facts(saved(0)).floatingWindowEligible)
        #expect(facts(saved(1)).floatingWindowEligible)
        #expect(!facts(saved(1), floatingWindow: false).floatingWindowEligible)
    }

    @Test("The shortcuts tip after three saved hacks, the appearance tip after five, once their turn has come")
    func counts() {
        func ready(_ count: Int) -> TipFacts {
            facts(saved(count), floatingWindowTipDone: true, shortcutsTipDone: true)
        }
        #expect(!ready(2).shortcutsEligible && ready(3).shortcutsEligible)
        #expect(!ready(4).appearanceEligible && ready(5).appearanceEligible)
        #expect(TipFacts.shortcutsAfter == 3 && TipFacts.appearanceAfter == 5)
    }

    @Test("The shortcuts tip waits until the floating window tip is done")
    func shortcutsAfterFloatingWindow() {
        let waiting = facts(saved(10))
        #expect(waiting.floatingWindowEligible && !waiting.shortcutsTipUnblocked && !waiting.shortcutsEligible)
        let done = facts(saved(10), floatingWindowTipDone: true)
        #expect(done.shortcutsTipUnblocked && done.shortcutsEligible)
    }

    @Test("With the floating window off, the shortcuts tip doesn't wait for a tip that can't come")
    func shortcutsWithoutFloatingWindow() {
        let off = facts(saved(3), floatingWindow: false)
        #expect(!off.floatingWindowEligible)
        #expect(off.shortcutsTipUnblocked && off.shortcutsEligible)
        // The count still applies.
        #expect(!facts(saved(2), floatingWindow: false).shortcutsEligible)
    }

    @Test("The appearance tip waits until the shortcuts tip is done, whatever became of the floating window tip",
          arguments: [true, false])
    func appearanceAfterShortcuts(_ floatingWindowTipDone: Bool) {
        let waiting = facts(saved(10), floatingWindowTipDone: floatingWindowTipDone)
        #expect(!waiting.appearanceTipUnblocked && !waiting.appearanceEligible)
        let done = facts(saved(10), floatingWindowTipDone: floatingWindowTipDone, shortcutsTipDone: true)
        #expect(done.appearanceTipUnblocked && done.appearanceEligible)
        // Off with the window, tip 4 done: tip 5 is free too.
        #expect(facts(saved(5), floatingWindow: false, shortcutsTipDone: true).appearanceEligible)
    }

    @Test("Home's order: tip 2, then 4, then 5; never two of them eligible by order alone")
    func homeOrder() {
        // Ten hacks, nothing done: only tip 2 of the three.
        var state = facts(saved(10))
        #expect(state.floatingWindowEligible && !state.shortcutsEligible && !state.appearanceEligible)
        // Tip 2 done (it then shows no more): tip 4 is next, tip 5 still waits.
        state = facts(saved(10), floatingWindowTipDone: true)
        #expect(state.shortcutsEligible && !state.appearanceEligible)
        // Tip 4 done: tip 5.
        state = facts(saved(10), floatingWindowTipDone: true, shortcutsTipDone: true)
        #expect(state.appearanceEligible)
    }

    @Test("Tips 1 and 3 don't wait for the others")
    func independent() {
        #expect(facts(saved(0)).startEligible)
        let blocked = facts(saved(10))
        #expect(!blocked.shortcutsTipUnblocked && !blocked.appearanceTipUnblocked)
        #expect(blocked.gameLanguageEligible)
        #expect(facts(saved(1), shortcutsTipDone: true).gameLanguageEligible
                == facts(saved(1)).gameLanguageEligible)
    }

    @Test("The game language tip after a hack, on Automatic")
    func gameLanguageAutomatic() {
        #expect(!facts(saved(0)).gameLanguageEligible)
        #expect(facts(saved(1)).gameLanguageEligible)
        #expect(!facts(saved(1), chosen: .english).gameLanguageEligible)
    }

    @Test("The game language tip after a hack read in Chinese or Japanese, even with a language chosen",
          arguments: [GameLanguage.simplifiedChinese, .traditionalChinese, .japanese])
    func gameLanguageDetected(_ language: GameLanguage) {
        let hack = RatingFixtures.record(1, at: base,
                                         summary: RatingFixtures.summary(1, language: language, languageSource: .detected))
        let found = facts([hack], chosen: .english)
        #expect(found.chineseOrJapaneseDetected && found.gameLanguageEligible)
        // Only a language seen in the game counts, not a guess.
        let assumed = RatingFixtures.record(1, at: base,
                                            summary: RatingFixtures.summary(1, language: language, languageSource: .assumed))
        #expect(!facts([assumed], chosen: .english).gameLanguageEligible)
        // Automatic reading's finding counts once a hack is saved.
        #expect(facts(saved(1), chosen: .english, detected: language).gameLanguageEligible)
        #expect(!facts(saved(0), chosen: .english, detected: language).chineseOrJapaneseDetected)
    }

    @Test("English and Korean are not Chinese or Japanese")
    func otherLanguages() {
        #expect(!TipFacts.isChineseOrJapanese(.english))
        #expect(!TipFacts.isChineseOrJapanese(.korean))
        #expect(!facts(saved(1), chosen: .korean, detected: .korean).gameLanguageEligible)
    }

    @Test("No tip while capturing, getting ready or in setup")
    func idle() {
        let busy = facts(saved(0), idle: false)
        #expect(!busy.startEligible)
        let many = facts(saved(10), idle: false, floatingWindowTipDone: true, shortcutsTipDone: true)
        #expect(!many.floatingWindowEligible && !many.gameLanguageEligible
                && !many.shortcutsEligible && !many.appearanceEligible)
    }
}
