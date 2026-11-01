import Combine
import Foundation
import Testing

/// The Shortcuts and Siri actions' decisions: what Start and Stop say from
/// what they saw, and which Statistics period Open Statistics asks for.
@Suite("Shortcuts actions")
struct AppIntentsTests {
    // MARK: - Start

    static let idle = StartCaptureConditions(isReading: false, isGettingReady: false)

    @Test("Start asks for screen sharing only when Home's Start would")
    func startOpens() {
        let answer = StartCaptureAnswer(Self.idle)
        #expect(answer == .opened)
        #expect(answer.asksForSharing)
    }

    @Test("Start never sets up a second capture, and says why")
    func startExplains() {
        var reading = Self.idle
        reading.isReading = true
        var gettingReady = Self.idle
        gettingReady.isGettingReady = true
        #expect(StartCaptureAnswer(reading) == .alreadyRunning)
        #expect(StartCaptureAnswer(gettingReady) == .notReady)
        for answer in [StartCaptureAnswer.alreadyRunning, .notReady] {
            #expect(!answer.asksForSharing)
        }
    }

    @Test("Running outranks getting ready")
    func startPrecedence() {
        let all = StartCaptureConditions(isReading: true, isGettingReady: true)
        #expect(StartCaptureAnswer(all) == .alreadyRunning)
        let notRunning = StartCaptureConditions(isReading: false, isGettingReady: true)
        #expect(StartCaptureAnswer(notRunning) == .notReady)
    }

    /// A Glyph list is optional: without one, capture reads gear only, so
    /// Start opens as usual, whatever the stored Glyph assistance switch says.
    @Test("With no Glyph list, Start opens the app with the normal answer")
    func startWithoutGlyphList() {
        for preferred in [false, true] {
            #expect(!GlyphAssistance.isInEffect(preferred: preferred, hasGlyphList: false))
        }
        let answer = StartCaptureAnswer(Self.idle)
        #expect(answer == .opened)
        #expect(answer.asksForSharing)
        #expect(String(localized: answer.dialog) == "Dynamic Glyph is open. Start screen sharing to begin.")
    }

    @Test("Start's answers never say capture is running when it only opened the app")
    func startDialogs() {
        let opened = String(localized: StartCaptureAnswer.opened.dialog)
        #expect(opened == "Dynamic Glyph is open. Start screen sharing to begin.")
        #expect(!opened.localizedCaseInsensitiveContains("running"))
        #expect(String(localized: StartCaptureAnswer.alreadyRunning.dialog) == "Dynamic Glyph is already running.")
    }

    // MARK: - Stop

    @Test("Stop reports a stop only when it asked and then saw the capture end")
    func stopOutcomes() {
        #expect(StopCaptureOutcome.decide(asked: false, stillOn: false) == .notRunning)
        #expect(StopCaptureOutcome.decide(asked: true, stillOn: false) == .stopped)
        #expect(StopCaptureOutcome.decide(asked: true, stillOn: true) == .unconfirmed)
        #expect(StopCaptureOutcome.decide(asked: false, stillOn: true) == .unconfirmed)
    }

    @Test("Each stop outcome has its own line")
    func stopDialogs() {
        let lines = [StopCaptureOutcome.notRunning, .stopped, .unconfirmed].map { String(localized: $0.dialog) }
        #expect(lines == ["Dynamic Glyph isn't running.", "Dynamic Glyph stopped.",
                          "Asked Dynamic Glyph to stop, but couldn't confirm it. Check the app."])
    }

    // MARK: - Open Statistics

    @Test("Open Statistics' periods are the Statistics page's own")
    func periods() {
        #expect(StatisticsShortcutPeriod.allCases.map(\.period) == [.today, .week, .all])
        #expect(StatisticsShortcutPeriod.allCases.map { StatisticsRange.Preset($0.period) }
                == [.day, .sevenDays, .all])
    }

    @Test("Saved shortcuts keep their period across releases")
    func rawValues() {
        #expect(StatisticsShortcutPeriod.allCases.map(\.rawValue) == ["today", "last7Days", "all"])
    }

    @MainActor
    @Test("A cold launch keeps the period until the page is ready, then shows it once")
    func coldLaunch() {
        let inbox = StatisticsOpenInbox()
        inbox.post(.week)
        #expect(inbox.take(isReady: false) == nil)
        #expect(inbox.pending == .week)
        #expect(inbox.take(isReady: true) == .week)
        #expect(inbox.take(isReady: true) == nil)
    }

    @MainActor
    @Test("A warm launch is told at once, and the latest request wins")
    func warmLaunch() {
        let inbox = StatisticsOpenInbox()
        var announcements = 0
        let subscription = inbox.posted.sink { announcements += 1 }
        inbox.post(.today)
        inbox.post(.all)
        #expect(announcements == 2)
        #expect(inbox.take(isReady: true) == .all)
        #expect(inbox.pending == nil)
        subscription.cancel()
    }
}
