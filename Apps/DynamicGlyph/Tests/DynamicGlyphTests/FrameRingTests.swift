import CoreVideo
import Foundation
import Testing

/// The transport from the broadcast extension to the app. Each test maps the
/// same file twice, as the two processes do.
@Suite("Frame ring")
struct FrameRingTests {
    @Test("Frames arrive in order with their pixels, times and orientation")
    func inOrder() throws {
        let pair = try Pair()
        pair.writer.begin(session: 7)
        #expect(pair.reader.next().session == 7)
        for n in 0..<3 {
            let outcome = pair.writer.publish(try Pattern.buffer(n), presentationTime: 10 + Double(n),
                                              orientation: 1, arrivalUptime: UInt64(n) * 1_000_000_000)
            #expect(outcome == .published(sequence: UInt64(n)))
        }
        for n in 0..<3 {
            let frame = try #require(pair.reader.next().frame)
            #expect(frame.sequence == UInt64(n))
            #expect(frame.session == 7)
            #expect(frame.presentationTime == 10 + Double(n))
            #expect(frame.arrivalUptime == Double(n))
            #expect(frame.orientation == 1)
            #expect(Pattern.isFilled(frame.pixelBuffer, with: UInt8(n)))
        }
        #expect(pair.reader.next().isNothingNew)
        #expect(pair.reader.counters == .init())
    }

    @Test("A slow reader misses exactly what was overwritten, and both sides count it")
    func overrun() throws {
        let pair = try Pair(slotCount: 4)
        pair.writer.begin(session: 1)
        _ = pair.reader.next()
        for n in 0..<7 { _ = pair.writer.publish(try Pattern.buffer(n), presentationTime: Double(n)) }
        let first = try #require(pair.reader.next().frame)
        #expect(first.sequence == 3)
        #expect(Pattern.isFilled(first.pixelBuffer, with: 3))
        #expect(pair.reader.counters.missed == 3)
        #expect(pair.reader.overwrittenUnread == 3)
    }

    @Test("Until the reader acknowledges a session, nothing counts as overwritten unread")
    func unacknowledged() throws {
        let pair = try Pair(slotCount: 4)
        pair.writer.begin(session: 1)
        for n in 0..<7 { _ = pair.writer.publish(try Pattern.buffer(n), presentationTime: Double(n)) }
        #expect(pair.reader.overwrittenUnread == 0)
    }

    @Test("A slot that is being written is skipped as missed")
    func beingWritten() throws {
        let pair = try Pair()
        pair.writer.begin(session: 1)
        _ = pair.reader.next()
        _ = pair.writer.publish(try Pattern.buffer(0), presentationTime: 0)
        pair.writerRing.atomic(at: pair.writerRing.layout.slotOffset(0)).pointee.store(1, ordering: .releasing)
        #expect(pair.reader.next().isNothingNew)
        #expect(pair.reader.counters.missed == 1)
    }

    @Test("A complete slot whose layout does not fit is rejected, never read", arguments: [
        (FrameRingLayout.Slot.planeCount, UInt32(3)),
        (FrameRingLayout.Slot.planes, UInt32.max),              // first plane's offset
        (FrameRingLayout.Slot.planes + 4, UInt32.max),          // first plane's bytes per row
        (FrameRingLayout.Slot.width, UInt32(9000)),
        (FrameRingLayout.Slot.session, UInt32(99))
    ])
    func rejected(field: Int, value: UInt32) throws {
        let pair = try Pair()
        pair.writer.begin(session: 1)
        _ = pair.reader.next()
        _ = pair.writer.publish(try Pattern.buffer(0), presentationTime: 0)
        pair.writerRing.slot(0).storeBytes(of: value, toByteOffset: field, as: UInt32.self)
        #expect(pair.reader.next().isNothingNew)
        #expect(pair.reader.counters.rejected == 1)
    }

    @Test("A new session restarts the sequence and is reported as a break")
    func newSession() throws {
        let pair = try Pair()
        pair.writer.begin(session: 1)
        _ = pair.reader.next()
        for n in 0..<2 { _ = pair.writer.publish(try Pattern.buffer(n), presentationTime: Double(n)) }
        _ = pair.reader.next()
        pair.writer.begin(session: 2)
        _ = pair.writer.publish(try Pattern.buffer(5), presentationTime: 50)
        #expect(pair.reader.next().session == 2)
        let frame = try #require(pair.reader.next().frame)
        #expect(frame.sequence == 0 && frame.session == 2)
        #expect(Pattern.isFilled(frame.pixelBuffer, with: 5))
        #expect(pair.reader.counters == .init())
    }

    @Test("Producer state and heartbeat reach the reader; the stop request reaches the producer")
    func control() throws {
        let pair = try Pair()
        pair.writer.begin(session: 3, uptime: 1_000_000_000)
        _ = pair.reader.next()
        #expect(pair.reader.producerState == .running)
        #expect(pair.reader.producerHeartbeatAge(now: 3_500_000_000) == 2.5)
        #expect(!pair.writer.isStopRequested)
        pair.reader.requestStop()
        #expect(pair.writer.isStopRequested)
        pair.writer.end(.finished)
        #expect(pair.reader.producerState == .finished)
        #expect(pair.writer.publish(try Pattern.buffer(0), presentationTime: 0) == .notRunning)
    }

