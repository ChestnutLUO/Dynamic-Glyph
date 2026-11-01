import CoreGraphics

import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Command acknowledgements", .serialized)
struct CommandRecognitionTests {
    @Test func outOfOrderRegistrationStillUsesSourceOrderWithinAnEpoch() {
        var session = CommandObservationSession()
        let later = session.beginNotice(at: 2)
        let earlier = session.beginNotice(at: 1)
        session.accept(.init(notice: .noKey, confidence: 1), id: later, at: 2)
        session.accept(.init(notice: .requestKey, confidence: 1), id: earlier, at: 1)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.effective == .noKey)
    }

    @Test func explicitEpochOrdersCoverageLossAfterOldNumericTimestamps() {
        var session = CommandObservationSession()
        let old = session.beginNotice(at: 100)
        session.accept(.init(notice: .noKey, confidence: 1), id: old, at: 100)
        session.beginEpoch(at: 1)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.status == .unresolved)
        #expect(session.summary(hackID: 1).gear.lastObserved == .noKey)
        // Completion ordering is independent of registration/epoch ordering.
        session.accept(.init(notice: .noKey, confidence: 1), id: old, at: 100.05)
        #expect(session.summary(hackID: 1).gear.effective == nil)
        let fresh = session.beginNotice(at: 1.1)
        session.accept(.init(notice: .requestKey, confidence: 1), id: fresh, at: 1.1)
        session.bind(hackID: 2)
        #expect(session.summary(hackID: 1).gear.status == .unresolved)
        #expect(session.summary(hackID: 2).gear.effective == .requestKey)
    }

    @Test func epochQueueInvalidationRejectsStaleReadsAndPreservesBoundHack() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture("no-key"), at: 99)
        let committed = try #require(capture.take(at: 99))
        capture.accept(.init(notice: .noKey, confidence: 1), frame: committed)
        capture.bind(hackID: 1)
        let retained = capture.summary(hackID: 1)
        try capture.observe(band: fixture("complex"), at: 100)
        let old = try #require(capture.take(at: 100))
        try capture.observe(band: fixture("complex"), at: 100.05)
        #expect(!capture.queue.isEmpty)
        capture.invalidateQueue(at: 1)
        #expect(capture.queue.isEmpty && !capture.showsNotice)
        capture.accept(.init(notice: .complex, confidence: 1), frame: old)
        capture.bind(hackID: 2)
        #expect(capture.summary(hackID: 2).presentation.status == .unresolved)
        #expect(capture.summary(hackID: 2).presentation.effective == nil)
        #expect(capture.summary(hackID: 1) == retained)
        try capture.observe(band: fixture("request-key-single"), at: 1.1)
        let fresh = try #require(capture.take(at: 1.1))
        capture.accept(.init(notice: .requestKey, confidence: 1), frame: fresh)
        capture.bind(hackID: 3)
        #expect(capture.summary(hackID: 3).gear.effective == .requestKey)
        #expect(capture.summary(hackID: 1) == retained)
    }

    @Test func futureQueuedCropCannotBeConsumedByRewoundClock() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture("no-key"), at: 100)
        let id = try #require(capture.queue.first?.id)
        #expect(capture.take(at: 1) == nil)
        #expect(capture.takeDropped() == [id])
    }

    @Test func watchResetCannotRearmWhenNewClockReachesOldNumericTime() {
        var watch = CommandScreenWatch()
        _ = watch.observe(at: 100, calibrated: true, commandPhase: true, complete: true)
        watch.reset()
        for time in [1.0, 99, 100, 100.25] {
            #expect(watch.observe(at: time, calibrated: false, commandPhase: true, complete: true) == .none)
            #expect(!watch.watching)
        }
        _ = watch.observe(at: 100.3, calibrated: true, commandPhase: true, complete: true)
        #expect(watch.watching)
    }

    @Test func independentCategoriesAndRejectedReplacement() {
        var session = CommandObservationSession()
        for (index, notice) in [CommandNoticeReading.Notice.requestKey, .complex, .noKey, .invalid, .keysOnly, .simple].enumerated() {
            let id = session.beginNotice(at: Double(index))
            session.accept(.init(notice: notice, confidence: 1, language: "en"), id: id, at: Double(index))
        }
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).presentation.effective == .simple)
        #expect(session.summary(hackID: 1).gear.effective == .keysOnly)
    }

    @Test func missingFinalNoticeDoesNotKeepOldSetting() {
        var session = CommandObservationSession()
        let first = session.beginNotice(at: 1)
        session.accept(.init(notice: .noKey, confidence: 1), id: first, at: 1)
        let last = session.beginNotice(at: 2)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.status == .unresolved)
        #expect(session.summary(hackID: 1).gear.lastObserved == .noKey)
        // A pre-boundary completion stays with the already bound hack.
        session.accept(.init(notice: .requestKey, confidence: 1), id: last, at: 2)
        #expect(session.summary(hackID: 1).gear.effective == .requestKey)
        #expect(session.summary(hackID: 1).gear.samples == 1)
        session.markObserved()
        session.bind(hackID: 2)
        #expect(session.summary(hackID: 2).gear.status == .noCommandObserved)
    }

    @Test func unseenOrUnboundWindowIsUncertainNotNoCommand() {
        var session = CommandObservationSession()
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.status == .unresolved)
        #expect(session.summary(hackID: 1).presentation.status == .unresolved)
        #expect(session.summary(hackID: 99).gear.status == .unresolved)
        session.setMode(.drone)
        session.bind(hackID: 2)
        #expect(session.summary(hackID: 2).gear.status == .notApplicable)
        #expect(session.summary(hackID: 2).presentation.status == .unresolved)
    }

    @Test func unreadableReadBesideClearOnesIsIgnored() {
        var session = CommandObservationSession()
        let id = session.beginNotice(at: 1)
        session.accept(.init(notice: nil, confidence: 0), id: id, at: 1)
        session.accept(.init(notice: .requestKey, confidence: 0.99, language: "en"), id: id, at: 1.05)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.effective == .requestKey)
        #expect(session.summary(hackID: 1).gear.samples == 1)
    }

    @Test func screenWatchKeepsWatchingThroughFlickersAndCancelsOnLeaving() {
        var watch = CommandScreenWatch()
        #expect(watch.observe(at: 0, calibrated: true, commandPhase: true, complete: true) == .none)
        #expect(watch.watching)
        // A stroke hides the array for a moment: still watched, nothing lost.
        #expect(watch.observe(at: 0.3, calibrated: false, commandPhase: true, complete: true) == .none)
        #expect(watch.watching)
        #expect(watch.observe(at: 0.4, calibrated: true, commandPhase: true, complete: true) == .none)
        // Gone longer than a flicker: coverage is lost, then the window ends.
        #expect(watch.observe(at: 1.0, calibrated: false, commandPhase: true, complete: true) == .interrupt)
        #expect(!watch.watching)
        #expect(watch.observe(at: 2.0, calibrated: false, commandPhase: true, complete: true) == .none)
        #expect(watch.observe(at: 3.1, calibrated: false, commandPhase: true, complete: true) == .cancel)
        // Presentation keeps the array but stops command watching, losing nothing.
        _ = watch.observe(at: 4, calibrated: true, commandPhase: true, complete: true)
        #expect(watch.observe(at: 4.1, calibrated: true, commandPhase: false, complete: true) == .none)
        #expect(!watch.watching)
    }

    @Test func distinctFramesRequiredForLowerConfidenceAndConflictsStayUnknown() {
        var session = CommandObservationSession()
        let id = session.beginNotice(at: 1)
        let read = CommandNoticeReading(notice: .simple, confidence: 0.85, language: "en")
        session.accept(read, id: id, at: 1); session.accept(read, id: id, at: 1)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).presentation.status == .unresolved)
        session.accept(read, id: id, at: 1.017)
        #expect(session.summary(hackID: 1).presentation.samples == 2)
        session.accept(.init(notice: .complex, confidence: 1), id: id, at: 1.034)
        #expect(session.summary(hackID: 1).presentation.status == .unresolved)
    }

    @Test func droneAndCancellation() {
        var session = CommandObservationSession()
        session.setMode(.drone)
        let id = session.beginNotice(at: 1)
        session.accept(.init(notice: .complex, confidence: 1), id: id, at: 1)
        session.bind(hackID: 1)
        #expect(session.summary(hackID: 1).gear.status == .notApplicable)
        #expect(session.summary(hackID: 1).presentation.effective == .complex)
        let abandoned = session.beginNotice(at: 2)
        session.cancel()
        session.accept(.init(notice: .keysOnly, confidence: 1), id: abandoned, at: 2)
        session.bind(hackID: 2)
        #expect(session.summary(hackID: 2).mode == .unknown)
        #expect(session.summary(hackID: 2).gear.effective == nil)
    }

    @Test(arguments: ["NO KEY EXTRA", "ONLY", "SPEED", "REQUEST KEV", "DRONE FOOTAGE", "请求钥匙"])
    func parserRejectsUnknownText(_ text: String) {
        #expect(CommandNoticeParser().read([(text, 1)]).notice == nil)
    }

    func fixture(_ name: String) throws -> CGImage {
        try ReferenceData.requireScreenshots()
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures/Assets/Screenshots/Commands"))
        return try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
    }

    @Test(arguments: [("simple", HackCommand.simple), ("complex", .complex), ("no-key", .noKey),
                      ("keys-only", .keysOnly), ("request-key-single", .requestKey)])
    func recordedNotices(_ sample: (String, HackCommand)) throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture(sample.0), at: 1)
        let frame = try #require(capture.take(at: 1))
        let reading = try CommandNoticeReader().read(frame)
        #expect(reading.notice?.command == sample.1)
        capture.accept(reading, frame: frame)
        capture.bind(hackID: 1)
        let summary = capture.summary(hackID: 1)
        let selection = sample.1.isPresentation ? summary.presentation : summary.gear
        #expect(selection.effective == sample.1)
        #expect(selection.samples == 1)
        #expect(selection.language == "en")
    }

    @Test func everyDeliveredFrameAndDirectReplacement() throws {
        let capture = CommandNoticeCapture()
        for (time, name) in [(1.0, "no-key"), (1.017, "no-key"), (1.034, "request-key-single"), (1.051, "empty")] {
            try capture.observe(band: fixture(name), at: time)
        }
        while let frame = capture.take(at: 1.06) { capture.accept(try CommandNoticeReader().read(frame), frame: frame) }
        capture.bind(hackID: 1)
        #expect(capture.summary(hackID: 1).gear.effective == .requestKey)
        #expect(capture.summary(hackID: 1).gear.samples == 1)
    }

    @Test func interruptionMakesBothUncertainUntilALaterNoticeResolvesOne() throws {
        let capture = CommandNoticeCapture()
        capture.interrupt(at: 0.5)
        try capture.observe(band: fixture("complex"), at: 1)
        while let frame = capture.take(at: 1) { capture.accept(try CommandNoticeReader().read(frame), frame: frame) }
        capture.interrupt(at: 1.5)
        try capture.observe(band: fixture("request-key-single"), at: 2)
        while let frame = capture.take(at: 2) { capture.accept(try CommandNoticeReader().read(frame), frame: frame) }
        capture.bind(hackID: 1)
        let summary = capture.summary(hackID: 1)
        // A gap after COMPLEX could hide SIMPLE; the later REQUEST KEY resolves keys.
        #expect(summary.presentation.status == .unresolved && summary.presentation.lastObserved == .complex)
        #expect(summary.gear.effective == .requestKey)
    }

    @Test func secondSampleWaitsForASettledFrameAndExpiredCropsAreReported() throws {
        let capture = CommandNoticeCapture()
        for time in [1.0, 1.017, 1.034, 1.051] { try capture.observe(band: fixture("no-key"), at: time) }
        #expect(capture.queue.map(\.sourceTime) == [1.0, 1.051])
        let id = try #require(capture.queue.first?.id)
        #expect(capture.take(at: 3) == nil)
        #expect(capture.takeDropped() == [id, id])
        #expect(capture.takeDropped().isEmpty)
    }

    @Test func invalidAndBlankAreNotAcceptedCommands() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture("invalid"), at: 1)
        let frame = try #require(capture.take(at: 1))
        #expect(try CommandNoticeReader().read(frame).notice == .invalid)
        try capture.observe(band: fixture("empty"), at: 1.05)
        #expect(capture.queue.isEmpty)
    }
    @Test func overlayAfterValidNoticeMakesFinalUnknown() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture("no-key"), at: 1)
        let frame = try #require(capture.take(at: 1))
        capture.accept(try CommandNoticeReader().read(frame), frame: frame)
        let context = try #require(CGContext(data: nil, width: 602, height: 170, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 70, width: 602, height: 3))
        try capture.observe(band: #require(context.makeImage()), at: 1.1)
        capture.bind(hackID: 1)
        #expect(capture.summary(hackID: 1).gear.status == .unresolved)
        #expect(capture.summary(hackID: 1).gear.lastObserved == .noKey)
    }

    @Test func queueExpiryAndClockRestart() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: fixture("no-key"), at: 10)
        #expect(capture.take(at: 12) == nil)
        capture.bind(hackID: 1)
        #expect(capture.summary(hackID: 1).gear.status == .unresolved)
        try capture.observe(band: fixture("request-key-single"), at: 1)
        let frame = try #require(capture.take(at: 1))
        capture.accept(try CommandNoticeReader().read(frame), frame: frame)
        capture.bind(hackID: 2)
        #expect(capture.summary(hackID: 2).gear.effective == .requestKey)
    }

    @Test func commandMetadataRoundTripsAndOldHistoryRemainsUnknown() throws {
        var commands = HackCommandSummary()
        commands.mode = .drone
        commands.gear.status = .notApplicable
        let summary = HackResultSummary(captureSessionID: 1, hackID: 1, state: .notObserved,
                                        isClosed: true, closeReason: "notObserved", hackingBonus: nil,
                                        speedBonus: nil, slots: [], commands: commands)
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: data) == summary)
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["commands"] = nil
        let decoded = try JSONDecoder().decode(HackResultSummary.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.commands == nil)
        // Fields missing from a saved summary take their defaults.
        let partial = Data(#"{"gear":{"status":"confirmed","lastObserved":"noKey"}}"#.utf8)
        let commandsOnly = try JSONDecoder().decode(HackCommandSummary.self, from: partial)
        #expect(commandsOnly.gear.effective == .noKey && commandsOnly.gear.samples == 0)
        #expect(commandsOnly.presentation.status == .noCommandObserved && commandsOnly.mode == .unknown)
    }

}
