import CoreGraphics
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Outside-hack header content gate")
struct HeaderContentGateTests {
    private let session = CaptureSessionID(rawValue: 1)

    // Synthetic pixels exercise scheduling only; injected OCR makes no claims
    // about recognition quality in any language.
    private func frame(changedRow: Int? = nil) throws -> (image: CGImage, band: FrameTopBand) {
        let width = 64, height = 200
        var pixels = [UInt8](repeating: 20, count: width * height * 3)
        if let changedRow { pixels[(changedRow * width + 32) * 3] = 21 }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return (image, try ImageDecoder.topBand(image))
    }

    /// Nonuniform in x, y and channel, so a flipped/shifted crop cannot look
    /// unchanged merely because both sources contain a solid background.
    private func patternedFrame(width: Int = 67, height: Int = 213,
                                changedRow: Int? = nil) throws -> (image: CGImage, band: FrameTopBand) {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 3
                pixels[offset] = UInt8((y * 17 + x * 3) % 251)
                pixels[offset + 1] = UInt8((y * 29 + x * 5 + 1) % 251)
                pixels[offset + 2] = UInt8((y * 43 + x * 7 + 2) % 251)
            }
        }
        if let changedRow { pixels[(changedRow * width + width / 2) * 3 + 1] ^= 0xff }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return (image, try ImageDecoder.topBand(image))
    }

    private func actualHeaderPixels(_ image: CGImage) throws -> ColorImage {
        let crop = try #require(HeaderTextRecognizer().headerCrop(of: image))
        return try ImageDecoder.decodeColor(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    }

    private func evidence(_ reader: GameHeaderReader, at time: Double) -> FrameEvidence {
        FrameEvidence(sessionID: session, time: time, header: reader.reading(for: time, session: session),
                      slots: nil, shape: .unavailable, hasValidCalibration: false)
    }

    private func reader(configuration: GameHeaderReader.Configuration = .init(),
                        meter: PowerMeter? = nil) -> GameHeaderReader {
        GameHeaderReader(configuration: configuration, headerOperation: { _, time in
            HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
        }, meter: meter)
    }

    private func finish(_ reader: GameHeaderReader) async throws {
        for _ in 0..<200 {
            if !reader.isReading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("OCR lane did not finish")
    }

    @Test("Same outside header skips, keeps its original timestamp, and refreshes at one second")
    func unchangedAndRefresh() async throws {
        let frame = try frame(), meter = PowerMeter()
        meter.reset()
        let reader = reader(meter: meter)
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(!reader.isReading)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.reading(for: 0.3, session: session)?.sourceTime == 0)
        #expect(reader.reading(for: 0.5, session: session) == nil, "No fresh vote from a skipped look")
        reader.submit(frame.image, at: 0.999, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 1)
        reader.submit(frame.image, at: 1, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 2)
        #expect(reader.reading(for: 1, session: session)?.sourceTime == 1)
        #expect(meter.snapshot().total(.headerOutside).count == 2)
        #expect(meter.snapshot().total(.headerUnchanged).count == 2)
    }

    @Test("Current hack cues bypass identical outside pixels without changing cadence or inventing a phase")
    func requiresFreshHeader() async throws {
        let frame = try frame(), reader = reader()
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, requiresFreshHeader: true, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 2)
        #expect(reader.snapshotMetrics().headerInHackSubmitted == 0)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        #expect(reader.reading(for: 0.5, session: session)?.sourceTime == 0.5)
        #expect(reader.reading(for: 0.5, session: session)?.phase == .unknown)
        reader.submit(frame.image, at: 0.6, session: session, headerInterval: 0.5,
                      inHack: false, requiresFreshHeader: true, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 2, "Freshness bypass cannot accelerate OCR cadence")
        reader.submit(frame.image, at: 1, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 3, "Cue clears the outside baseline")
    }

    @Test("Every changed crop byte triggers the next eligible look; pixels below it do not")
    func changedHeader() async throws {
        let original = try frame(), below = try frame(changedRow: 30), changed = try frame(changedRow: 15)
        let reader = reader()
        reader.submit(original.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: original.band)
        try await finish(reader)
        reader.submit(below.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: below.band)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
        reader.submit(changed.image, at: 0.55, session: session, headerInterval: 0.5,
                      inHack: false, topBand: changed.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().submitted == 2, "A skip did not consume header cadence")
        #expect(reader.reading(for: 0.55, session: session)?.sourceTime == 0.55)
    }

    @Test("The existing CGImage fallback compares the same crop without another CI conversion")
    func cgImageFallback() async throws {
        let original = try frame(), changed = try frame(changedRow: 15), reader = reader()
        reader.submit(original.image, at: 0, session: session, headerInterval: 0.5, inHack: false)
        try await finish(reader)
        reader.submit(original.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: original.band)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
        reader.submit(changed.image, at: 0.55, session: session, headerInterval: 0.5, inHack: false)
        try await finish(reader)
        #expect(reader.snapshotMetrics().submitted == 2)
    }

    @Test("Fractional crop edges and alternating pixel sources match the real recognizer crop")
    func fractionalCropEdges() async throws {
        // At height 213 the unchanged production fractions give y=12.78
        // through 22.152: integral crop rows 12...22, excluding 11 and 23.
        let original = try patternedFrame()
        let actual = try actualHeaderPixels(original.image)
        #expect(actual.width == 67 && actual.height == 11)
        let first = 12, last = 22, stride = original.image.width * 3
        let bandPixels = Array(original.band.image.pixels[(first * stride)..<((last + 1) * stride)])
        #expect(bandPixels == actual.pixels, "Decoded band and actual OCR crop have identical row order and RGB")
        for row in [first - 1, first, last, last + 1] {
            let changed = try patternedFrame(changedRow: row)
            let changedActual = try actualHeaderPixels(changed.image)
            let included = row >= first && row <= last
            #expect((changedActual.pixels != actual.pixels) == included,
                    "The actual HeaderTextRecognizer crop is the boundary oracle")
            for startsWithBand in [false, true] {
                let reader = reader()
                reader.submit(original.image, at: 0, session: session, headerInterval: 0.5,
                              inHack: false, topBand: startsWithBand ? original.band : nil)
                try await finish(reader)
                reader.submit(original.image, at: 0.5, session: session, headerInterval: 0.5,
                              inHack: false, topBand: startsWithBand ? nil : original.band)
                reader.submit(original.image, at: 0.52, session: session, headerInterval: 0.5,
                              inHack: false, topBand: startsWithBand ? original.band : nil)
                #expect(reader.snapshotMetrics().headerSkippedUnchanged == 2)
                reader.submit(changed.image, at: 0.55, session: session, headerInterval: 0.5,
                              inHack: false, topBand: startsWithBand ? nil : changed.band)
                try await finish(reader)
                #expect(reader.snapshotMetrics().submitted == (included ? 2 : 1))
                #expect(reader.snapshotMetrics().headerSkippedUnchanged == (included ? 2 : 3))
            }
        }
    }

    @Test("Frame width or height changes force reading even with an identical header payload")
    func dimensionChanges() async throws {
        let original = try patternedFrame()
        for (width, height) in [(68, 213), (67, 214)] {
            let resized = try patternedFrame(width: width, height: height)
            if width == original.image.width {
                let originalCrop = try actualHeaderPixels(original.image)
                let resizedCrop = try actualHeaderPixels(resized.image)
                #expect(originalCrop.pixels == resizedCrop.pixels,
                        "This height change preserves every cropped byte: frame height alone must invalidate reuse")
            }
            let reader = reader()
            reader.submit(original.image, at: 0, session: session, headerInterval: 0.5,
                          inHack: false, topBand: original.band)
            try await finish(reader)
            reader.submit(resized.image, at: 0.5, session: session, headerInterval: 0.5,
                          inHack: false, topBand: resized.band)
            try await finish(reader)
            #expect(reader.snapshotMetrics().submitted == 2)
            #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        }
    }

    @Test("Identical in-hack headers retain normal and constrained cadence")
    func inHackCadence() async throws {
        let frame = try frame()
        for constrained in [false, true] {
            let reader = reader(), interval = constrained ? 0.2 : 0.1
            for index in 0..<6 {
                reader.submit(frame.image, at: Double(index) * (interval + 0.001), session: session,
                              headerInterval: interval, constrained: constrained,
                              inHack: true, topBand: frame.band)
                try await finish(reader)
            }
            #expect(reader.snapshotMetrics().headerInHackSubmitted == 6)
            #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        }
    }

    @Test("Constrained outside refresh is not doubled again; quiet and comparison-off retain their policy")
    func policy() async throws {
        let frame = try frame(), reader = reader()
        for time in [0.0, 1.0] {
            reader.submit(frame.image, at: time, session: session, headerInterval: 1,
                          constrained: true, inHack: false, topBand: frame.band)
            try await finish(reader)
        }
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 2)
        reader.submit(frame.image, at: 2, session: session, readsHeader: false, inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 2, "Quiet mode must not be woken for refresh")
        let comparisonOff = self.reader(configuration: .init(skipsUnchangedHeaders: false))
        for time in [0.0, 0.5] {
            comparisonOff.submit(frame.image, at: time, session: session, headerInterval: 0.5,
                                 inHack: false, topBand: frame.band)
            try await finish(comparisonOff)
        }
        #expect(comparisonOff.snapshotMetrics().submitted == 2)
        #expect(comparisonOff.snapshotMetrics().headerSkippedUnchanged == 0)
    }

    @Test("Unchanged suppression consumes none of the result, gear, portal or command lane")
    func sharedLane() async throws {
        let frame = try frame()
        let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)
        let context = ResultReadContext(sessionID: session, hackID: 1, glyphs: ["xm"])
        let reader = GameHeaderReader(
            headerOperation: { _, time in .init(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            resultOperation: { _, context, time in .init(context: context, sourceTime: time, panelPresent: true) },
            gearOperation: { _, bounds, time in .init(sourceTime: time, stage: .bonus, bounds: bounds) },
            portalOperation: { _, time in .init(sourceTime: time, resonators: [8, 8], unreadSlots: 6, badgeHue: 259) })
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
        // Same timestamp as the skipped look: it did not occupy the shared lane.
        reader.submit(frame.image, at: 0.5, session: session, resultContext: context, panelCandidate: true,
                      headerInterval: 0.5, inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.takeResult()?.evidence.sourceTime == 0.5)
        reader.submit(frame.image, at: 0.7, session: session, gearBounds: bounds,
                      headerInterval: 0.5, inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.takeGear()?.evidence.sourceTime == 0.7)
        reader.submit(frame.image, at: 0.9, session: session, portalCandidate: true,
                      headerInterval: 0.5, inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.takePortal()?.sourceTime == 0.9)
        let commands = CommandNoticeCapture()
        try TestFixtures.requireScreenshots()
        let url = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "simple", withExtension: "png"))
        let notice = try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
        try commands.observe(band: notice, at: 1.1)
        #expect(commands.queue.count == 1)
        // Command stays eligible even when no header-only read is allowed.
        reader.submit(frame.image, at: 1.1, session: session, commands: commands,
                      readsHeader: false, headerInterval: 0.5, inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.takeCommand()?.0.sourceTime == 1.1)
        #expect(commands.queue.isEmpty)
        #expect(reader.snapshotMetrics().resultSubmitted == 1)
        #expect(reader.snapshotMetrics().gearSubmitted == 1)
        #expect(reader.snapshotMetrics().portalSubmitted == 1)
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 2, "Command's header is counted too")
    }

    @Test("Invalidation and concurrent looks never open another OCR lane or refill an old signature")
    func singleFlight() async throws {
        let frame = try frame(), gate = AsyncHeaderGate()
        defer { gate.signal() }
        let reader = GameHeaderReader(headerOperation: { _, time in
            await gate.wait()
            return .init(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
        })
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
        }
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == 20)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        reader.invalidate()
        gate.signal()
        try await finish(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        reader.submit(frame.image, at: 0.6, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 2)
        gate.signal()
        try await finish(reader)
    }

    @Test("Phase-only invalidation clears identical outside pixels without opening another OCR lane",
          arguments: [false, true])
    func phaseEpochClearsBaseline(_ inFlight: Bool) async throws {
        let frame = try patternedFrame(), gate = AsyncHeaderGate()
        defer { gate.signal() }
        let reader = GameHeaderReader(headerOperation: { _, time in
            if inFlight && time == 100 { await gate.wait() }
            return .init(phase: time == 100 ? .unknown : .presenting, matchedText: "",
                         confidence: 1, sourceTime: time)
        })
        reader.submit(frame.image, at: 100, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        if !inFlight { try await finish(reader) }
        reader.invalidatePhase()
        #expect(reader.reading(for: 100, session: session) == nil)
        if inFlight {
            #expect(reader.isReading)
            reader.submit(frame.image, at: 100.5, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
            #expect(reader.snapshotMetrics().submitted == 1)
            #expect(reader.snapshotMetrics().droppedBusy == 1)
            gate.signal()
            try await finish(reader)
            #expect(reader.snapshotMetrics().staleCompletions == 1)
        }
        // The new epoch has caught the old numeric clock. Identity/age/pixels
        // alone would all permit suppression of this first fresh phase read.
        reader.submit(frame.image, at: 100.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().submitted == 2)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        #expect(reader.reading(for: 100.5, session: session)?.sourceTime == 100.5)
        #expect(reader.reading(for: 100.5, session: session)?.phase == .presenting)
        // Only the baseline was cleared: ordinary bounded outside suppression
        // resumes on the new epoch without a cadence change or restamping.
        reader.submit(frame.image, at: 101, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 2)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
        #expect(reader.reading(for: 101, session: session) == nil)
    }

    @Test("Hack evidence during blocked outside OCR prevents a late baseline refill", arguments: [false, true])
    func inHackDuringOutsideRead(_ inHack: Bool) async throws {
        let frame = try patternedFrame(), gate = AsyncHeaderGate()
        defer { gate.signal() }
        let reader = GameHeaderReader(headerOperation: { _, time in
            if time == 0 { await gate.wait() }
            return .init(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
        })
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        reader.submit(frame.image, at: 0.2, session: session, headerInterval: 0.1,
                      inHack: inHack, requiresFreshHeader: !inHack, topBand: frame.band)
        reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == 2)
        gate.signal()
        try await finish(reader)
        #expect(reader.reading(for: 0.3, session: session)?.sourceTime == 0)
        reader.submit(frame.image, at: 0.6, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().submitted == 2,
                "Completion must not restore the baseline cleared by hack evidence")
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
        #expect(reader.reading(for: 0.6, session: session)?.sourceTime == 0.6)
        reader.submit(frame.image, at: 1.1, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 1)
    }

    @Test("A first known reader header enters the real tracker's correct phase",
          arguments: [(GamePhase.command, TrackingState.command), (.presenting, .presenting),
                      (.input, .input), (.completed, .completed)])
    func firstKnownHeaderTracksPhase(_ sample: (GamePhase, TrackingState)) async throws {
        let frame = try frame()
        let reader = GameHeaderReader(headerOperation: { _, time in
            .init(phase: sample.0, matchedText: sample.0.rawValue, confidence: 1, sourceTime: time)
        })
        var tracker = PresentationTracker(sessionID: session)
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        let first = evidence(reader, at: 0.05)
        let events = tracker.accept(first)
        #expect(first.header?.sourceTime == 0)
        #expect(tracker.state == sample.1 && tracker.phaseSource == .headerText)
        #expect(tracker.lastPhaseTime == 0, "The tracker sees the source frame, not completion/application time")
        #expect(events.contains { $0.kind == .hackStarted } == (sample.0 == .presenting))
        let repeated = evidence(reader, at: 0.2)
        tracker.accept(repeated)
        #expect(repeated.header?.sourceTime == 0)
        #expect(tracker.lastPhaseTime == 0, "Reusing the reading does not manufacture a new phase timestamp")
    }

    @Test("Unknown-first unchanged headers may defer real tracker entry from 0.5s to the 1s refresh")
    func unknownFirstTrackerRefresh() async throws {
        let frame = try frame()
        for skipsUnchanged in [false, true] {
            let reader = GameHeaderReader(configuration: .init(skipsUnchangedHeaders: skipsUnchanged),
                headerOperation: { _, time in
                    let phase: GamePhase = time == 0 ? .unknown : .presenting
                    return .init(phase: phase, matchedText: phase.rawValue, confidence: 1, sourceTime: time)
                })
            var tracker = PresentationTracker(sessionID: session)
            reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
            try await finish(reader)
            tracker.accept(evidence(reader, at: 0.05))
            #expect(tracker.state == .inactive && tracker.lastPhaseTime == nil)
            reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
            try await finish(reader)
            let halfSecond = evidence(reader, at: 0.55)
            tracker.accept(halfSecond)
            if skipsUnchanged {
                #expect(halfSecond.header == nil, "Expired unknown OCR is not refreshed by the skipped look")
                #expect(tracker.state == .inactive && tracker.lastPhaseTime == nil)
                reader.submit(frame.image, at: 0.999, session: session, headerInterval: 0.5,
                              inHack: false, topBand: frame.band)
                #expect(reader.snapshotMetrics().submitted == 1)
                reader.submit(frame.image, at: 1, session: session, headerInterval: 0.5,
                              inHack: false, topBand: frame.band)
                try await finish(reader)
                let refreshed = evidence(reader, at: 1.05)
                let events = tracker.accept(refreshed)
                #expect(refreshed.header?.sourceTime == 1)
                #expect(events.contains { $0.kind == .hackStarted })
            } else {
                #expect(halfSecond.header?.sourceTime == 0.5)
            }
            let firstKnownSource = skipsUnchanged ? 1.0 : 0.5
            #expect(tracker.state == .presenting && tracker.phaseSource == .headerText)
            #expect(tracker.hackID == 1 && tracker.lastPhaseTime == firstKnownSource)
            tracker.accept(evidence(reader, at: firstKnownSource + 0.2))
            #expect(tracker.lastPhaseTime == firstKnownSource)
            #expect(reader.snapshotMetrics().submitted == 2)
        }
    }

    @Test("Real indicator and timer cues bypass unchanged unknown OCR at the in-hack cadence",
          arguments: [false, true])
    func independentHackCueBypassesUnknownHeader(_ constrained: Bool) async throws {
        // LiveGlyphOutput constructs its reader internally, without an OCR
        // injection point. Exercise its real tracker -> inHack -> production
        // interval -> reader path here instead; no production test hook added.
        // The identical pixels never become a fake known OCR header.
        let frame = try patternedFrame(), reader = reader()
        var tracker = PresentationTracker(sessionID: session)
        func inHack(at time: Double) -> Bool {
            // The tracker-owned portion of LiveGlyphOutput.isInHack(at:).
            // No CommandScreenWatch participates in this indicator/timer case.
            tracker.state == .presenting || tracker.state == .input || tracker.state == .command
                || tracker.state == .interrupted && time - (tracker.lastPhaseTime ?? -.infinity) < 5
        }
        func strip(_ highlight: Int?, timer: Bool = false) -> SlotStripReading {
            .init(slotCount: 4, highlightedIndex: highlight,
                  markerCentersX: [0.35, 0.45, 0.55, 0.65], hasInputTimerBar: timer)
        }
        let noStroke = ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: [])
        let outsideInterval = try #require(AnalysisRateController.headerInterval(
            mode: .active, inHack: false, constrained: constrained))
        reader.submit(frame.image, at: 0, session: session, headerInterval: outsideInterval,
                      constrained: constrained, inHack: false, topBand: frame.band)
        try await finish(reader)
        tracker.accept(evidence(reader, at: 0.05))
        #expect(tracker.state == .inactive && tracker.lastPhaseTime == nil)

        let cues: [(Double, Int?)] = [(0.5, nil), (0.55, nil), (0.6, 0)]
        for (time, highlight) in cues {
            // As in LiveGlyphOutput, submit using the previous tracker state,
            // then let this frame's independent slot evidence update it.
            let wasInHack = inHack(at: time)
            #expect(!wasInHack)
            reader.submit(frame.image, at: time, session: session, headerInterval: outsideInterval,
                          constrained: constrained, inHack: wasInHack, topBand: frame.band)
            try await finish(reader)
            let cueEvidence = FrameEvidence(sessionID: session, time: time,
                header: reader.reading(for: time, session: session), slots: strip(highlight),
                shape: noStroke, hasValidCalibration: true)
            #expect(cueEvidence.header == nil, "The original unknown read has expired, not gained a fresh vote")
            tracker.accept(cueEvidence)
        }
        #expect(tracker.state == .presenting && tracker.phaseSource == .indicatorTransition)
        #expect(tracker.hackID == 1 && tracker.lastPhaseTime == nil)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == (constrained ? 0 : 3))

        let nextLook = 0.65, cueInHack = inHack(at: nextLook)
        #expect(cueInHack, "A real indicator transition, not fabricated OCR, selects in-hack policy")
        let interval = try #require(AnalysisRateController.headerInterval(
            mode: .active, inHack: cueInHack, constrained: constrained))
        #expect(interval == (constrained ? 0.2 : 0.1))
        reader.submit(frame.image, at: nextLook, session: session, headerInterval: interval,
                      constrained: constrained, inHack: cueInHack, topBand: frame.band)
        try await finish(reader)
        let cueRead = try #require(reader.reading(for: nextLook, session: session))
        #expect(cueRead.phase == .unknown && cueRead.matchedText.isEmpty && cueRead.confidence == 0)
        #expect(cueRead.sourceTime == nextLook && reader.snapshotMetrics().submitted == 2,
                "Next eligible in-hack look refreshes identical pixels before the 1s outside refresh")
        tracker.accept(FrameEvidence(sessionID: session, time: nextLook, header: cueRead,
            slots: strip(0), shape: noStroke, hasValidCalibration: true))
        #expect(tracker.state == .presenting && tracker.phaseSource == .indicatorTransition)
        #expect(tracker.lastPhaseTime == nil, "Unknown OCR did not establish a text phase")

        reader.submit(frame.image, at: nextLook + interval - 0.01, session: session,
                      headerInterval: interval, constrained: constrained,
                      inHack: inHack(at: nextLook + interval - 0.01), topBand: frame.band)
        #expect(reader.snapshotMetrics().submitted == 2, "Bypass still respects the existing 0.1/0.2s cadence")
        let timerTime = nextLook + interval + 0.001
        reader.submit(frame.image, at: timerTime, session: session, headerInterval: interval,
                      constrained: constrained, inHack: inHack(at: timerTime), topBand: frame.band)
        try await finish(reader)
        let timerRead = try #require(reader.reading(for: timerTime, session: session))
        #expect(timerRead.phase == .unknown && timerRead.sourceTime == timerTime)
        tracker.accept(FrameEvidence(sessionID: session, time: timerTime, header: timerRead,
            slots: strip(0, timer: true), shape: noStroke, hasValidCalibration: true))
        #expect(tracker.state == .input && tracker.phaseSource == .inputTimer)
        #expect(tracker.lastPhaseTime == timerTime, "This timestamp comes from the independent timer, not OCR")
        let inputTime = timerTime + interval + 0.001
        reader.submit(frame.image, at: inputTime, session: session, headerInterval: interval,
                      constrained: constrained, inHack: inHack(at: inputTime), topBand: frame.band)
        try await finish(reader)
        let inputRead = try #require(reader.reading(for: inputTime, session: session))
        #expect(inputRead.phase == .unknown && inputRead.sourceTime == inputTime)
        #expect(reader.snapshotMetrics().headerInHackSubmitted == 3)
        #expect(reader.snapshotMetrics().headerOutsideSubmitted == 1)
    }

    @Test("Concurrent identical eligible looks count every skip without submitting OCR")
    func concurrentSkipCounts() async throws {
        let frame = try frame(), reader = reader()
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
        }
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 20)
        #expect(!reader.isReading)
    }

    @Test("Session, language and backwards-clock changes cannot reuse the old signature")
    func baselineIdentity() async throws {
        let frame = try frame()
        let languages = GameLanguageMemory(language: .english, isAutomatic: true)
        let reader = reader(configuration: .init(languages: languages))
        reader.submit(frame.image, at: 0, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        languages.found(.simplifiedChinese)
        reader.submit(frame.image, at: 0.5, session: session, headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 1, session: CaptureSessionID(rawValue: 2), headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        reader.submit(frame.image, at: 0.5, session: CaptureSessionID(rawValue: 2), headerInterval: 0.5,
                      inHack: false, topBand: frame.band)
        try await finish(reader)
        #expect(reader.snapshotMetrics().submitted == 4)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
    }

    @Test("A failed header read does not suppress a retry on identical pixels")
    func failureRetries() async throws {
        let frame = try frame()
        let reader = GameHeaderReader(headerOperation: { _, _ in throw CocoaError(.fileReadUnknown) })
        for time in [0.0, 0.5] {
            reader.submit(frame.image, at: time, session: session, headerInterval: 0.5,
                          inHack: false, topBand: frame.band)
            try await finish(reader)
        }
        #expect(reader.snapshotMetrics().failed == 2)
        #expect(reader.snapshotMetrics().headerSkippedUnchanged == 0)
    }
}

private final class TestBundleMarker: NSObject {}

/// One-shot asynchronous gate: OCR tasks suspend rather than blocking a
/// cooperative executor thread. Synchronous signal is safe in test cleanup.
final class AsyncHeaderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func signal() {
        let pending = lock.withLock {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}