    @Test("A stop asked for before the first read still names the producer's session")
    func stopBeforeFirstRead() throws {
        let pair = try Pair()
        pair.writer.begin(session: 9)
        pair.reader.requestStop()
        #expect(pair.writer.isStopRequested)
    }

    @Test("After a cancelled start, only a live broadcast is asked to stop")
    func stopLiveSession() throws {
        let pair = try Pair()
        #expect(!pair.reader.stopLiveSession(freshness: 1.5), "no session yet")
        pair.writer.begin(session: 4, uptime: 1_000_000_000)
        pair.writer.end(.finished)
        #expect(!pair.reader.stopLiveSession(freshness: 1.5, now: 1_500_000_000), "already over")
        #expect(!pair.writer.isStopRequested)
        // A broadcast that begins late, with nothing read from it yet.
        pair.writer.begin(session: 5, uptime: 2_000_000_000)
        #expect(!pair.reader.stopLiveSession(freshness: 1.5, now: 4_000_000_000), "stale heartbeat")
        #expect(pair.reader.stopLiveSession(freshness: 1.5, now: 2_500_000_000))
        #expect(pair.writer.isStopRequested)
        pair.writer.begin(session: 6, uptime: 3_000_000_000)
        pair.writer.end(.paused)
        #expect(pair.reader.stopLiveSession(freshness: 1.5, now: 3_200_000_000), "a paused broadcast still shares")
        #expect(pair.writer.isStopRequested)
    }

    @Test("A heartbeat from before a restart is infinitely old, never fresh")
    func heartbeatFromBeforeRestart() throws {
        let pair = try Pair()
        pair.writer.begin(session: 8, uptime: 900_000_000_000)
        // Uptime starts again at zero after a restart.
        #expect(pair.reader.producerHeartbeatAge(now: 5_000_000_000) == .infinity)
        #expect(!pair.reader.stopLiveSession(freshness: 1.5, now: 5_000_000_000), "nothing live to stop")
        #expect(!pair.writer.isStopRequested)
        // A beat landing just after the reader took the time is fresh.
        #expect(pair.reader.producerHeartbeatAge(now: 899_900_000_000) == 0)
        #expect(pair.reader.stopLiveSession(freshness: 1.5, now: 899_900_000_000))
    }

    @Test("A beat up to 250 ms ahead of the reader's clock is fresh; beyond that it predates a restart")
    func futureHeartbeatBoundary() throws {
        let pair = try Pair()
        pair.writer.begin(session: 9, uptime: 10_000_000_000)
        #expect(pair.reader.producerHeartbeatAge(now: 9_800_000_000) == 0, "200 ms ahead")
        #expect(pair.reader.producerHeartbeatAge(now: 9_700_000_000) == .infinity, "300 ms ahead")
        #expect(FrameRingClock.age(of: 10_000_000_000, now: 9_750_000_000) == 0, "exactly 250 ms ahead")
    }

    @Test("Without a given time, the reader takes it after the beat, so a live producer is never in the future")
    func heartbeatReadBeforeTime() throws {
        let pair = try Pair()
        pair.writer.begin(session: 10)
        let age = pair.reader.producerHeartbeatAge()
        #expect(age >= 0 && age < 1)
    }

    @Test("Why the producer ended, and its peak memory, reach the reader; a new session clears them")
    func endReason() throws {
        let pair = try Pair()
        pair.writer.begin(session: 1)
        pair.writer.report(peakFootprint: 31 << 20)
        pair.writer.end(.finished, reason: .broadcastFinished)
        #expect(pair.reader.producerEndReason == .broadcastFinished)
        #expect(pair.reader.producerPeakFootprint == 31 << 20)
        pair.writer.begin(session: 2)
        #expect(pair.reader.producerEndReason == FrameRingEndReason.none)
        #expect(pair.reader.producerPeakFootprint == 0)
    }

    @Test("Broadcast frames are scaled to the width recognition was measured at, never up",
          arguments: [((886, 1918), (603, 1305)), ((1206, 2622), (603, 1311)), ((402, 874), (402, 874))])
    func scaledSize(source: (Int, Int), expected: (Int, Int)) {
        let size = BroadcastChannel.scaledSize(width: source.0, height: source.1)
        #expect(size.width == expected.0 && size.height == expected.1)
    }

    @Test("A frame larger than a slot is dropped and counted")
    func tooLarge() throws {
        let pair = try Pair(slotCapacity: 1024)
        pair.writer.begin(session: 1)
        #expect(pair.writer.publish(try Pattern.buffer(0), presentationTime: 0) == .tooLarge)
        #expect(pair.reader.producerDropped == 1)
    }

