import CoreVideo
import Foundation
import Synchronization

// The broadcast extension's frames cross into the app through a ring of
// slots in one shared file. Docs/FRAME_TRANSPORT.md is the protocol; this is
// its implementation, used by both processes.

/// Where everything sits in the file, for version 1.
struct FrameRingLayout: Equatable, Sendable {
    static let magic: UInt32 = 0x4447_4654 // "DGFT"
    static let version: UInt32 = 1
    static let headerSize = 256
    static let slotHeaderSize = 128
    /// Beyond any screen this app captures; bounds what a torn header can claim.
    static let maximumDimension: UInt32 = 8192

    let slotCount: Int
    /// Payload bytes per slot.
    let slotCapacity: Int

    var slotStride: Int { Self.slotHeaderSize + (slotCapacity + 63) / 64 * 64 }
    var fileSize: Int { Self.headerSize + slotCount * slotStride }
    func slotOffset(_ index: Int) -> Int { Self.headerSize + index * slotStride }

    enum Header {
        static let magic = 0, version = 4, slotCount = 8, slotCapacity = 12
        static let producerSession = 16, producerState = 24, producerHeartbeat = 32, published = 40
        static let overwrittenUnread = 48, producerDropped = 56
        static let consumerSession = 64, consumerRead = 72, consumerHeartbeat = 80, stopRequested = 88
        static let producerPeakFootprint = 96, producerEndReason = 104
    }

    enum Slot {
        static let sequence = 0, session = 8, presentationTime = 16, arrivalUptime = 24
        static let width = 32, height = 36, pixelFormat = 40, orientation = 44
        static let planeCount = 48, payloadLength = 52, planes = 56, planeSize = 16
        static let maximumPlanes = 2
    }
}

enum FrameRingProducerState: UInt64, Sendable {
    case idle = 0, running, paused, finished, failed
}

/// Why the producer finished, so the app can tell the player's or iOS's
/// stop from its own request. A killed extension records nothing.
enum FrameRingEndReason: UInt64, Sendable {
    case none = 0
    /// ReplayKit called `broadcastFinished`: the player or iOS ended it.
    case broadcastFinished
    /// The app asked, through `stopRequested`.
    case stopRequested
}

enum FrameRingError: Error, Equatable {
    case cannotOpen(errno: Int32)
    case incompatible
    case cannotMap(errno: Int32)
}

/// One process's mapping of the ring file.
final class FrameRingMapping {
    let layout: FrameRingLayout
    /// The file this mapping belongs to; a different one at the same path
    /// means the producer recreated it.
    let inode: UInt64
    private let base: UnsafeMutableRawPointer
    private let descriptor: Int32

    private init(layout: FrameRingLayout, descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FrameRingError.cannotOpen(errno: errno) }
        guard let mapped = mmap(nil, layout.fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapped != MAP_FAILED else { throw FrameRingError.cannotMap(errno: errno) }
        self.layout = layout
        self.descriptor = descriptor
        base = mapped
        inode = UInt64(info.st_ino)
    }

    deinit {
        munmap(base, layout.fileSize)
        close(descriptor)
    }

