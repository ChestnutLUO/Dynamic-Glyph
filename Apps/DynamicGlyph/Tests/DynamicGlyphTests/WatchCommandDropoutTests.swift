import CoreVideo
import Foundation
import GlyphRecognition
import Testing

@Suite("Command drawing watch coverage", .serialized)
struct WatchCommandDropoutTests {
    @Test("Drawn commands keep an armed watch on current evidence through a short dropout, then release",
          arguments: [false, true], [false, true])
    func drawnCommand(lowPower: Bool, noticeSupport: Bool) throws {
        let harness = try WatchReproductionHarness(lowPower: lowPower) { _, time in
            let supporting = noticeSupport ? time < 0.5 : time <= 4 && !(2.5..<2.8).contains(time)
            return WatchReproductionHarness.header(supporting ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let emptyCommand = try Frames.recorded("field-00381")
        let drawn = try commandDrawing(notice: false)
        let notice = try commandDrawing(notice: true)
        try harness.play(emptyCommand, at: 0)
        for index in 1...318 {
            let time = Double(index) / 60
            let showsNotice = noticeSupport && time <= 4 && !(2.5..<2.8).contains(time)
            try harness.play(showsNotice ? notice : drawn, at: time)
        }
        harness.report("drawn command lowPower=\(lowPower) noticeSupport=\(noticeSupport); support stops at4, dropout2.5..<2.8")
        let rows = try harness.finish()
        let during = harness.probes.filter { (1.7...4.0).contains($0.time) }
        #expect(!during.isEmpty && during.allSatisfy { $0.reasons.has(.commandWatch) && $0.mode?.ratePerSecond == 20 })
        #expect(during.allSatisfy { !$0.reasons.has(.calibration) && !$0.reasons.has(.slots) && !$0.reasons.has(.timer) },
                "The first empty array must not be revalidated during the real recorded stroke")
        let before = try #require(harness.probes.first { abs($0.time - 2) < 0.001 })
        let after = try #require(harness.probes.first { abs($0.time - 4) < 0.001 })
        #expect(after.commandBandSamples - before.commandBandSamples == 40,
                "Every 20-Hz command band is inspected, including the sub-flicker dropout")
        #expect(after.analysedLastSecond == 20)
        let dropout = try #require(harness.probes.first { abs($0.time - 2.7) < 0.001 })
        #expect(dropout.reasons.has(.commandWatch), "A 300-ms evidence dropout must not interrupt/cancel coverage")
        let released = try #require(harness.probes.first { $0.time > 4.1 && !$0.reasons.has(.commandWatch) })
        #expect(released.time <= 4.75, "A retained fit/stroke must not keep the watch alive after current support ends")
        let strokes = rows.filter { (1.7...4.0).contains(WatchReproductionHarness.time($0)) }
        #expect(!strokes.isEmpty && strokes.allSatisfy {
            $0["calibration"] != nil && $0["slotCount"] == nil && $0["state"] as? String != "noStroke"
        })
        let tail = rows.filter { WatchReproductionHarness.time($0) >= 4.8 }
        #expect(!tail.isEmpty && tail.allSatisfy { $0["calibration"] != nil },
                "Releasing command watch must not discard useful recognition geometry")
    }

    /// The contrast to `drawnCommand`: support (command header reads) again
    /// stops at 4 and every later read recognises nothing, but this window's
    /// notice (the recorded SIMPLE crop, 3.5..<4.0) has been read, so those
    /// reads are no evidence (S8b). The watch keeps support on the cached fit
    /// within `leave` of the last command evidence, past drawnCommand's 4.75
    /// release, until the presented hack binds the confirmed notice.
    @Test("After a read notice, header reads that recognise nothing keep a drawn command watched into the hack",
          arguments: [false, true])
    func drawnCommandHeldAfterReadNotice(lowPower: Bool) throws {
        let nothingRead = WatchReproductionValues<Double>()
        let harness = try WatchReproductionHarness(lowPower: lowPower) { _, time in
            if time <= 4 { return WatchReproductionHarness.header(.command, at: time) }
            if time >= 5.5 { return WatchReproductionHarness.header(.presenting, at: time) }
            nothingRead.append(time)
            return WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        let emptyCommand = try Frames.recorded("field-00381")
        let drawn = try commandDrawing(notice: false)
        let notice = try NoticeDrawingFrame.make("simple")
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        try harness.play(emptyCommand, at: 0)
        for index in 1...370 {
            let frame = (210..<240).contains(index) ? notice : index < 330 ? drawn : index < 350 ? empty : glyph
            try harness.play(frame, at: Double(index) / 60)
        }
        harness.report("drawn command lowPower=\(lowPower); notice read 3.5..<4, support stops at 4, nothing read to 5.5")
        _ = try harness.finish()
        let text = try String(contentsOf: harness.directory.url.appendingPathComponent("commands.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(nothingRead.values.filter { $0 < 5.5 }.count >= 5,
                "Precondition: reads that recognise nothing after support stops: \(nothingRead.values)")
        #expect(rows.filter { $0["kind"] as? String == "notice" && $0["notice"] as? String == "simple" }.count >= 2,
                "Precondition: the recorded notice was read in the window")
        #expect(!rows.contains { $0["kind"] as? String == "dropped" })
        // drawnCommand releases by 4.75; here the watch keeps support.
        let during = harness.probes.filter { (1.7...5.4).contains($0.time) }
        let unwatched = during.filter { !$0.reasons.has(.commandWatch) || $0.mode?.ratePerSecond != 20 }.map(\.time)
        #expect(!during.isEmpty && unwatched.isEmpty, "Lost at \(unwatched)")
        #expect(during.allSatisfy { !$0.reasons.has(.calibration) },
                "The drawn stroke must not revalidate the array: this is the cached-fit path")
        let bound = try #require(rows.first { $0["kind"] as? String == "bound" }, "Precondition: the hack started")
        let presentation = try #require(bound["presentation"] as? [String: Any])
        #expect(presentation["status"] as? String == "confirmed", "No interrupt after the notice: \(bound)")
        #expect(presentation["lastObserved"] as? String == "simple")
        #expect((bound["gear"] as? [String: Any])?["status"] as? String == "noCommandObserved",
                "No coverage-loss event anywhere in the window: \(bound)")
    }

    /// Test-only command-context composite: real field Glyph stroke pixels
    /// (which block empty-array revalidation), with the presentation strip and
    /// timer/notice band removed. Header votes provide command context. This is
    /// NOT claimed to be a recorded full-frame command-drawing capture.
    /// The optional synthetic bordered notice exercises CURRENT box detection,
    /// not OCR accuracy; it carries no player/location data and is not saved.
    private func commandDrawing(notice: Bool) throws -> CVPixelBuffer {
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
        if notice {
            let left = width / 5, right = width * 4 / 5
            let y0 = Int(Double(height) * 0.195), y1 = Int(Double(height) * 0.245)
            for y in y0...y1 {
                for x in left...right where y < y0 + 3 || y > y1 - 3 || x < left + 3 || x > right - 3 {
                    luma[y * stride + x] = 220
                }
            }
        }
        return buffer
    }
}
