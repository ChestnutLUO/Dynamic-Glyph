import CoreGraphics
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// The `headerStillSkip` cut in the header reader: the grid it compares, when
/// a header-only read is skipped, and the reading a skip issues again.
/// Synthetic pixels and injected OCR exercise the decision only; they make no
/// claim about how any language's header reads.
@Suite("Still header skip")
struct HeaderStillSkipTests {
    private let session = CaptureSessionID(rawValue: 1)

    /// A grey frame whose header rows are `level` with `text`'s stripes 100
    /// levels brighter, over a background that differs everywhere else.
    /// Grey pixels make each cell's grey exactly its pixels' mean, so a
    /// `level` one higher moves every cell by exactly one grey level.
    static func frame(level: UInt8 = 40, text: Int = 0, width: Int = 320,
                      height: Int = 700) throws -> (image: CGImage, band: FrameTopBand) {
        let rect = HeaderTextRecognizer().headerRect(width: width, height: height)
        let header = Int(rect.minY)..<Int(rect.maxY)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let value = header.contains(y)
                    ? level &+ ((x / 8 + text) % 3 == 0 ? 100 : 0)
                    : UInt8(30 + (x * 7 + y * 3) % 50)
                let offset = (y * width + x) * 3
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return (image, try ImageDecoder.topBand(image))
    }