    /// For the producer. Keeps a compatible file in place, since the consumer
    /// may already have it mapped; replaces an incompatible one by renaming a
    /// new file over it, never by resizing, which would fault the consumer's
    /// mapping beyond the new end.
    static func create(at url: URL, layout: FrameRingLayout) throws -> FrameRingMapping {
        if let existing = try? open(at: url), existing.layout == layout { return existing }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw FrameRingError.cannotOpen(errno: errno) }
        guard ftruncate(descriptor, off_t(layout.fileSize)) == 0 else {
            let failure = errno
            close(descriptor)
            unlink(temporary.path)
            throw FrameRingError.cannotOpen(errno: failure)
        }
        let mapping: FrameRingMapping
        do { mapping = try FrameRingMapping(layout: layout, descriptor: descriptor) } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        mapping.storeU32(FrameRingLayout.magic, at: FrameRingLayout.Header.magic)
        mapping.storeU32(FrameRingLayout.version, at: FrameRingLayout.Header.version)
        mapping.storeU32(UInt32(layout.slotCount), at: FrameRingLayout.Header.slotCount)
        mapping.storeU32(UInt32(layout.slotCapacity), at: FrameRingLayout.Header.slotCapacity)
        guard rename(temporary.path, url.path) == 0 else {
            let failure = errno
            unlink(temporary.path)
            throw FrameRingError.cannotOpen(errno: failure)
        }
        return mapping
    }

    /// For the consumer: an existing file whose header and size agree.
    static func open(at url: URL) throws -> FrameRingMapping {
        let descriptor = Darwin.open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw FrameRingError.cannotOpen(errno: errno) }
        var header = [UInt32](repeating: 0, count: 4)
        let wanted = header.count * MemoryLayout<UInt32>.size
        let read = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, 0) }
        var info = stat()
        guard read == wanted, fstat(descriptor, &info) == 0,
              header[0] == FrameRingLayout.magic, header[1] == FrameRingLayout.version,
              header[2] > 0, header[3] > 0 else {
            close(descriptor)
            throw FrameRingError.incompatible
        }
        let layout = FrameRingLayout(slotCount: Int(header[2]), slotCapacity: Int(header[3]))
        guard info.st_size == off_t(layout.fileSize) else {
            close(descriptor)
            throw FrameRingError.incompatible
        }
        do { return try FrameRingMapping(layout: layout, descriptor: descriptor) } catch {
            close(descriptor)
            throw error
        }
    }

    // MARK: Field access

    func atomic(at offset: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        (base + offset).bindMemory(to: Atomic<UInt64>.self, capacity: 1)
    }

    func header(_ field: Int) -> UnsafeMutablePointer<Atomic<UInt64>> { atomic(at: field) }

    func slot(_ index: Int) -> UnsafeMutableRawPointer { base + layout.slotOffset(index) }

    func storeU32(_ value: UInt32, at offset: Int) { (base + offset).storeBytes(of: value, as: UInt32.self) }
}

// MARK: - Producer

/// The extension's side: publishes frames into the ring.
final class FrameRingWriter {
    enum Outcome: Equatable {
        case published(sequence: UInt64)
        case tooLarge
        case notRunning
    }

    private let ring: FrameRingMapping
    private(set) var session: UInt64 = 0
    private var isRunning = false

    init(ring: FrameRingMapping) {
        self.ring = ring
    }

    /// Starts a session, in the order the protocol gives. The session is
    /// stored last, so a reader that sees it also sees the counters and slots
    /// already reset.
    func begin(session: UInt64 = UInt64.random(in: 1...UInt64.max),
               uptime: UInt64 = FrameRingClock.uptimeNanoseconds()) {
        typealias H = FrameRingLayout.Header
        ring.header(H.producerState).pointee.store(FrameRingProducerState.idle.rawValue, ordering: .releasing)
        ring.header(H.published).pointee.store(0, ordering: .releasing)
        ring.header(H.overwrittenUnread).pointee.store(0, ordering: .relaxed)
        ring.header(H.producerDropped).pointee.store(0, ordering: .relaxed)
        ring.header(H.producerPeakFootprint).pointee.store(0, ordering: .relaxed)
        ring.header(H.producerEndReason).pointee.store(FrameRingEndReason.none.rawValue, ordering: .relaxed)
        for index in 0..<ring.layout.slotCount {
            ring.atomic(at: ring.layout.slotOffset(index) + FrameRingLayout.Slot.sequence).pointee
                .store(0, ordering: .releasing)
        }
        ring.header(H.producerSession).pointee.store(session, ordering: .releasing)
        ring.header(H.producerHeartbeat).pointee.store(uptime, ordering: .releasing)
        ring.header(H.producerState).pointee.store(FrameRingProducerState.running.rawValue, ordering: .releasing)
        self.session = session
        isRunning = true
    }