    @Test("A missing or foreign file is refused; an incompatible one is replaced, not resized")
    func files() throws {
        let directory = try TemporaryDirectory("ring-files")
        let url = directory.url.appendingPathComponent("ring-v1")
        #expect(throws: FrameRingError.self) { try FrameRingMapping.open(at: url) }
        try Data(repeating: 7, count: 512).write(to: url)
        #expect(throws: FrameRingError.incompatible) { try FrameRingMapping.open(at: url) }

        let first = try FrameRingMapping.create(at: url, layout: FrameRingLayout(slotCount: 4, slotCapacity: 4096))
        let reused = try FrameRingMapping.create(at: url, layout: first.layout)
        #expect(reused.inode == first.inode)
        let replaced = try FrameRingMapping.create(at: url, layout: FrameRingLayout(slotCount: 6, slotCapacity: 4096))
        #expect(replaced.inode != first.inode)
        #expect(try FrameRingMapping.open(at: url).layout.slotCount == 6)
    }

    @Test("Under a concurrent writer every delivered frame is whole, and every loss is counted")
    func concurrent() throws {
        let directory = try TemporaryDirectory("ring-stress")
        let url = directory.url.appendingPathComponent("ring-v1")
        let layout = FrameRingLayout(slotCount: 4, slotCapacity: 16_384)
        let writerRing = try FrameRingMapping.create(at: url, layout: layout)
        let writer = FrameRingWriter(ring: writerRing)
        writer.begin(session: 1)
        let buffers = try (0..<256).map { try Pattern.buffer($0) }
        let total = 3000
        let result = Collected()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            guard let ring = try? FrameRingMapping.open(at: url) else { return result.fail() }
            let reader = FrameRingReader(ring: ring)
            let deadline = Date().addingTimeInterval(20)
            var last: UInt64?
            while Date() < deadline {
                switch reader.next() {
                case .frame(let frame):
                    if let last, frame.sequence <= last { result.fail() }
                    if !Pattern.isFilled(frame.pixelBuffer, with: UInt8(frame.sequence & 0xFF)) { result.fail() }
                    last = frame.sequence
                    result.delivered()
                    if frame.sequence == UInt64(total - 1) {
                        return result.finish(reader.counters)
                    }
                case .sessionChanged, .nothingNew:
                    continue
                }
            }
            result.finish(reader.counters)
        }
        // The reader acknowledges the session before the writer starts.
        while writerRing.header(FrameRingLayout.Header.consumerSession).pointee.load(ordering: .acquiring) != 1 {
            usleep(100)
        }
        for n in 0..<total {
            _ = writer.publish(buffers[n % buffers.count], presentationTime: Double(n))
        }
        group.wait()
        let counters = try #require(result.counters)
        #expect(!result.failed)
        #expect(counters.rejected == 0)
        #expect(result.deliveredCount > 0)
        #expect(UInt64(result.deliveredCount) + counters.missed + counters.torn == UInt64(total))
    }
}

// MARK: - Helpers

private struct Pair {
    let directory: TemporaryDirectory
    let writerRing: FrameRingMapping
    let writer: FrameRingWriter
    let reader: FrameRingReader

    init(slotCount: Int = 8, slotCapacity: Int = 16_384) throws {
        directory = try TemporaryDirectory("ring")
        let url = directory.url.appendingPathComponent("ring-v1")
        writerRing = try FrameRingMapping.create(at: url,
                                                 layout: FrameRingLayout(slotCount: slotCount, slotCapacity: slotCapacity))
        writer = FrameRingWriter(ring: writerRing)
        reader = FrameRingReader(ring: try FrameRingMapping.open(at: url))
    }
}

/// Small 420f frames whose every byte, in both planes, is the frame's number.
private enum Pattern {
    static let width = 64, height = 48

    static func buffer(_ n: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw Frames.Failure(description: "could not allocate a pattern buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            memset(base, Int32(n & 0xFF), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                                          * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }

    /// Checks the visible bytes of every row, not the padding.
    static func isFilled(_ buffer: CVPixelBuffer, with value: UInt8) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return false }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return false }
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let bytes = UnsafeRawBufferPointer(start: base + row * stride, count: rowBytes)
                if bytes.contains(where: { $0 != value }) { return false }
            }
        }
        return true
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var deliveries = 0
    private var finalCounters: FrameRingReader.Counters?

    func fail() { lock.withLock { failures += 1 } }
    func delivered() { lock.withLock { deliveries += 1 } }
    func finish(_ counters: FrameRingReader.Counters) { lock.withLock { finalCounters = counters } }
    var failed: Bool { lock.withLock { failures > 0 } }
    var deliveredCount: Int { lock.withLock { deliveries } }
    var counters: FrameRingReader.Counters? { lock.withLock { finalCounters } }
}

private extension FrameRingReader.Event {
    var frame: FrameRingReader.Frame? {
        if case .frame(let frame) = self { return frame }
        return nil
    }
    var session: UInt64? {
        if case .sessionChanged(let session) = self { return session }
        return nil
    }
    var isNothingNew: Bool {
        if case .nothingNew = self { return true }
        return false
    }
}
