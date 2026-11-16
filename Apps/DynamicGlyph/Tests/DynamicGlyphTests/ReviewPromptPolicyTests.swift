import Foundation
import Testing
import GlyphRecognition

/// Builders shared by the review prompt and tip facts tests.
enum RatingFixtures {
    /// Noon on 2026-11-02 in the test calendar's zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()
    static let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!

    static func summary(_ hack: Int, state: HackResult.State = .complete, closed: Bool = true,
                        comparison: ValidatorResultComparison.Status = .agreement,
                        language: GameLanguage? = nil,
                        languageSource: CaptureOrigin.LanguageSource? = nil) -> HackResultSummary {
        var summary = HackResultSummary(captureSessionID: 1, hackID: hack, state: state, isClosed: closed,
                                        closeReason: closed ? "panelLeft" : nil,
                                        hackingBonus: .init(percent: 120, isFinal: true),
                                        speedBonus: .init(percent: 20, isFinal: true),
                                        slots: [.init(glyph: "help", outcome: .accepted, check: .matched,
                                                      comparison: comparison)])
        if language != nil || languageSource != nil {
            summary.origin = CaptureOrigin(appVersion: "1.2", appBuild: "0", captureMode: .glyphAssistance,
                                           gameLanguage: language, gameLanguageSource: languageSource,
                                           utcOffsetMinutes: 540)
        }
        return summary
    }

    static func record(_ hack: Int, at date: Date, summary: HackResultSummary? = nil) -> HackResultRecord {
        HackResultRecord(id: "launch/1/\(hack)", date: date, summary: summary ?? self.summary(hack))
    }

    /// One read item panel.
    static func gear(_ hack: Int, items: [String?], partial: Bool = false) -> HackGearAttachment {
        let entries = items.enumerated().map { index, item in
            GearDropEntry(column: index % 2, row: index / 2, item: item, levelState: .known, level: 8, quantity: 1)
        }
        let group = GearDropSummary(groupID: hack, startedAt: 0, closedAt: 1, closeReason: "panelLeft",
                                    hackID: hack, association: .ordered,
                                    panels: [.init(stage: .portal, entries: entries, partial: partial)])
        return HackGearAttachment(captureSessionID: 1, hackID: hack, reading: .read(group))
    }
}

@Suite("Review prompt policy")
struct ReviewPromptPolicyTests {
    typealias Policy = ReviewPromptPolicy

    /// Every condition met: the prompt may ask.
    static let ready = Policy.Input(
        savedHackCount: 5, savedHackDays: 3, latestHackIsClean: true, screen: .home,
        hasViewedLatestResult: true, isCaptureActive: false, isFloatingWindowUp: false,
        isPresentingSomething: false, isTipShowing: false, isFirstLaunchAfterUpdate: false,
        appVersion: "1.2", lastAskedVersion: nil, lastAskedDate: nil, now: RatingFixtures.base)

    @Test("With every condition met it asks, on Home and on Statistics")
    func asks() {
        #expect(Policy.shouldAsk(Self.ready))
        var statistics = Self.ready
        statistics.screen = .statistics
        #expect(Policy.shouldAsk(statistics))
        #expect(Policy.reasonsNotToAsk(Self.ready).isEmpty)
    }

    @Test("The thresholds are the plan's: 5 hacks, 3 days, 30 days apart")
    func thresholds() {
        #expect(Policy.minimumSavedHacks == 5)
        #expect(Policy.minimumDistinctDays == 3)
        #expect(Policy.minimumDaysBetweenAsks == 30)
    }

    @Test("Four saved hacks are not enough; five are", arguments: [(0, false), (4, false), (5, true), (40, true)])
    func hackCount(_ count: Int, _ asks: Bool) {
        var input = Self.ready
        input.savedHackCount = count
        #expect(Policy.shouldAsk(input) == asks)
        #expect(Policy.reasonsNotToAsk(input).contains(.tooFewHacks) == !asks)
    }

    @Test("Hacks on two days are not enough; three are", arguments: [(1, false), (2, false), (3, true), (9, true)])
    func dayCount(_ days: Int, _ asks: Bool) {
        var input = Self.ready
        input.savedHackDays = days
        #expect(Policy.shouldAsk(input) == asks)
    }