    func end(_ state: FrameRingProducerState, reason: FrameRingEndReason = .none) {
        isRunning = state == .running
        ring.header(FrameRingLayout.Header.producerEndReason).pointee.store(reason.rawValue, ordering: .relaxed)
        ring.header(FrameRingLayout.Header.producerState).pointee.store(state.rawValue, ordering: .releasing)
    }

    /// The producer's peak memory footprint so far, in bytes.
    func report(peakFootprint: UInt64) {
        ring.header(FrameRingLayout.Header.producerPeakFootprint).pointee.store(peakFootprint, ordering: .relaxed)
    }

    func heartbeat(uptime: UInt64 = FrameRingClock.uptimeNanoseconds()) {
        ring.header(FrameRingLayout.Header.producerHeartbeat).pointee.store(uptime, ordering: .releasing)
    }

    /// Whether the app has asked this session to end.
    var isStopRequested: Bool {
        session != 0
            && ring.header(FrameRingLayout.Header.stopRequested).pointee.load(ordering: .acquiring) == session
    }

    func publish(_ pixels: CVPixelBuffer, presentationTime: Double, orientation: UInt32 = 0,
                 arrivalUptime: UInt64 = FrameRingClock.uptimeNanoseconds()) -> Outcome {
        typealias H = FrameRingLayout.Header
        typealias S = FrameRingLayout.Slot
        guard isRunning else { return .notRunning }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let planes = Self.planes(of: pixels)
        let length = planes.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        guard !planes.isEmpty, planes.count <= S.maximumPlanes, length <= ring.layout.slotCapacity else {
            ring.header(H.producerDropped).pointee.wrappingAdd(1, ordering: .relaxed)
            return .tooLarge
        }

        let n = ring.header(H.published).pointee.load(ordering: .relaxed)
        let slotCount = UInt64(ring.layout.slotCount)
        if ring.header(H.consumerSession).pointee.load(ordering: .acquiring) == session {
            let read = ring.header(H.consumerRead).pointee.load(ordering: .acquiring)
            if n >= read, n - read >= slotCount {
                ring.header(H.overwrittenUnread).pointee.wrappingAdd(1, ordering: .relaxed)
            }
        }
        let index = Int(n % slotCount)
        let slot = ring.slot(index)
        let sequence = ring.atomic(at: ring.layout.slotOffset(index) + S.sequence)
        sequence.pointee.store(2 * n + 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)

        slot.storeBytes(of: session, toByteOffset: S.session, as: UInt64.self)
        slot.storeBytes(of: presentationTime, toByteOffset: S.presentationTime, as: Double.self)
        slot.storeBytes(of: arrivalUptime, toByteOffset: S.arrivalUptime, as: UInt64.self)
        slot.storeBytes(of: UInt32(CVPixelBufferGetWidth(pixels)), toByteOffset: S.width, as: UInt32.self)
        slot.storeBytes(of: UInt32(CVPixelBufferGetHeight(pixels)), toByteOffset: S.height, as: UInt32.self)
        slot.storeBytes(of: CVPixelBufferGetPixelFormatType(pixels), toByteOffset: S.pixelFormat, as: UInt32.self)
        slot.storeBytes(of: orientation, toByteOffset: S.orientation, as: UInt32.self)
        slot.storeBytes(of: UInt32(planes.count), toByteOffset: S.planeCount, as: UInt32.self)
        slot.storeBytes(of: UInt32(length), toByteOffset: S.payloadLength, as: UInt32.self)
        let payload = slot + FrameRingLayout.slotHeaderSize
        var offset = 0
        for (number, plane) in planes.enumerated() {
            let entry = S.planes + number * S.planeSize
            for (field, value) in [offset, plane.bytesPerRow, plane.width, plane.height].enumerated() {
                slot.storeBytes(of: UInt32(value), toByteOffset: entry + field * 4, as: UInt32.self)
            }
            (payload + offset).copyMemory(from: plane.base, byteCount: plane.bytesPerRow * plane.height)
            offset += plane.bytesPerRow * plane.height
        }

        sequence.pointee.store(2 * n + 2, ordering: .releasing)
        ring.header(H.published).pointee.store(n + 1, ordering: .releasing)
        heartbeat(uptime: arrivalUptime)
        return .published(sequence: n)
    }

