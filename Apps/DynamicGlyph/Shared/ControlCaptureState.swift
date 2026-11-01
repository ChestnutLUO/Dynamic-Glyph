import Foundation

/// The app's own report of a capture it runs itself (ScreenCaptureKit, iOS
/// 27), kept in the App Group for the Control Center switch. Rewritten about
/// once a second while capturing, so a report left by a crash goes stale.
struct ControlCaptureBeacon: Codable, Equatable {
    /// The capture being reported; nil once it has ended.
    var session: UUID?
    /// `FrameRingClock` time of the latest report.
    var heartbeat: UInt64
}

/// A stop asked for from Control Center, naming the app's capture it is for,
/// so it can never end a later one.
struct ControlStopRequest: Codable, Equatable {
    var session: UUID
}

/// What the switch reads of the broadcast extension's ring (iOS 18-26).
struct ControlRingReading: Equatable {
    var state: FrameRingProducerState?
    var session: UInt64
    var heartbeat: UInt64
}

/// Whether the screen is actually being read, from what the app and the
/// broadcast extension leave in the App Group. Either side can be the one
/// capturing: the app on iOS 27, the extension on iOS 18-26, where the app
/// may be suspended while the broadcast goes on.
enum ControlCaptureState {
    /// A report older than this is from a process that died or is frozen.
    static let freshness = 3.0

    static func isOn(ring: ControlRingReading?, app: ControlCaptureBeacon?, now: UInt64) -> Bool {
        isLive(ring, now: now) || isLive(app, now: now)
    }

    /// Running or paused (a paused broadcast still shares the screen), with
    /// a fresh heartbeat. One from the future predates a restart.
    static func isLive(_ ring: ControlRingReading?, now: UInt64) -> Bool {
        guard let ring, ring.session != 0, ring.state == .running || ring.state == .paused else { return false }
        return FrameRingClock.age(of: ring.heartbeat, now: now) < freshness
    }

    static func isLive(_ app: ControlCaptureBeacon?, now: UInt64) -> Bool {
        guard let app, app.session != nil else { return false }
        return FrameRingClock.age(of: app.heartbeat, now: now) < freshness
    }

    /// Whether `request` is for the capture the app is running now.
    static func answers(_ request: ControlStopRequest?, session: UUID?) -> Bool {
        guard let request, let session else { return false }
        return request.session == session
    }
}

/// The App Group files and the ring, read and written for the switch.
struct ControlCaptureStore {
    /// What a stop from Control Center asked for.
    struct StopOutcome: Equatable {
        /// The app's capture, by a request it reads on the Darwin notification.
        var app = false
        /// The broadcast, through the ring the extension watches itself.
        var broadcast = false

        var askedAnything: Bool { app || broadcast }
    }

    let directory: URL
    let ringURL: URL?

    var beaconURL: URL { directory.appendingPathComponent("capture-v1.json") }
    var stopURL: URL { directory.appendingPathComponent("stop-v1.json") }

    func readBeacon() -> ControlCaptureBeacon? { read(ControlCaptureBeacon.self, from: beaconURL) }

    func write(_ beacon: ControlCaptureBeacon) { write(beacon, to: beaconURL) }

    func readStopRequest() -> ControlStopRequest? { read(ControlStopRequest.self, from: stopURL) }

    func readRing() -> ControlRingReading? {
        guard let reader = ringReader() else { return nil }
        return ControlRingReading(state: reader.producerState, session: reader.producerSession,
                                  heartbeat: reader.producerHeartbeat)
    }

    /// The reports are read before the time is taken, so a heartbeat
    /// written in between is never in the future.
    func isOn(now: UInt64? = nil) -> Bool {
        let ring = readRing(), app = readBeacon()
        return ControlCaptureState.isOn(ring: ring, app: app, now: now ?? FrameRingClock.uptimeNanoseconds())
    }

    /// Asks whichever side is capturing to stop: the app through a request
    /// naming its capture, the broadcast through the ring. Asking again for
    /// the same capture changes nothing. The caller posts the notifications.
    func requestStop(now: UInt64? = nil) -> StopOutcome {
        var outcome = StopOutcome()
        // Read before the time is taken, as in `isOn`; the ring does the same.
        let beacon = readBeacon()
        if let beacon, ControlCaptureState.isLive(beacon, now: now ?? FrameRingClock.uptimeNanoseconds()),
           let session = beacon.session {
            write(ControlStopRequest(session: session), to: stopURL)
            outcome.app = true
        }
        if let reader = ringReader() {
            outcome.broadcast = reader.stopLiveSession(freshness: ControlCaptureState.freshness, now: now)
        }
        return outcome
    }

    private func ringReader() -> FrameRingReader? {
        guard let ringURL, let mapping = try? FrameRingMapping.open(at: ringURL) else { return nil }
        return FrameRingReader(ring: mapping)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Readable while the iPhone is locked, after its first unlock: Control
    /// Center is reachable from the Lock Screen.
    private func write(_ value: some Encodable, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
