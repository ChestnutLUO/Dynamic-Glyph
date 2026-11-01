import CoreGraphics
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages
import ImageIO
import Testing

/// Build 93 kept the command watch only on a fit from the last second, or on a
/// header vote or notice box on the frame itself. Header text is read only on
/// some frames, so a drawn command (strokes over the rings: no fresh fit) lost
/// the watch between readings, marking its commands unresolved. These pin the
/// fix: while the command phase is current the cached fit keeps the watch, a
/// frame without a reading is no evidence against it, and the phase still
/// ends on a contrary reading or after the watch's leave time. S8b: once a
/// notice of the window has been read, a reading that recognised nothing is
/// no evidence either; readable header text of another phase still ends it.
@Suite("Command watch on a cached fit while the command phase is current", .serialized)
struct WatchCommandContextTests {
    private static func noReading() -> Frames.Failure {
        Frames.Failure(description: "Injected: no fresh header reading on this frame")
    }

    /// Readable header text that is not the command channel: what the phrase
    /// matcher returns when two different phases' phrases match. It is the
    /// only unknown reading with text; it does not move the tracker, so only
    /// the command-phase context can release the watch on it.
    private static func readableOther(at time: Double) -> HeaderReading {
        HeaderReading(phase: .unknown, matchedText: "conflicting phrases", confidence: 0, sourceTime: time)
    }

    /// commands.jsonl, one object per row.
    private static func commandRows(_ harness: WatchReproductionHarness) throws -> [[String: Any]] {
        let text = try String(contentsOf: harness.directory.url.appendingPathComponent("commands.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test("Sparse header readings keep a drawn command watched at the full pace, then a contrary reading releases it",
          arguments: [false, true])
    func sparseHeaderReadings(lowPower: Bool) throws {
        // One reading a second (the lane's first request in each source
        // second), each fresh for 0.35 s: gaps longer than `flicker`.
        let gate = FirstReadEachSecond()
        let harness = try WatchReproductionHarness(lowPower: lowPower) { _, time in
            if time > 4 { return WatchReproductionHarness.header(.unknown, at: time) }
            guard gate.admits(time) else { throw Self.noReading() }
            return WatchReproductionHarness.header(.command, at: time)
        }
        defer { harness.output.close() }
        try harness.play(try Frames.recorded("field-00381"), at: 0)
        let drawn = try CommandDrawingFrame.make()
        for index in 1...318 { try harness.play(drawn, at: Double(index) / 60) }
        harness.report("sparse header lowPower=\(lowPower): command reads about once a second to 4, unknown after")
        _ = try harness.finish()
        // The fit from 0 is fresh through 1.0 and reported one analysis late.
        let during = harness.probes.filter { (1.1...4.0).contains($0.time) }
        let unwatched = during.filter { !$0.reasons.has(.commandWatch) || $0.mode?.ratePerSecond != 20 }.map(\.time)
        #expect(!during.isEmpty && unwatched.isEmpty, "No coverage loss between header readings; lost at \(unwatched)")
        #expect(during.allSatisfy { !$0.reasons.has(.calibration) },
                "The drawn stroke must not revalidate the array: this is the cached-fit path")
        #expect(gate.admitted.count >= 4, "Readings at \(gate.admitted)")
        let before = try #require(harness.probes.first { abs($0.time - 2) < 0.001 })
        let after = try #require(harness.probes.first { abs($0.time - 4) < 0.001 })
        #expect(after.commandBandSamples - before.commandBandSamples == 40,
                "Every 20-Hz command band is inspected: \(after.commandBandSamples - before.commandBandSamples)")
        let released = try #require(harness.probes.first { $0.time > 4.05 && !$0.reasons.has(.commandWatch) })
        #expect(released.time <= 4.75, "A contrary header reading ends the phase as before")
    }

