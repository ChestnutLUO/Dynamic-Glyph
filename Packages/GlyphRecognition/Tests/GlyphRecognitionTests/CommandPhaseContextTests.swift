import CoreGraphics
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Command phase context for a cached array fit")
struct CommandPhaseContextTests {
    @Test("Frames with no fresh header reading keep the phase, for at most the watch's leave time")
    func missingReadingsAreNotContrary() {
        var context = CommandPhaseContext()
        #expect(!context.isCurrent(at: 0), "No command evidence yet")
        context.header(.command, at: 1)
        #expect(context.isCurrent(at: 1))
        #expect(context.isCurrent(at: 2.9), "Header text is read only on some frames")
        #expect(context.isCurrent(at: 1 + context.leave))
        #expect(!context.isCurrent(at: 1 + context.leave + 0.05), "No evidence for longer than leave ends it")
        #expect(context.leave == CommandScreenWatch().leave)
    }

    @Test("A header reading of any other phase ends the phase at once")
    func contraryReadingEndsIt() {
        for phase in [GamePhase.unknown, .presenting, .input] {
            var context = CommandPhaseContext()
            context.header(.command, at: 1)
            context.header(phase, at: 1.3)
            #expect(!context.isCurrent(at: 1.35), "\(phase) after the command reading")
            context.header(.command, at: 1.6)
            #expect(context.isCurrent(at: 1.65), "A later command reading restores it")
        }
    }

    @Test("A current notice box is command evidence, also beside a contrary header read on the same frame")
    func noticeEvidence() {
        var context = CommandPhaseContext()
        context.header(.unknown, at: 2)
        context.notice(at: 2)
        #expect(context.isCurrent(at: 2))
        #expect(context.isCurrent(at: 3.5))
        context.header(.unknown, at: 3.6)
        #expect(!context.isCurrent(at: 3.6))
    }

    @Test("Out-of-order and older readings never extend the phase; a reset forgets it")
    func ordering() {
        var context = CommandPhaseContext()
        context.header(.command, at: 5)
        context.header(.command, at: 3)
        #expect(context.isCurrent(at: 6.9), "The older reading must not move the evidence back")
        #expect(!context.isCurrent(at: 4), "Source time before the evidence is not current")
        context.header(.command, at: .nan)
        context.notice(at: .infinity)
        #expect(context.isCurrent(at: 6))
        context.reset()
        #expect(!context.isCurrent(at: 6))
    }
}

/// S8b: a header reading that recognised nothing (unknown, no matched text)
/// is no evidence once a notice of the open command window has been read;
/// before that it ends the phase as in S8. The command screen's header is
/// mostly unreadable while a command is drawn.
@Suite("Command phase context: header reads that recognise nothing, after a notice read")
struct CommandPhaseContextNoticeReadTests {
    private static func nothing(at time: Double) -> HeaderReading {
        HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
    }
    /// The phrase matcher's only unknown reading with text: phrases of two
    /// different phases at once, so readable text that is not the command's.
    private static func conflicting(at time: Double) -> HeaderReading {
        HeaderReading(phase: .unknown, matchedText: "conflicting phrases", confidence: 0, sourceTime: time)
    }

    @Test("Only an unknown reading without text recognised nothing")
    func readable() {
        #expect(!CommandPhaseContext.isReadable(Self.nothing(at: 1)))
        #expect(!CommandPhaseContext.isReadable(HeaderReading(phase: .unknown, matchedText: " \n", confidence: 0)))
        #expect(CommandPhaseContext.isReadable(Self.conflicting(at: 1)))
        for phase in [GamePhase.command, .presenting, .input, .completed] {
            #expect(CommandPhaseContext.isReadable(HeaderReading(phase: phase, matchedText: "", confidence: 0)))
        }
    }

    /// Clip-03 in the owner's replay: the notice shows at about 9.5-10.0 s and
    /// is read twice, presentation starts at 12.035 s, and all 25 header reads
    /// in between recognised nothing. Frames every 0.05 s, as the watch
    /// analyses them, fed in LiveGlyphOutput's order.
    @Test("Clip-03: after the notice is read, reads that recognise nothing keep the phase for leave after the last notice")
    func clip03() {
        func play(readsNotice: Bool) -> (lost: [Double], at12: Bool, after: Bool) {
            var context = CommandPhaseContext()
            var lost: [Double] = []
            var last: HeaderReading?
            for index in 186...241 {
                let time = Double(index) / 20
                if index == 186 { last = HeaderReading(phase: .command, matchedText: "COMMAND CHANNEL",
                                                       confidence: 1, sourceTime: time) }
                if index >= 192, index.isMultiple(of: 2) { last = Self.nothing(at: time) }
                if let last { context.header(last) }
                // The two crops, 9.5 and 9.55, read 0.15 s later.
                context.noticeRead(at: !readsNotice || index < 193 ? nil : index == 193 ? 9.5 : 9.55)
                if (190...200).contains(index) { context.notice(at: time) }
                if index <= 240, !context.isCurrent(at: time) { lost.append(time) }
            }
            return (lost, context.isCurrent(at: 12), context.isCurrent(at: 12.05))
        }
        let read = play(readsNotice: true)
        #expect(read.lost.isEmpty, "Lost at \(read.lost)")
        #expect(read.at12 && !read.after, "Leave (2 s) after the last notice at 10.0, no longer")
        // S8's behaviour while no notice of the window has been read.
        let unread = play(readsNotice: false)
        #expect(unread.lost.first == 10.1, "Without a read, the first empty read after the last notice ends it")
    }

