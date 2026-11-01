import CoreGraphics
import Testing
import GlyphRecognitionImages
@testable import GlyphRecognition

@Suite("Input check display")
struct InputCheckDisplayTests {
    private func model(_ verdict: InputCheckVerdict?, session: UInt64 = 1,
                       hack: Int = 1) -> GlyphDisplaySnapshot {
        let result = verdict.map {
            InputCheckResult(sessionID: CaptureSessionID(rawValue: session), hackID: hack,
                slotIndex: 0, attemptID: 1, expectedGlyph: GlyphID("alpha"), verdict: $0,
                reason: nil, sourceTime: 10, startTime: 9, liftTime: 9.5, samples: [])
        }
        return GlyphDisplaySnapshot(captureSessionID: CaptureSessionID(rawValue: 1), hackID: 1,
            revision: 5, liveness: .live, state: .input, phaseSource: .inputTimer,
            acceptance: .trackingSequence, sourceFrameTime: 10, evidenceArrivalUptime: 100,
            expectedSlotCount: 2, slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("alpha")),
                                          SlotObservation(index: 1, status: .confirmed, glyph: GlyphID("alpha"))],
            currentSlotIndex: nil, inputSlotIndex: 1, slotCountConflict: false, isFrozen: true,
            provisionalGlyph: nil, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "", inputChecks: result.map { [$0] } ?? [],
            inputCheckRevision: verdict == nil ? 0 : 1)
    }

    @Test("Verdicts change the snapshot revision, PiP render key and rendered pixels")
    func redraw() throws {
        let blank = model(nil)
        let table = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!])
        func render(_ snapshot: GlyphDisplaySnapshot) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 384 * 96 * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 384, height: 96,
                    bitsPerComponent: 8, bytesPerRow: 384 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                GlyphDisplayRenderer(table: table).draw(snapshot, in: context,
                    size: CGSize(width: 384, height: 96), atUptime: 100)
            }
            return pixels
        }
        let baseline = try render(blank)
        for verdict: InputCheckVerdict in [.matched, .differs, .unavailable] {
            let checked = model(verdict)
            #expect(checked.revision > blank.revision)
            #expect(checked.inputCheckRenderKey(atUptime: 100) != blank.inputCheckRenderKey(atUptime: 100))
            #expect(try render(checked) != baseline)
            #expect(checked.inputCheckDisplay(for: 0, atUptime: 100)?.verdict == verdict)
            #expect(checked.inputCheckDisplay(for: 1, atUptime: 100) == nil)
        }
    }

    @Test("A brief check mark expires without expiring its historical verdict")
    func expiry() {
        let checked = model(.matched)
        #expect(checked.inputCheckDisplay(for: 0, atUptime: 100)?.showsSymbol == true)
        #expect(checked.inputCheckDisplay(for: 0, atUptime: 102)?.showsSymbol == false)
        #expect(checked.inputCheckRenderKey(atUptime: 100) != checked.inputCheckRenderKey(atUptime: 102))
        #expect(checked.inputCheckDisplay(for: 0, atUptime: 102)?.verdict == .matched)
        #expect(model(.differs).inputCheckDisplay(for: 0, atUptime: 102)?.showsSymbol == true)
    }

    @Test("Results from another session or hack are never rendered")
    func ownership() {
        #expect(model(.differs, session: 2).inputCheckDisplay(for: 0, atUptime: 100) == nil)
        #expect(model(.differs, hack: 2).inputCheckDisplay(for: 0, atUptime: 100) == nil)
    }
}