    @Test("With no reading at all after the last command evidence, the cached fit holds the watch only for the leave time")
    func noReadingsAfterEvidence() throws {
        let harness = try WatchReproductionHarness { _, time in
            guard time < 0.1 else { throw Self.noReading() }
            return WatchReproductionHarness.header(.command, at: time)
        }
        defer { harness.output.close() }
        try harness.play(try Frames.recorded("field-00381"), at: 0)
        let drawn = try CommandDrawingFrame.make()
        for index in 1...360 { try harness.play(drawn, at: Double(index) / 60) }
        harness.report("no readings after 0.05: leave 2 s, flicker 0.5 s")
        let rows = try harness.finish()
        let atTwo = try #require(harness.probes.first { abs($0.time - 2) < 0.001 })
        #expect(atTwo.reasons.has(.commandWatch), "Within leave of the last command reading")
        let released = try #require(harness.probes.first { $0.time > 2 && !$0.reasons.has(.commandWatch) })
        #expect((2.0...2.7).contains(released.time), "Released at \(released.time): leave plus flicker after the evidence")
        let tail = harness.probes.filter { $0.time >= 2.7 }
        #expect(!tail.isEmpty && tail.allSatisfy { !$0.reasons.has(.commandWatch) },
                "The eight-second cached fit must never re-arm or hold the watch")
        let cached = rows.filter { (2.7...6.0).contains(WatchReproductionHarness.time($0)) }
        #expect(!cached.isEmpty && cached.allSatisfy { $0["calibration"] != nil },
                "The fit is still cached: only command evidence decides")
    }

    @Test("A command phase that starts after the fit is no longer fresh arms the watch from the cached fit")
    func armsOnCachedFit() throws {
        let harness = try WatchReproductionHarness { _, time in
            WatchReproductionHarness.header((2..<3).contains(time) ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        try harness.play(try Frames.recorded("field-00381"), at: 0)
        let drawn = try CommandDrawingFrame.make()
        for index in 1...240 { try harness.play(drawn, at: Double(index) / 60) }
        harness.report("command header 2..<3 only, fit last fresh at 0")
        _ = try harness.finish()
        let idle = try #require(harness.probes.first { abs($0.time - 1.8) < 0.001 })
        #expect(!idle.reasons.has(.commandWatch), "No command evidence yet: the fit alone does not arm it")
        let phase = harness.probes.filter { (2.2...2.95).contains($0.time) }
        #expect(!phase.isEmpty && phase.allSatisfy { $0.reasons.has(.commandWatch) && !$0.reasons.has(.calibration) },
                "Armed on the cached fit while the header reads the command channel")
        let released = try #require(harness.probes.first { $0.time > 3.05 && !$0.reasons.has(.commandWatch) })
        #expect(released.time <= 3.75)
    }

    @Test("Drone mode read before the command window survives a long drawn command into the hack")
    func droneModeSurvivesDrawnCommand() throws {
        // Build 93 lost the watch between header readings; two seconds later
        // the cancel dropped the window and with it the drone footer's mode.
        let gate = FirstReadEachSecond()
        let harness = try WatchReproductionHarness { _, time in
            if time < 0.5 { return WatchReproductionHarness.header(.unknown, at: time) }
            if time >= 5.5 { return WatchReproductionHarness.header(.presenting, at: time) }
            guard gate.admits(time) else { throw Self.noReading() }
            return WatchReproductionHarness.header(.command, at: time)
        }
        defer { harness.output.close() }
        let droneView = try Frames.recorded("field-00666")
        let commandChannel = try Frames.recorded("field-00381")
        let drawn = try CommandDrawingFrame.make()
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        for index in 0...470 {
            let frame = index < 30 ? droneView : index == 30 ? commandChannel : index <= 330 ? drawn
                : index <= 450 ? empty : glyph
            try harness.play(frame, at: Double(index) / 60)
        }
        harness.report("drone footer at 0, command channel 0.5, drawn command to 5.5, hack presented after")
        _ = try harness.finish()
        let text = try String(contentsOf: harness.directory.url.appendingPathComponent("commands.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.contains { $0["kind"] as? String == "notice" && $0["notice"] as? String == "drone" },
                "Precondition: the recorded drone footer was read before the command window")
        let drawing = harness.probes.filter { (1.6...5.4).contains($0.time) }
        let unwatched = drawing.filter { !$0.reasons.has(.commandWatch) }.map(\.time)
        #expect(!drawing.isEmpty && unwatched.isEmpty, "Lost at \(unwatched); readings at \(gate.admitted)")
        let bound = try #require(rows.first { $0["kind"] as? String == "bound" }, "Precondition: the hack started")
        #expect(bound["mode"] as? String == "drone")
        #expect((bound["gear"] as? [String: Any])?["status"] as? String == "notApplicable")
    }

    // MARK: S8b: once a notice is read, header reads that recognise nothing are no evidence

    /// Clip-03 in the owner's replay: the COMPLEX HACK notice shows at about
    /// 9.5-10.0 s and is read twice, presentation starts at 12.035 s, and all
    /// 25 header reads inside that command window were unknown with no matched
    /// text. S8 took each as contrary, so the cached fit stopped supporting the
    /// watch at the first one after the last notice frame; 0.5 s later the
    /// watch lost coverage and the twice-read notice ended unresolved. S8b:
    /// the window's notice has been read, so those reads are no evidence. The
    /// same pattern here, 9.5 s earlier, with a recorded notice crop.
    @Test("Clip-03: a drawn command whose notice was read stays watched through header reads that recognise nothing")
    func clip03NothingReadDuringCommand() throws {
        let nothingRead = WatchReproductionValues<Double>()
        let harness = try WatchReproductionHarness { _, time in
            if time < 0.3 { return WatchReproductionHarness.header(.command, at: time) }
            if time >= 2.75 { return WatchReproductionHarness.header(.presenting, at: time) }
            nothingRead.append(time)
            return WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        let commandChannel = try Frames.recorded("field-00381")
        let drawn = try CommandDrawingFrame.make()
        let notice = try NoticeDrawingFrame.make("simple")
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        for index in 0...200 {
            // 0: the command channel (the last fresh fit); 0.5..<1.0: strokes
            // and the notice; to 2.75: strokes only; then the presented hack.
            let frame = index == 0 ? commandChannel : (30..<60).contains(index) ? notice
                : index < 165 ? drawn : index < 185 ? empty : glyph
            try harness.play(frame, at: Double(index) / 60)
        }
        harness.report("clip-03 pattern: command header to 0.3, notice 0.5..<1.0, nothing read to 2.75, presented after")
        _ = try harness.finish()
        let rows = try Self.commandRows(harness)
        let window = nothingRead.values.filter { $0 < 2.75 }
        #expect(window.count >= 20, "Precondition: reads that recognise nothing fill the command window: \(window)")
        let reads = rows.filter { $0["kind"] as? String == "notice" }
        #expect(reads.filter { $0["notice"] as? String == "simple" }.count >= 2,
                "Precondition: the recorded notice was read twice: \(reads)")
        #expect(!rows.contains { $0["kind"] as? String == "dropped" })
        let drawing = harness.probes.filter { (1.1...2.7).contains($0.time) }
        let unwatched = drawing.filter { !$0.reasons.has(.commandWatch) || $0.mode?.ratePerSecond != 20 }.map(\.time)
        #expect(!drawing.isEmpty && unwatched.isEmpty, "Lost at \(unwatched); nothing read at \(window)")
        #expect(drawing.allSatisfy { !$0.reasons.has(.calibration) },
                "The drawn stroke must not revalidate the array: this is the cached-fit path")
        let bound = try #require(rows.first { $0["kind"] as? String == "bound" }, "Precondition: the hack started")
        let presentation = try #require(bound["presentation"] as? [String: Any])
        #expect(presentation["status"] as? String == "confirmed", "No coverage loss after the notice: \(bound)")
        #expect(presentation["lastObserved"] as? String == "simple")
        #expect(presentation["samples"] as? Int == 2)
        #expect((bound["gear"] as? [String: Any])?["status"] as? String == "noCommandObserved",
                "No coverage-loss event anywhere in the window: \(bound)")
    }

    /// 0: the command channel (the last fresh fit); 0.5..<1.0: strokes and
    /// the recorded SIMPLE notice, read by OCR; then strokes only.
    private static func playReadNotice(_ harness: WatchReproductionHarness, through last: Int) throws {
        let drawn = try CommandDrawingFrame.make()
        let notice = try NoticeDrawingFrame.make("simple")
        try harness.play(try Frames.recorded("field-00381"), at: 0)
        for index in 1...last {
            try harness.play((30..<60).contains(index) ? notice : drawn, at: Double(index) / 60)
        }
    }

    @Test("Readable header text of another phase ends the phase at once, also after the window's notice was read")
    func readableOtherTextEndsPhase() throws {
        let harness = try WatchReproductionHarness { _, time in
            if time < 0.3 { return WatchReproductionHarness.header(.command, at: time) }
            if time >= 1.8 { return Self.readableOther(at: time) }
            return WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        try Self.playReadNotice(harness, through: 240)
        harness.report("command header to 0.3, notice read 0.5..<1.0, nothing read to 1.8, other text after")
        _ = try harness.finish()
        #expect(try Self.commandRows(harness).contains { $0["notice"] as? String == "simple" },
                "Precondition: the notice was read")
        // The fit from 0 is fresh through 1.0 and reported one analysis late.
        let held = harness.probes.filter { (1.1...1.8).contains($0.time) }
        #expect(!held.isEmpty && held.allSatisfy { $0.reasons.has(.commandWatch) && !$0.reasons.has(.calibration) },
                "Held on the cached fit through reads that recognised nothing")
        let released = try #require(harness.probes.first { $0.time > 1.8 && !$0.reasons.has(.commandWatch) })
        #expect(released.time <= 2.5,
                "Released at \(released.time): the other text from 1.8 ends the phase; leave alone would hold it to about 3.5")
        #expect(harness.probes.filter { $0.time >= released.time }.allSatisfy { !$0.reasons.has(.commandWatch) })
    }

    @Test("After a read notice, header reads that recognise nothing hold the watch only for the leave time")
    func nothingReadAfterNoticeRead() throws {
        let nothingRead = WatchReproductionValues<Double>()
        let harness = try WatchReproductionHarness { _, time in
            if time < 0.3 { return WatchReproductionHarness.header(.command, at: time) }
            nothingRead.append(time)
            return WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        try Self.playReadNotice(harness, through: 360)
        harness.report("command header to 0.3, notice read 0.5..<1.0, nothing read after: leave 2 s, flicker 0.5 s")
        let rows = try harness.finish()
        #expect(try Self.commandRows(harness).contains { $0["notice"] as? String == "simple" },
                "Precondition: the notice was read")
        #expect(nothingRead.values.filter { (1.0...3.0).contains($0) }.count >= 10,
                "Precondition: reads that recognise nothing through the leave time: \(nothingRead.values)")
        let held = harness.probes.filter { (1.1...2.9).contains($0.time) }
        #expect(!held.isEmpty && held.allSatisfy { $0.reasons.has(.commandWatch) && !$0.reasons.has(.calibration) },
                "Within leave of the last notice frame (about 0.95)")
        let released = try #require(harness.probes.first { $0.time > 2.9 && !$0.reasons.has(.commandWatch) })
        // Leave (2 s) plus flicker (0.5 s) after the last notice box, seen at
        // the next 20-Hz analysis: about 3.5.
        #expect((3.0...3.6).contains(released.time), "Released at \(released.time)")
        let tail = harness.probes.filter { $0.time >= 3.6 }
        #expect(!tail.isEmpty && tail.allSatisfy { !$0.reasons.has(.commandWatch) },
                "Neither the eight-second cached fit nor further empty reads re-arm or hold the watch")
        let cached = rows.filter { (3.7...6.0).contains(WatchReproductionHarness.time($0)) }
        #expect(!cached.isEmpty && cached.allSatisfy { $0["calibration"] != nil },
                "The fit is still cached: only command evidence decides")
    }
}