    private static func signature(_ frame: (image: CGImage, band: FrameTopBand)) throws -> HeaderStillSignature {
        let width = frame.image.width, height = frame.image.height
        let rect = HeaderTextRecognizer().headerRect(width: width, height: height)
        return try #require(HeaderStillSignature(rgb: frame.band.image.pixels, width: width,
                                                 rows: Int(rect.minY)..<Int(rect.maxY),
                                                 frameWidth: width, frameHeight: height))
    }

    private static let read = HeaderReading(phase: .presenting, matchedText: "INJECTED presenting",
                                            confidence: 0.9)

    private func reader(still: Bool = true, languages: GameLanguageMemory? = nil, meter: PowerMeter? = nil,
                        reads: ReadTimes = ReadTimes(),
                        operation: GameHeaderReader.HeaderOperation? = nil) -> GameHeaderReader {
        var configuration = GameHeaderReader.Configuration(skipsStillHeaders: still)
        if let languages { configuration.languages = languages }
        return GameHeaderReader(configuration: configuration, headerOperation: operation ?? { _, time in
            reads.append(time)
            return Self.read.at(sourceTime: time)
        }, meter: meter)
    }

    private func finish(_ reader: GameHeaderReader) async throws {
        for _ in 0..<200 {
            if !reader.isReading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("OCR lane did not finish")
    }

    // MARK: - The grid

    @Test("The grid and tolerance are the measured ones: 160x16 cells, at most 1.0 grey level apart on average")
    func gridAndTolerance() throws {
        #expect(HeaderStillSignature.columns == 160 && HeaderStillSignature.rows == 16)
        #expect(HeaderStillSignature.tolerance == 1.0)
        let base = try Self.signature(Self.frame())
        #expect(base.cells.count == 2560)
        #expect(base.meanDifference(from: base) == 0 && base.isStill(comparedWith: base))
        let one = try Self.signature(Self.frame(level: 41))
        #expect(one.meanDifference(from: base) == 1.0 && one.isStill(comparedWith: base), "At the tolerance is still")
        let two = try Self.signature(Self.frame(level: 42))
        #expect(two.meanDifference(from: base) == 2.0 && !two.isStill(comparedWith: base))
        let text = try Self.signature(Self.frame(text: 1))
        #expect((text.meanDifference(from: base) ?? 0) > 21, "Other text is far beyond the tolerance")
    }

    @Test("A frame of another size never compares as still")
    func frameSize() throws {
        let base = try Self.signature(Self.frame())
        for (width, height) in [(321, 700), (320, 701)] {
            let other = try Self.signature(Self.frame(width: width, height: height))
            #expect(other.meanDifference(from: base) == nil && !other.isStill(comparedWith: base))
        }
    }

    @Test("Cells follow the measured rule: edges at index x size / count, means truncated")
    func cellRule() throws {
        // At 320 wide each cell holds columns 2c and 2c+1, grey c and c+1
        // here, whose truncated mean is c; two rows of 32 per grid row.
        let width = 320, rows = 0..<32
        var pixels = [UInt8](repeating: 0, count: width * rows.count * 3)
        for y in rows {
            for x in 0..<width {
                let grey = UInt8(x / 2 + x % 2)
                for channel in 0..<3 { pixels[(y * width + x) * 3 + channel] = grey }
            }
        }
        let grid = try #require(HeaderStillSignature(rgb: pixels, width: width, rows: rows,
                                                     frameWidth: width, frameHeight: 100))
        #expect(grid.cells[0] == 0 && grid.cells[1] == 1 && grid.cells[159] == 159)
        #expect(grid.cells[15 * 160 + 7] == 7)
        // Narrower than the grid: every cell still holds at least one pixel.
        let narrow = try #require(HeaderStillSignature(rgb: [UInt8](repeating: 9, count: 100 * 4 * 3), width: 100,
                                                       rows: 0..<4, frameWidth: 100, frameHeight: 10))
        #expect(narrow.cells.allSatisfy { $0 == 9 })
        #expect(HeaderStillSignature(rgb: pixels, width: width, rows: 0..<33, frameWidth: width, frameHeight: 100) == nil,
                "Rows beyond the pixels build nothing")
        #expect(HeaderStillSignature(rgb: pixels, width: width, rows: 5..<5, frameWidth: width, frameHeight: 100) == nil)
    }

    @Test("The top band and the rendered frame's header crop give the same grid")
    func sources() throws {
        let frame = try Self.frame(text: 2)
        let rect = HeaderTextRecognizer().headerRect(width: frame.image.width, height: frame.image.height)
        let crop = try ImageDecoder.decodeColor(frame.image, in: rect)
        let fromCrop = try #require(HeaderStillSignature(rgb: crop.pixels, width: crop.width, rows: 0..<crop.height,
                                                         frameWidth: frame.image.width,
                                                         frameHeight: frame.image.height))
        #expect(fromCrop == (try Self.signature(frame)))
    }

    // MARK: - On unless the player chose otherwise

    @Test("The cut is on on a fresh install and in Settings' New, off in Old; the four cuts without it are custom")
    func onByDefault() throws {
        let suite = "dynamicglyph-still-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(AppPreferences.defaultRecognitionCuts.contains(.headerStillSkip))
        #expect(preferences.recognitionCuts.contains(.headerStillSkip))
        RecognitionEngineSelection.old.apply(to: preferences)
        #expect(!preferences.recognitionCuts.contains(.headerStillSkip))
        RecognitionEngineSelection.new.apply(to: preferences)
        #expect(preferences.recognitionCuts.contains(.headerStillSkip))
        // New as the build before it was a default stored it: a stored list
        // wins, so the session runs without the skip and Settings shows Custom.
        preferences.recognitionCuts = [.directPlanes, .lazyImage, .huntBand, .huntHalf]
        #expect(RecognitionEngineSelection(preferences) == .custom)
        #expect(!preferences.recognitionCuts.contains(.headerStillSkip))
        // A session that falls back to the Swift engine keeps it.
        #expect(RecognitionCut.swiftEngineCuts.contains(.headerStillSkip))
    }

    // MARK: - Skips and the reading issued again

    @Test("Still frames skip in a hack and outside, and issue the last read's reading at their own time")
    func stillFramesSkipAndReissue() async throws {
        let frame = try Self.frame(), meter = PowerMeter(), reads = ReadTimes()
        meter.reset()
        let reader = reader(meter: meter, reads: reads)
        reader.submit(frame.image, at: 0, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        #expect(reader.issuedReading(for: 0.0625, session: session)
                == .init(reading: Self.read.at(sourceTime: 0), reused: false))
        for time in [0.125, 0.25] {
            reader.submit(frame.image, at: time, session: session, inHack: true, topBand: frame.band)
            #expect(!reader.isReading)
            #expect(reader.issuedReading(for: time, session: session)
                    == .init(reading: Self.read.at(sourceTime: time), reused: true))
            #expect(reader.reading(for: time, session: session) == Self.read.at(sourceTime: time))
            // The issue holds the lane's 0.1-s cadence, as a read would: the
            // look between is neither read nor issued.
            reader.submit(frame.image, at: time + 0.0625, session: session, inHack: true, topBand: frame.band)
            #expect(reader.issuedReading(for: time + 0.0625, session: session)?.reading.sourceTime == time)
        }
        // Outside a hack at the outside cadence, then with a fresh header
        // required at the lane's: the same skip, counted outside.
        reader.submit(frame.image, at: 0.6875, session: session, headerInterval: 0.5, inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().headerSkippedStillOutside == 0 && !reader.isReading,
                "Under the outside interval since the last issue: held, neither read nor issued")
        reader.submit(frame.image, at: 0.75, session: session, headerInterval: 0.5, inHack: false, topBand: frame.band)
        #expect(reader.issuedReading(for: 0.75, session: session)?.reading.sourceTime == 0.75)
        reader.submit(frame.image, at: 0.875, session: session, inHack: false, requiresFreshHeader: true,
                      topBand: frame.band)
        #expect(reader.issuedReading(for: 0.875, session: session)
                == .init(reading: Self.read.at(sourceTime: 0.875), reused: true))
        let metrics = reader.snapshotMetrics()
        #expect(reads.values == [0] && metrics.submitted == 1)
        #expect(metrics.headerSkippedStillInHack == 2 && metrics.headerSkippedStillOutside == 2)
        #expect(metrics.headerSkippedUnchanged == 0, "The exact comparison is replaced, not run as well")
        let snapshot = meter.snapshot()
        #expect(snapshot.total(.headerStillInHack).count == 2 && snapshot.total(.headerStillOutside).count == 2)
        #expect(snapshot.total(.headerInHack).count == 1 && snapshot.total(.headerUnchanged).count == 0)
    }

    @Test("A change beyond the tolerance reads at the next look a read would take; one within it skips")
    func changeBeyondTolerance() async throws {
        let base = try Self.frame(), within = try Self.frame(level: 41)
        let beyond = try Self.frame(level: 42), text = try Self.frame(text: 1)
        let reads = ReadTimes(), reader = reader(reads: reads)
        reader.submit(base.image, at: 0, session: session, inHack: true, topBand: base.band)
        try await finish(reader)
        reader.submit(within.image, at: 0.125, session: session, inHack: true, topBand: within.band)
        #expect(reads.values == [0] && reader.issuedReading(for: 0.125, session: session)?.reused == true)
        // Within the cadence the issue holds, the change waits for the next
        // look, as it would after a read.
        reader.submit(beyond.image, at: 0.1875, session: session, inHack: true, topBand: beyond.band)
        #expect(reads.values == [0] && !reader.isReading)
        reader.submit(beyond.image, at: 0.25, session: session, inHack: true, topBand: beyond.band)
        try await finish(reader)
        #expect(reads.values == [0, 0.25])
        #expect(reader.issuedReading(for: 0.25, session: session)?.reused == false)
        // The anchor is now the changed frame: the original is a change too.
        reader.submit(text.image, at: 0.375, session: session, inHack: true, topBand: text.band)
        try await finish(reader)
        #expect(reads.values == [0, 0.25, 0.375])
    }

    @Test("A real read happens once the last one is a second old, however still the header is")
    func ageLimit() async throws {
        let frame = try Self.frame(), reads = ReadTimes(), reader = reader(reads: reads)
        reader.submit(frame.image, at: 0, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        for index in 1...7 {
            reader.submit(frame.image, at: Double(index) * 0.125, session: session, inHack: true, topBand: frame.band)
        }
        #expect(reads.values == [0] && reader.snapshotMetrics().headerSkippedStillInHack == 7)
        reader.submit(frame.image, at: 1.0, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        #expect(reads.values == [0, 1.0])
        reader.submit(frame.image, at: 1.125, session: session, inHack: true, topBand: frame.band)
        #expect(reads.values == [0, 1.0], "The new read is the anchor")
        #expect(reader.issuedReading(for: 1.125, session: session)?.reused == true)
    }

    @Test("With the cut, a still header is answered at exactly the frames a read answers without it")
    func sameFramesAsReads() async throws {
        let still = try Self.frame(), changed = try Self.frame(text: 1)
        // 20-Hz looks, whose float times space the lane's reads 0.1 or 0.15 s
        // apart; the header changes at 1.23 s.
        let times = (0...50).map { Double($0) * 0.05 }
        func answered(_ cut: Bool) async throws -> [Double] {
            let reads = ReadTimes(), reader = reader(still: cut, reads: reads)
            var answered: [Double] = []
            for time in times {
                let frame = time < 1.23 ? still : changed
                reader.submit(frame.image, at: time, session: session, inHack: true, topBand: frame.band)
                try await finish(reader)
                if reader.reading(for: time, session: session)?.sourceTime == time { answered.append(time) }
            }
            if cut {
                #expect(reads.values.count == 4, "The first read, the age limit, the change, its age limit: \(reads.values)")
            } else {
                #expect(reads.values == answered)
            }
            return answered
        }
        let off = try await answered(false), on = try await answered(true)
        #expect(off.count > 15 && on == off, "off \(off), on \(on)")
    }

    @Test("Another session or language, or an invalidation, reads again")
    func anchorIdentity() async throws {
        let frame = try Self.frame(), reads = ReadTimes()
        let languages = GameLanguageMemory(language: .english, isAutomatic: true)
        let reader = reader(languages: languages, reads: reads)
        let other = CaptureSessionID(rawValue: 2)
        var time = 0.0
        func look(_ session: CaptureSessionID) async throws {
            reader.submit(frame.image, at: time, session: session, inHack: true, topBand: frame.band)
            try await finish(reader)
            // Exact in binary, so each look keeps the lane's 0.1-s spacing.
            time += 0.125
        }
        try await look(session)
        try await look(other)
        try await look(other)
        #expect(reads.values.count == 2, "A new session reads, then its own anchor skips")
        languages.found(.simplifiedChinese)
        try await look(other)
        try await look(other)
        #expect(reads.values.count == 3)
        reader.invalidate()
        #expect(reader.issuedReading(for: time, session: other) == nil)
        try await look(other)
        try await look(other)
        #expect(reads.values.count == 4)
        reader.invalidatePhase()
        #expect(reader.issuedReading(for: time, session: other) == nil)
        try await look(other)
        try await look(other)
        #expect(reads.values.count == 5)
        #expect(reader.snapshotMetrics().headerSkippedStillInHack == 4)
    }

    @Test("While the anchor's read runs nothing is skipped or issued; once it returns, still frames reuse it")
    func anchorInFlight() async throws {
        let frame = try Self.frame(), gate = AsyncHeaderGate()
        defer { gate.signal() }
        let reader = reader(operation: { _, time in
            if time == 0 { await gate.wait() }
            return Self.read.at(sourceTime: time)
        })
        reader.submit(frame.image, at: 0, session: session, inHack: true, topBand: frame.band)
        reader.submit(frame.image, at: 0.1, session: session, inHack: true, topBand: frame.band)
        // The lane is busy: the schedule never asks, as without the cut.
        #expect(reader.snapshotMetrics().droppedBusy == 1 && reader.snapshotMetrics().headerSkippedStillInHack == 0)
        #expect(reader.issuedReading(for: 0.1, session: session) == nil)
        gate.signal()
        try await finish(reader)
        reader.submit(frame.image, at: 0.2, session: session, inHack: true, topBand: frame.band)
        #expect(reader.issuedReading(for: 0.2, session: session)
                == .init(reading: Self.read.at(sourceTime: 0.2), reused: true))
        #expect(reader.snapshotMetrics().submitted == 1)
    }

    @Test("A failed read leaves no anchor: the next still frame reads")
    func failureReads() async throws {
        let frame = try Self.frame(), reads = ReadTimes()
        let reader = reader(operation: { _, time in
            reads.append(time)
            if time == 0 { throw CocoaError(.fileReadUnknown) }
            return Self.read.at(sourceTime: time)
        })
        for time in [0, 0.1, 0.2] {
            reader.submit(frame.image, at: time, session: session, inHack: true, topBand: frame.band)
            try await finish(reader)
        }
        #expect(reads.values == [0, 0.1], "The read after the failure is the anchor the third look reuses")
        #expect(reader.snapshotMetrics().failed == 1 && reader.snapshotMetrics().headerSkippedStillInHack == 1)
    }

    @Test("A lazy frame is never rendered for the grid: without a top band it reads, with one it skips unrendered")
    func lazyFrame() async throws {
        let frame = try Self.frame(), renders = ReadTimes(), reads = ReadTimes()
        let reader = reader(reads: reads)
        let lazy = GameHeaderReader.LazyFrame(width: frame.image.width, height: frame.image.height,
                                              whole: { renders.append(-1); return frame.image }) { rect in
            renders.append(rect.minY)
            return frame.image.cropping(to: rect)
        }
        for time in [0, 0.125, 0.25] {
            reader.submit(lazy, at: time, session: session, inHack: true)
            try await finish(reader)
        }
        #expect(reads.values == [0, 0.125, 0.25], "No grid without the band: every read runs (fail open)")
        #expect(renders.values.count == 3, "Each admitted read renders the header once, and nothing else")
        reader.submit(lazy, at: 0.375, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        reader.submit(lazy, at: 0.5, session: session, inHack: true, topBand: frame.band)
        #expect(reads.values == [0, 0.125, 0.25, 0.375] && renders.values.count == 4, "A skip renders nothing")
        #expect(reader.issuedReading(for: 0.5, session: session)?.reused == true)
    }

    @Test("A queued command notice is read, never skipped, and leaves no anchor; panels still get the lane")
    func commandsAndPanels() async throws {
        let frame = try Self.frame(), reads = ReadTimes()
        let context = ResultReadContext(sessionID: session, hackID: 1, glyphs: ["xm"])
        let reader = GameHeaderReader(
            configuration: .init(skipsStillHeaders: true),
            headerOperation: { _, time in reads.append(time); return Self.read.at(sourceTime: time) },
            resultOperation: { _, context, time in .init(context: context, sourceTime: time, panelPresent: true) })
        reader.submit(frame.image, at: 0, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 0.1, session: session, inHack: true, topBand: frame.band)
        #expect(reads.values == [0])
        // The skipped look took no lane: a result read at the same time runs.
        reader.submit(frame.image, at: 0.1, session: session, resultContext: context, panelCandidate: true,
                      inHack: true, topBand: frame.band)
        try await finish(reader)
        #expect(reader.takeResult()?.evidence.sourceTime == 0.1)
        let commands = CommandNoticeCapture()
        try TestFixtures.requireScreenshots()
        let notice = try #require(ImageDecoder.cgImage(from: Data(contentsOf: try TestFixtures.url("simple", "png"))))
        try commands.observe(band: notice, at: 0.2)
        #expect(commands.queue.count == 1)
        reader.submit(frame.image, at: 0.2, session: session, commands: commands, inHack: true, topBand: frame.band)
        try await finish(reader)
        #expect(reads.values == [0, 0.2] && reader.takeCommand()?.0.sourceTime == 0.2)
        reader.submit(frame.image, at: 0.35, session: session, inHack: true, topBand: frame.band)
        try await finish(reader)
        #expect(reads.values == [0, 0.2, 0.35], "The command read is no anchor: the header is read again")
        #expect(reader.snapshotMetrics().headerSkippedStillInHack == 1)
    }

    @Test("Off, nothing changes: still in-hack frames are read at the cadence and outside ones skip without a reading")
    func offIsUnchanged() async throws {
        let frame = try Self.frame(), meter = PowerMeter(), reads = ReadTimes()
        meter.reset()
        let reader = reader(still: false, meter: meter, reads: reads)
        for index in 0..<6 {
            let time = Double(index) * 0.125
            reader.submit(frame.image, at: time, session: session, inHack: true, topBand: frame.band)
            try await finish(reader)
            #expect(reader.issuedReading(for: time, session: session)?.reused == false)
        }
        #expect(reads.values.count == 6)
        reader.submit(frame.image, at: 1.25, session: session, headerInterval: 0.5, inHack: false,
                      topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 1.75, session: session, headerInterval: 0.5, inHack: false, topBand: frame.band)
        #expect(reads.values.count == 7 && reader.snapshotMetrics().headerSkippedUnchanged == 1)
        #expect(reader.reading(for: 1.75, session: session) == nil, "The exact skip still issues nothing")
        let metrics = reader.snapshotMetrics(), snapshot = meter.snapshot()
        #expect(metrics.headerSkippedStillInHack == 0 && metrics.headerSkippedStillOutside == 0)
        #expect(snapshot.total(.headerStillInHack).count == 0 && snapshot.total(.headerStillOutside).count == 0)
    }

    @Test("The Power report shows still skips under the header rows only when the cut ran")
    func powerReport() throws {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp", cuts: [])
        #expect(!PowerReport.lines(meter.snapshot()).contains { $0.hasPrefix("still") })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.headerStillSkip])
        meter.count(.headerStillInHack, 5)
        meter.count(.headerStillOutside, 2)
        let lines = PowerReport.lines(meter.snapshot())
        let header = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerUnchanged.label) })
        let still = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerStillInHack.label) })
        #expect(still == header + 2, "Under the header rows and their note: \(lines)")
        #expect(lines.contains { $0.hasPrefix("still out") && $0.contains(" 2") })
        #expect(lines.allSatisfy { $0.count <= 42 }, "\(lines.filter { $0.count > 42 })")
        #expect(PowerMetric.headerStill.allSatisfy { $0.label.count <= 11 && !PowerMetric.topLevel.contains($0) })
    }
}

/// Times a stub was called at, from any thread.
final class ReadTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func append(_ time: Double) { lock.withLock { times.append(time) } }
    var values: [Double] { lock.withLock { times } }
}
