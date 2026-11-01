import CoreGraphics
import Foundation
import ImageIO
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Result evidence and OCR ownership")
struct ResultEvidenceTests {
    func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 562, height: 1218,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 562, height: 1218))
        return try #require(context.makeImage())
    }

    @Test("Result JPEGs and crop metadata are finished before export without video")
    func evidence() throws {
        let temporary = try TemporaryDirectory("result-evidence")
        let writer = try ResultEvidenceWriter(directory: temporary.url)
        #expect(writer.enqueue(try image(), hackID: 2, sourceTime: 12.5, decision: true) == nil)
        writer.finish()
        let log = try String(contentsOf: temporary.url.appendingPathComponent("result-frames.jsonl"), encoding: .utf8)
        let row = try #require(JSONSerialization.jsonObject(with: Data(log.utf8)) as? [String: Any])
        #expect(row["status"] as? String == "saved")
        #expect(row["sourceTime"] as? Double == 12.5)
        #expect(row["sourceHeight"] as? Int == 1218)
        let file = try #require(row["file"] as? String)
        let source = try #require(CGImageSourceCreateWithURL(temporary.url.appendingPathComponent(file) as CFURL, nil))
        let saved = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(saved.width == 562 && saved.height < 1218)
    }

    @Test("Failed image saves are explicit in the evidence manifest")
    func failedSave() throws {
        let temporary = try TemporaryDirectory("result-failure")
        let writer = try ResultEvidenceWriter(directory: temporary.url)
        try FileManager.default.createDirectory(at: temporary.url.appendingPathComponent("result-2-12.500000.jpg"),
                                               withIntermediateDirectories: true)
        #expect(writer.enqueue(try image(), hackID: 2, sourceTime: 12.5, decision: true) == nil)
        writer.finish()
        let log = try String(contentsOf: temporary.url.appendingPathComponent("result-frames.jsonl"), encoding: .utf8)
        #expect(log.contains("failed"))
    }

    @Test("Invalidation rejects late completion and never opens a second OCR lane")
    func lateCompletion() async throws {
        let gate = DispatchSemaphore(value: 0)
        let reader = GameHeaderReader(headerOperation: { _, time in
            gate.wait()
            return HeaderReading(phase: .input, matchedText: "GO!", confidence: 1, sourceTime: time)
        })
        let frame = try image(), session = CaptureSessionID(rawValue: 1)
        reader.submit(frame, at: 1, session: session)
        reader.invalidate()
        reader.submit(frame, at: 1.2, session: session)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == 1)
        gate.signal()
        for _ in 0..<100 {
            if reader.snapshotMetrics().staleCompletions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.reading(for: 1.1, session: session) == nil)
    }

    @Test("Result OCR owns its original hack and logging-off retains no screenshot")
    func resultContext() async throws {
        let gate = DispatchSemaphore(value: 0)
        let session = CaptureSessionID(rawValue: 1)
        let first = ResultReadContext(sessionID: session, hackID: 1, glyphs: ["xm"])
        let next = ResultReadContext(sessionID: session, hackID: 2, glyphs: ["old"])
        let reader = GameHeaderReader(resultOperation: { _, context, time in
            gate.wait()
            return ResultFrameEvidence(context: context, sourceTime: time, panelPresent: true)
        })
        let frame = try image()
        reader.submit(frame, at: 1, session: session, resultContext: first, panelCandidate: true)
        reader.submit(frame, at: 1.2, session: session, resultContext: next, panelCandidate: true)
        gate.signal()
        for _ in 0..<100 {
            if reader.snapshotMetrics().staleCompletions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.takeResult() == nil)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        let fresh = GameHeaderReader(resultOperation: { _, context, time in
            ResultFrameEvidence(context: context, sourceTime: time, panelPresent: true)
        })
        fresh.submit(frame, at: 2, session: session, resultContext: next, panelCandidate: true, keepResultImage: false)
        for _ in 0..<100 {
            if fresh.snapshotMetrics().resultCompleted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        fresh.submit(frame, at: 2.2, session: session, resultContext: next, panelCandidate: true)
        #expect(fresh.snapshotMetrics().submitted == 1)
        let read = try #require(fresh.takeResult())
        #expect(read.evidence.context == next && read.evidence.sourceTime == 2)
        #expect(read.image == nil)
        #expect(fresh.takeResult() == nil)
    }

    @Test("Gear OCR shares the lane, keeps its frame, and yields to the header during input")
    func gearLane() async throws {
        let session = CaptureSessionID(rawValue: 1)
        let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)
        let reader = GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            gearOperation: { _, bounds, time in GearDropFrameEvidence(sourceTime: time, stage: .bonus, bounds: bounds) })
        let frame = try image()
        reader.submit(frame, at: 1, session: session, gearBounds: bounds, headerPriority: true)
        for _ in 0..<100 {
            if reader.snapshotMetrics().completed == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.snapshotMetrics().gearSubmitted == 0)
        reader.submit(frame, at: 1.2, session: session, gearBounds: bounds)
        for _ in 0..<100 {
            if reader.snapshotMetrics().gearCompleted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = try #require(reader.takeGear())
        #expect(read.evidence.stage == .bonus && read.evidence.sourceTime == 1.2 && read.image != nil)
        #expect(reader.takeGear() == nil)
    }

    @Test("A gear picture is cropped to the panel with its title strip blacked out")
    func gearEvidenceMasksTitle() throws {
        let temporary = try TemporaryDirectory("gear-evidence")
        let writer = GearEvidenceWriter(directory: temporary.url)
        let context = try #require(CGContext(data: nil, width: 562, height: 1218,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 562, height: 1218))
        let frame = try #require(context.makeImage())
        let saved = writer.enqueue(frame, bounds: GearDropPanelBounds(top: 0.29, bottom: 0.42), sourceTime: 3.25)
        #expect(saved.status == "queued")
        writer.finish()
        let file = try #require(saved.file)
        let data = try Data(contentsOf: temporary.url.appendingPathComponent(file))
        let written = try #require(ImageDecoder.cgImage(from: data))
        #expect(written.width < 562 && written.height < 200)
        let pixels = try ImageDecoder.decodeColor(written, in: CGRect(x: 0, y: 0, width: written.width, height: written.height))
        // Top rows are the title band, now black; the rows below keep the panel.
        let title = pixels[written.width / 2, 5], body = pixels[written.width / 2, written.height - 5]
        #expect(Int(title.red) + Int(title.green) + Int(title.blue) < 30)
        #expect(Int(body.red) + Int(body.green) + Int(body.blue) > 300)
        // Beside it, the whole frame, unmasked, for a report that asks for it.
        let full = temporary.url.appendingPathComponent(HackGearPicture.fullFrameName(file))
        #expect(full.lastPathComponent == "gear-full-3.250000.jpg")
        let whole = try #require(ImageDecoder.cgImage(from: try Data(contentsOf: full)))
        #expect(whole.width == 562 && whole.height == 1218)
        let top = try ImageDecoder.decodeColor(whole, in: CGRect(x: 0, y: 0, width: whole.width, height: whole.height))[281, 360]
        #expect(Int(top.red) + Int(top.green) + Int(top.blue) > 300, "The title isn't masked in the whole frame")
    }

    @Test("A gear gap drops queued and in-flight reads without resetting header ownership")
    func gearGapInvalidatesReads() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let reader = GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .input, matchedText: "GO!", confidence: 1, sourceTime: time) },
            gearOperation: { _, bounds, time in
                if time == 1.2 { gate.wait() }
                return GearDropFrameEvidence(sourceTime: time, stage: .portal, bounds: bounds)
            })
        let frame = try image(), session = CaptureSessionID(rawValue: 1)
        let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)
        reader.submit(frame, at: 1, session: session)
        for _ in 0..<100 {
            if reader.snapshotMetrics().completed == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        reader.submit(frame, at: 1.2, session: session, gearBounds: bounds)
        #expect(reader.pendingGearSourceTime == 1.2)
        reader.invalidateGear()
        #expect(reader.pendingGearSourceTime == nil)
        #expect(reader.reading(for: 1.3, session: session)?.phase == .input)
        reader.submit(frame, at: 3, session: session, gearBounds: bounds)
        #expect(reader.snapshotMetrics().submitted == 2)
        gate.signal()
        for _ in 0..<100 {
            if reader.snapshotMetrics().staleCompletions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.takeGear() == nil)
        reader.submit(frame, at: 3.2, session: session, gearBounds: bounds)
        for _ in 0..<100 {
            if reader.snapshotMetrics().gearCompleted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.snapshotMetrics().gearCompleted == 1)
        #expect(reader.pendingGearSourceTime == 3.2)
        reader.invalidateGear()
        #expect(reader.pendingGearSourceTime == nil)
        #expect(reader.takeGear() == nil)
        reader.submit(frame, at: 3.4, session: session, gearBounds: bounds)
        for _ in 0..<100 {
            if reader.snapshotMetrics().gearCompleted == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.takeGear()?.evidence.sourceTime == 3.4)
        #expect(reader.pendingGearSourceTime == nil)
    }

    @Test("Portal-screen OCR shares the lane and yields to the header during input")
    func portalLane() async throws {
        let session = CaptureSessionID(rawValue: 1)
        let reader = GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            portalOperation: { _, time in PortalScreenEvidence(sourceTime: time, resonators: [8, 8], unreadSlots: 6, badgeHue: 259) })
        let frame = try image()
        reader.submit(frame, at: 1, session: session, headerPriority: true, portalCandidate: true)
        for _ in 0..<100 {
            if reader.snapshotMetrics().completed == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.snapshotMetrics().portalSubmitted == 0)
        reader.submit(frame, at: 1.2, session: session, portalCandidate: true)
        for _ in 0..<100 {
            if reader.snapshotMetrics().portalCompleted == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = try #require(reader.takePortal())
        #expect(read.sourceTime == 1.2 && read.resonators == [8, 8])
        #expect(reader.takePortal() == nil)
    }
}