    struct Plane {
        let base: UnsafeRawPointer
        let bytesPerRow: Int
        let width: Int
        let height: Int
    }

    /// Only valid while the buffer's base address is locked.
    static func planes(of pixels: CVPixelBuffer) -> [Plane] {
        guard CVPixelBufferIsPlanar(pixels) else {
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
            return [Plane(base: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                          width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))]
        }
        return (0..<CVPixelBufferGetPlaneCount(pixels)).compactMap { plane in
            CVPixelBufferGetBaseAddressOfPlane(pixels, plane).map {
                Plane(base: $0, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, plane),
                      width: CVPixelBufferGetWidthOfPlane(pixels, plane),
                      height: CVPixelBufferGetHeightOfPlane(pixels, plane))
            }
        }
    }
}

// MARK: - Consumer

/// The app's side: copies frames out of the ring, in order, counting every
/// frame it could not have.
final class FrameRingReader {
    struct Frame: @unchecked Sendable {
        // Unchecked for the pixel buffer, which belongs to the caller once delivered.
        let sequence: UInt64
        let session: UInt64
        /// Seconds on the host clock, as the producer received the sample.
        let presentationTime: Double
        /// Seconds of uptime when the producer received it.
        let arrivalUptime: Double
        let orientation: UInt32
        let pixelBuffer: CVPixelBuffer
    }

    enum Event {
        case frame(Frame)
        /// A new capture: continuity with anything before it is broken.
        case sessionChanged(UInt64)
        case nothingNew
    }

    struct Counters: Equatable {
        /// Overwritten, or being overwritten, before they could be read.
        var missed: UInt64 = 0
        /// Changed while being copied.
        var torn: UInt64 = 0
        /// Complete, but describing a frame that does not fit the slot.
        var rejected: UInt64 = 0
    }

    let ring: FrameRingMapping
    private(set) var counters = Counters()
    private var session: UInt64 = 0
    private var wanted: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?

    init(ring: FrameRingMapping) {
        self.ring = ring
    }

    var producerSession: UInt64 { header(FrameRingLayout.Header.producerSession) }

    var producerState: FrameRingProducerState? {
        FrameRingProducerState(rawValue: header(FrameRingLayout.Header.producerState))
    }

    /// `FrameRingClock` time of the producer's latest sign of life.
    var producerHeartbeat: UInt64 { header(FrameRingLayout.Header.producerHeartbeat) }

    /// Infinite for a heartbeat from before the device restarted; see
    /// `FrameRingClock.age(of:now:)`. The beat is read before the time is
    /// taken, so a pause between the two can only age it, never put it in
    /// the future.
    func producerHeartbeatAge(now: UInt64? = nil) -> Double {
        let beat = producerHeartbeat
        return FrameRingClock.age(of: beat, now: now ?? FrameRingClock.uptimeNanoseconds())
    }

    var overwrittenUnread: UInt64 { header(FrameRingLayout.Header.overwrittenUnread) }
    var producerPeakFootprint: UInt64 { header(FrameRingLayout.Header.producerPeakFootprint) }
    var producerEndReason: FrameRingEndReason? {
        FrameRingEndReason(rawValue: header(FrameRingLayout.Header.producerEndReason))
    }
    var producerDropped: UInt64 { header(FrameRingLayout.Header.producerDropped) }
    /// Frames the producer has published this session.
    var published: UInt64 { header(FrameRingLayout.Header.published) }