    @Test("Each moment that isn't calm holds it back, alone", arguments: [
        \Policy.Input.isCaptureActive, \.isFloatingWindowUp, \.isPresentingSomething, \.isTipShowing,
        \.isFirstLaunchAfterUpdate,
    ])
    func busyMoments(_ flag: WritableKeyPath<Policy.Input, Bool>) {
        var input = Self.ready
        input[keyPath: flag] = true
        #expect(!Policy.shouldAsk(input))
        #expect(Policy.reasonsNotToAsk(input).count == 1)
    }

    @Test("A latest hack that isn't clean, or a result not yet seen, holds it back")
    func latestHack() {
        var unclean = Self.ready
        unclean.latestHackIsClean = false
        #expect(Policy.reasonsNotToAsk(unclean) == [.latestHackNotClean])
        var unseen = Self.ready
        unseen.hasViewedLatestResult = false
        #expect(Policy.reasonsNotToAsk(unseen) == [.resultNotViewed])
    }

    @Test("Never from Settings or anywhere but Home and Statistics")
    func screens() {
        var input = Self.ready
        input.screen = .other
        #expect(Policy.reasonsNotToAsk(input) == [.wrongScreen])
    }

    @Test("Once per app version")
    func oncePerVersion() {
        var input = Self.ready
        input.lastAskedVersion = "1.2"
        input.lastAskedDate = RatingFixtures.base.addingTimeInterval(-400 * 86_400)
        #expect(Policy.reasonsNotToAsk(input) == [.askedThisVersion])
        input.lastAskedVersion = "1.1"
        #expect(Policy.shouldAsk(input))
    }

    @Test("At least 30 days since the last ask, even in a new version")
    func thirtyDays() {
        var input = Self.ready
        input.lastAskedVersion = "1.1"
        input.lastAskedDate = RatingFixtures.base.addingTimeInterval(-29 * 86_400)
        #expect(Policy.reasonsNotToAsk(input) == [.askedRecently])
        input.lastAskedDate = RatingFixtures.base.addingTimeInterval(-30 * 86_400 + 1)
        #expect(!Policy.shouldAsk(input))
        input.lastAskedDate = RatingFixtures.base.addingTimeInterval(-30 * 86_400)
        #expect(Policy.shouldAsk(input))
    }