    @Test("Before a notice is read, a reading that recognised nothing ends the phase as in S8")
    func beforeNoticeRead() {
        var context = CommandPhaseContext()
        context.header(.command, at: 1)
        context.notice(at: 1.05)
        context.header(Self.nothing(at: 1.1))
        #expect(!context.isCurrent(at: 1.1), "Header-only and box-only windows end on it, as S8 did")
        context.noticeRead(at: nil)
        #expect(!context.isCurrent(at: 1.15))
        // Once the window's notice is read, its earlier empty reads are explained too.
        context.noticeRead(at: 1.05)
        #expect(context.isCurrent(at: 1.15))
        #expect(context.isCurrent(at: 3))
        #expect(!context.isCurrent(at: 3.1), "Leave after the latest evidence, the read's own source time")
    }

    @Test("Readable header text of another phase ends the phase at once, also after a notice read",
          arguments: [GamePhase.presenting, .input, .completed, .unknown])
    func readableTextEndsIt(_ phase: GamePhase) {
        var context = CommandPhaseContext()
        context.header(.command, at: 1)
        context.noticeRead(at: 1.2)
        context.header(Self.nothing(at: 1.3))
        #expect(context.isCurrent(at: 1.35), "Nothing recognised is no evidence after the read")
        context.header(phase == .unknown ? Self.conflicting(at: 1.4)
                       : HeaderReading(phase: phase, matchedText: phase.rawValue, confidence: 1, sourceTime: 1.4))
        #expect(!context.isCurrent(at: 1.4), "\(phase)")
        context.header(Self.nothing(at: 1.5))
        context.noticeRead(at: 1.2)
        #expect(!context.isCurrent(at: 1.55), "Neither nothing read nor the same old read restores it")
        context.notice(at: 1.6)
        #expect(context.isCurrent(at: 1.6), "Newer command evidence does")
    }

    @Test("A notice read is command evidence at its source time, bounded by leave; it never moves evidence back")
    func readIsEvidence() {
        var context = CommandPhaseContext()
        context.header(Self.nothing(at: 0.5))
        #expect(!context.isCurrent(at: 0.5), "Nothing recognised never starts a phase")
        context.noticeRead(at: 4)
        for step in 1...30 { context.header(Self.nothing(at: 4 + Double(step) / 20)) }
        #expect(context.isCurrent(at: 4))
        #expect(context.isCurrent(at: 5.5))
        #expect(context.isCurrent(at: 6))
        #expect(!context.isCurrent(at: 6.05), "Empty reads never extend it")
        context.noticeRead(at: 3)
        #expect(!context.isCurrent(at: 6.05), "An older read does not move the evidence")
        #expect(!context.isCurrent(at: 3.5), "Source time before the evidence is not current")
    }

    @Test("A bind or cancel (no read in the open window) and an epoch break end the exemption")
    func windowEnds() {
        var context = CommandPhaseContext()
        context.header(.command, at: 1)
        context.noticeRead(at: 1.1)
        context.header(Self.nothing(at: 1.3))
        #expect(context.isCurrent(at: 1.3))
        context.noticeRead(at: nil)
        #expect(!context.isCurrent(at: 1.35), "A read of the bound or cancelled window no longer explains them")
        context.noticeRead(at: 1.1)
        context.reset()
        #expect(!context.isCurrent(at: 1.35))
        context.notice(at: 2)
        context.header(Self.nothing(at: 2.1))
        #expect(!context.isCurrent(at: 2.1), "After an epoch break the exemption needs a new read")
    }
}

/// `CommandNoticeCapture.noticeReadAt`, the window's read notice that
/// `CommandPhaseContext.noticeRead(at:)` mirrors.
@Suite("Command notice capture: the open window's read notice")
struct CommandNoticeReadTimeTests {
    private func fixture(_ name: String) throws -> CGImage {
        try ReferenceData.requireScreenshots()
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures/Assets/Screenshots/Commands"))
        return try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
    }

    @Test("Only a read with a notice counts, at its crop's source time, until bind, cancel or epoch break")
    func readTime() throws {
        let capture = CommandNoticeCapture()
        #expect(capture.noticeReadAt == nil)
        try capture.observe(band: fixture("simple"), at: 1)
        let unread = try #require(capture.take(at: 1))
        capture.accept(.init(notice: nil, confidence: 0), frame: unread)
        #expect(capture.noticeReadAt == nil, "OCR returned no notice")
        capture.accept(.init(notice: .simple, confidence: 1), frame: unread)
        #expect(capture.noticeReadAt == 1)
        capture.bind(hackID: 1)
        #expect(capture.noticeReadAt == nil, "Bound: the next window has none")

        try capture.observe(band: fixture("complex"), at: 2)
        let beforeBind = try #require(capture.take(at: 2))
        capture.bind(hackID: 2)
        capture.accept(.init(notice: .complex, confidence: 1), frame: beforeBind)
        #expect(capture.noticeReadAt == nil, "A read of an earlier window's crop does not count")

        try capture.observe(band: fixture("no-key"), at: 3)
        let crop = try #require(capture.take(at: 3))
        capture.accept(.init(notice: .noKey, confidence: 1), frame: crop)
        #expect(capture.noticeReadAt == 3)
        capture.cancel()
        #expect(capture.noticeReadAt == nil, "Cancelled")

        try capture.observe(band: fixture("simple"), at: 4)
        let old = try #require(capture.take(at: 4))
        capture.accept(.init(notice: .simple, confidence: 1), frame: old)
        #expect(capture.noticeReadAt == 4)
        capture.invalidateQueue(at: 0.5)
        #expect(capture.noticeReadAt == nil, "Epoch break")
        capture.accept(.init(notice: .simple, confidence: 1), frame: old)
        #expect(capture.noticeReadAt == nil, "An old-epoch read does not count")
    }
}