    /// Asks the producer to end its current session if that session is live:
    /// running or paused, with a heartbeat younger than `freshness` seconds.
    /// Returns whether it asked. For a start the app gave up on, whose
    /// broadcast may begin anyway.
    @discardableResult
    func stopLiveSession(freshness: Double, now: UInt64? = nil) -> Bool {
        let target = producerSession
        guard target != 0, producerState == .running || producerState == .paused,
              producerHeartbeatAge(now: now) < freshness else { return false }
        ring.header(FrameRingLayout.Header.stopRequested).pointee.store(target, ordering: .releasing)
        return true
    }

    /// Asks the producer to end the session this reader is on, or, before
    /// its first read, the producer's current one.
    func requestStop() {
        let target = session != 0 ? session : header(FrameRingLayout.Header.producerSession)
        guard target != 0 else { return }
        ring.header(FrameRingLayout.Header.stopRequested).pointee.store(target, ordering: .releasing)
    }

    func next(now: UInt64 = FrameRingClock.uptimeNanoseconds()) -> Event {
        typealias H = FrameRingLayout.Header
        ring.header(H.consumerHeartbeat).pointee.store(now, ordering: .relaxed)
        let current = header(H.producerSession)
        guard current != 0 else { return .nothingNew }
        if current != session {
            session = current
            wanted = 0
            ring.header(H.consumerRead).pointee.store(0, ordering: .releasing)
            ring.header(H.consumerSession).pointee.store(current, ordering: .releasing)
            return .sessionChanged(current)
        }
        let slotCount = UInt64(ring.layout.slotCount)
        // Each pass either delivers or moves past one lost frame, so this ends.
        for _ in 0...ring.layout.slotCount {
            let published = header(H.published)
            guard wanted < published else { return .nothingNew }
            if published - wanted > slotCount {
                counters.missed += published - slotCount - wanted
                wanted = published - slotCount
            }
            if let frame = copy(wanted) {
                wanted += 1
                ring.header(H.consumerRead).pointee.store(wanted, ordering: .releasing)
                return .frame(frame)
            }
            wanted += 1
            ring.header(H.consumerRead).pointee.store(wanted, ordering: .releasing)
        }
        return .nothingNew
    }

    private func header(_ field: Int) -> UInt64 {
        ring.header(field).pointee.load(ordering: .acquiring)
    }