    @Test("Every failing rule is reported")
    func allReasons() {
        let input = Policy.Input(
            savedHackCount: 0, savedHackDays: 0, latestHackIsClean: false, screen: .other,
            hasViewedLatestResult: false, isCaptureActive: true, isFloatingWindowUp: true,
            isPresentingSomething: true, isTipShowing: true, isFirstLaunchAfterUpdate: true,
            appVersion: "1.2", lastAskedVersion: "1.2", lastAskedDate: RatingFixtures.base, now: RatingFixtures.base)
        #expect(Policy.reasonsNotToAsk(input) == [
            .tooFewHacks, .tooFewDays, .latestHackNotClean, .wrongScreen, .resultNotViewed, .capturing,
            .floatingWindowUp, .presenting, .tipShowing, .firstLaunchAfterUpdate, .askedThisVersion, .askedRecently,
        ])
    }

    // MARK: - Facts from saved hacks

    @Test("Days are counted on the local calendar: late evening and early morning are two days")
    func distinctDays() {
        let calendar = RatingFixtures.calendar
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 50))!
        let records = [
            RatingFixtures.record(1, at: day),
            RatingFixtures.record(2, at: day.addingTimeInterval(5 * 60)),
            RatingFixtures.record(3, at: day.addingTimeInterval(20 * 60)),
            RatingFixtures.record(4, at: day.addingTimeInterval(25 * 60)),
            RatingFixtures.record(5, at: day.addingTimeInterval(3 * 86_400)),
        ]
        #expect(Policy.distinctDays(records, calendar: calendar) == 3)
        #expect(Policy.distinctDays([], calendar: calendar) == 0)
    }

    @Test("Only finished hacks count; one this build can't read is finished")
    func finished() {
        let base = RatingFixtures.base
        let records = [
            RatingFixtures.record(1, at: base),
            RatingFixtures.record(2, at: base, summary: RatingFixtures.summary(2, state: .awaiting, closed: false)),
            HackResultRecord(id: "future", date: base, summary: nil),
        ]
        #expect(Policy.finishedHacks(records).map(\.id) == ["launch/1/1", "future"])
    }

    @Test("A complete hack with no gear, or gear read in full, is clean")
    func clean() {
        let base = RatingFixtures.base
        #expect(Policy.isClean(RatingFixtures.record(1, at: base)))
        var withGear = RatingFixtures.record(2, at: base)
        withGear.gear = RatingFixtures.gear(2, items: ["Resonator", "XMP Burster"])
        #expect(Policy.isClean(withGear))
    }

    @Test("An Unrecognized item makes a hack not clean")
    func unrecognizedItem() {
        var record = RatingFixtures.record(1, at: RatingFixtures.base)
        record.gear = RatingFixtures.gear(1, items: ["Resonator", nil])
        #expect(!Policy.isClean(record))
    }

    @Test("Errors make a hack not clean: partial or unseen result, a disagreement, gear not read or unreadable")
    func errors() {
        let base = RatingFixtures.base
        #expect(!Policy.isClean(RatingFixtures.record(1, at: base, summary: RatingFixtures.summary(1, state: .partial))))
        #expect(!Policy.isClean(RatingFixtures.record(1, at: base, summary: RatingFixtures.summary(1, state: .notObserved))))
        #expect(!Policy.isClean(RatingFixtures.record(1, at: base, summary: RatingFixtures.summary(1, closed: false))))
        #expect(!Policy.isClean(RatingFixtures.record(1, at: base,
                                                       summary: RatingFixtures.summary(1, comparison: .disagreement))))
        #expect(!Policy.isClean(HackResultRecord(id: "future", date: base, summary: nil)))
        var notRead = RatingFixtures.record(1, at: base)
        notRead.gear = HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .notRead(reason: "captureStopped"))
        #expect(!Policy.isClean(notRead))
        var unreadable = RatingFixtures.record(1, at: base)
        unreadable.gearUnreadable = true
        #expect(!Policy.isClean(unreadable))
        var partly = RatingFixtures.record(1, at: base)
        partly.gear = RatingFixtures.gear(1, items: ["Resonator"], partial: true)
        #expect(!Policy.isClean(partly))
    }

    @Test("The first launch of a version, or with none recorded, is the first after an update")
    func firstLaunch() {
        #expect(Policy.isFirstLaunchAfterUpdate(lastLaunchedVersion: nil, current: "1.2"))
        #expect(Policy.isFirstLaunchAfterUpdate(lastLaunchedVersion: "1.1", current: "1.2"))
        #expect(!Policy.isFirstLaunchAfterUpdate(lastLaunchedVersion: "1.2", current: "1.2"))
    }
}

@Suite("Review prompt record")
struct ReviewPromptRecordTests {
    @Test("Launches and asks are kept in the app's own defaults")
    func persistence() throws {
        let suite = "ReviewPromptRecordTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ReviewPromptRecord(defaults: defaults)
        #expect(record.lastAskedVersion == nil && record.lastAskedDate == nil)
        #expect(record.registerLaunch(version: "1.2"), "No version recorded yet")
        #expect(!record.registerLaunch(version: "1.2"), "The second launch of 1.2")
        #expect(record.registerLaunch(version: "1.3"), "An update")
        record.recordAsk(version: "1.3", at: RatingFixtures.base)
        let again = ReviewPromptRecord(defaults: defaults)
        #expect(again.lastAskedVersion == "1.3")
        #expect(again.lastAskedDate == RatingFixtures.base)
    }
}

@Suite("Rating links")
struct RatingLinksTests {
    @Test("Rate opens the App Store's write-a-review page for this app")
    func writeReview() {
        #expect(RatingLinks.writeReview.absoluteString == "https://apps.apple.com/app/id6814911908?action=write-review")
    }

    @Test("Source code opens the GitHub repository")
    func sourceCode() {
        #expect(RatingLinks.sourceCode.absoluteString == "https://github.com/ChestnutLUO/Dynamic-Glyph")
    }
}