/// Admits the header lane's first request in each whole source second.
/// Request times follow the lane's own cadence, so a source-time window would
/// depend on its rounding; this does not.
final class FirstReadEachSecond: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Set<Int> = []
    private var times: [Double] = []
    func admits(_ time: Double) -> Bool {
        lock.withLock {
            guard seconds.insert(Int(time.rounded(.down))).inserted else { return false }
            times.append(time)
            return true
        }
    }
    var admitted: [Double] { lock.withLock { times } }
}

/// The same test-only composite as `WatchCommandDropoutTests`: recorded field
/// Glyph strokes (which block empty-array revalidation) with the presentation
/// strip and timer/notice band blanked. Not a recorded command-drawing frame.
enum CommandDrawingFrame {
    static func make() throws -> CVPixelBuffer {
        let buffer = try Frames.recorded("field-00443")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let top = Int(Double(height) * GameUILayout().slotStripTop) - 2
        let bottom = Int(ceil(Double(height) * 0.29)) + 2
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in top..<bottom { memset(luma + y * stride, 0, width) }
        for y in top / 2..<(bottom + 1) / 2 {
            memset(chroma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        }
        return buffer
    }
}

/// `CommandDrawingFrame` with a recorded notice-band crop (Fixtures/Commands,
/// already in the app test bundle) centred in the notice band, as luma only.
/// The strokes still cover the array; grey pixels can't read as a timer bar.
/// Test-only composite; nothing is saved.
enum NoticeDrawingFrame {
    static func make(_ name: String) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(try TestFixtures.url(name, "png") as CFURL, nil),
              let notice = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Frames.Failure(description: "could not decode \(name).png")
        }
        let noticeWidth = notice.width, noticeHeight = notice.height
        var grey = [UInt8](repeating: 0, count: noticeWidth * noticeHeight)
        let drawn = grey.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: noticeWidth, height: noticeHeight,
                                          bitsPerComponent: 8, bytesPerRow: noticeWidth,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(notice, in: CGRect(x: 0, y: 0, width: noticeWidth, height: noticeHeight))
            return true
        }
        guard drawn else { throw Frames.Failure(description: "could not draw \(name).png in grey") }
        let buffer = try CommandDrawingFrame.make()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        // CommandDrawingFrame has already blanked the band, luma and chroma.
        let band = CommandNoticeDetector.band(width: width, height: height)
        let left = max(0, (width - noticeWidth) / 2)
        let top = Int(band.minY) + max(0, (Int(band.height) - noticeHeight) / 2)
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<min(noticeHeight, height - top) {
            for x in 0..<min(noticeWidth, width - left) {
                luma[(top + y) * stride + left + x] = grey[y * noticeWidth + x]
            }
        }
        return buffer
    }
}