    /// Frame `n`, or nil with the reason counted.
    private func copy(_ n: UInt64) -> Frame? {
        typealias S = FrameRingLayout.Slot
        let index = Int(n % UInt64(ring.layout.slotCount))
        let slot = ring.slot(index)
        let sequence = ring.atomic(at: ring.layout.slotOffset(index) + S.sequence)
        let expected = 2 * n + 2
        guard sequence.pointee.load(ordering: .acquiring) == expected else {
            counters.missed += 1
            return nil
        }
        func unchanged() -> Bool {
            atomicMemoryFence(ordering: .acquiring)
            return sequence.pointee.load(ordering: .relaxed) == expected
        }
        func u32(_ offset: Int) -> Int { Int(slot.load(fromByteOffset: offset, as: UInt32.self)) }

        let frameSession = slot.load(fromByteOffset: S.session, as: UInt64.self)
        let presentation = slot.load(fromByteOffset: S.presentationTime, as: Double.self)
        let arrival = slot.load(fromByteOffset: S.arrivalUptime, as: UInt64.self)
        let width = u32(S.width), height = u32(S.height)
        let format = OSType(u32(S.pixelFormat))
        let orientation = UInt32(u32(S.orientation))
        let planeCount = u32(S.planeCount), length = u32(S.payloadLength)
        let planes = (0..<min(planeCount, S.maximumPlanes)).map { number -> FrameRingWriter.Plane in
            let entry = S.planes + number * S.planeSize
            return FrameRingWriter.Plane(base: UnsafeRawPointer(slot + FrameRingLayout.slotHeaderSize + u32(entry)),
                                         bytesPerRow: u32(entry + 4), width: u32(entry + 8),
                                         height: u32(entry + 12))
        }
        // Checked before anything is read through these fields: a torn copy
        // could otherwise point outside the slot.
        let limit = Int(FrameRingLayout.maximumDimension)
        let offsets = (0..<planes.count).map { u32(S.planes + $0 * S.planeSize) }
        let fits = frameSession == session && (1...S.maximumPlanes).contains(planeCount)
            && width > 0 && height > 0 && width <= limit && height <= limit
            && length <= ring.layout.slotCapacity
            && zip(planes, offsets).allSatisfy { plane, offset in
                // Each bounded before multiplying, so the product cannot overflow.
                plane.width > 0 && plane.height > 0 && plane.height <= limit
                    && plane.bytesPerRow > 0 && plane.bytesPerRow <= length && offset <= length
                    && offset + plane.bytesPerRow * plane.height <= length
            }
        guard fits, let pixels = makeBuffer(width: width, height: height, format: format),
              Self.matches(pixels, planes) else {
            if unchanged() { counters.rejected += 1 } else { counters.torn += 1 }
            return nil
        }
        CVPixelBufferLockBaseAddress(pixels, [])
        for (source, destination) in zip(planes, Self.mutablePlanes(of: pixels)) {
            let rowBytes = min(source.bytesPerRow, destination.bytesPerRow)
            for row in 0..<source.height {
                (destination.base + row * destination.bytesPerRow)
                    .copyMemory(from: source.base + row * source.bytesPerRow, byteCount: rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard unchanged() else {
            counters.torn += 1
            return nil
        }
        return Frame(sequence: n, session: frameSession, presentationTime: presentation,
                     arrivalUptime: Double(arrival) / 1e9, orientation: orientation, pixelBuffer: pixels)
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if poolKey.map({ $0 != (width, height, format) }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels)
        return pixels
    }

    /// The slot's planes describe the buffer this format and size produce.
    private static func matches(_ pixels: CVPixelBuffer, _ planes: [FrameRingWriter.Plane]) -> Bool {
        let expected = CVPixelBufferIsPlanar(pixels) ? CVPixelBufferGetPlaneCount(pixels) : 1
        guard planes.count == expected else { return false }
        return planes.enumerated().allSatisfy { number, plane in
            let isPlanar = CVPixelBufferIsPlanar(pixels)
            let width = isPlanar ? CVPixelBufferGetWidthOfPlane(pixels, number) : CVPixelBufferGetWidth(pixels)
            let height = isPlanar ? CVPixelBufferGetHeightOfPlane(pixels, number) : CVPixelBufferGetHeight(pixels)
            return plane.width == width && plane.height == height
        }
    }

    private struct MutablePlane {
        let base: UnsafeMutableRawPointer
        let bytesPerRow: Int
    }

    /// Only valid while the buffer's base address is locked.
    private static func mutablePlanes(of pixels: CVPixelBuffer) -> [MutablePlane] {
        guard CVPixelBufferIsPlanar(pixels) else {
            return CVPixelBufferGetBaseAddress(pixels).map {
                [MutablePlane(base: $0, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))]
            } ?? []
        }
        return (0..<CVPixelBufferGetPlaneCount(pixels)).compactMap { plane in
            CVPixelBufferGetBaseAddressOfPlane(pixels, plane).map {
                MutablePlane(base: $0, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, plane))
            }
        }
    }
}

/// The protocol's one clock: `systemUptime` in nanoseconds, the same in
/// every process on the device.
enum FrameRingClock {
    static func uptimeNanoseconds() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1e9)
    }

    /// Readers take the time after reading the beat, so a beat ahead of it
    /// can only come from clock rounding between processes; this is margin.
    static let futureTolerance: UInt64 = 250_000_000

    /// Seconds since `beat`, both on this clock. Uptime restarts at zero
    /// with the device, so a beat further in the future than a write in
    /// flight explains was left before a restart: it is infinitely old, never
    /// fresh.
    static func age(of beat: UInt64, now: UInt64) -> Double {
        if now >= beat { return Double(now - beat) / 1e9 }
        return beat - now <= futureTolerance ? 0 : .infinity
    }
}
