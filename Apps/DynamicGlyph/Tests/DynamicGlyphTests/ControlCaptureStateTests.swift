import Foundation
import Testing

@Suite("Control Center switch state")
struct ControlCaptureStateTests {
    static let second: UInt64 = 1_000_000_000
    static let now: UInt64 = 100 * second

    static func ring(_ state: FrameRingProducerState?, session: UInt64 = 7, beat: UInt64) -> ControlRingReading {
        ControlRingReading(state: state, session: session, heartbeat: beat)
    }

    @Test("Nothing reported is Off")
    func nothing() {
        #expect(!ControlCaptureState.isOn(ring: nil, app: nil, now: Self.now))
    }

    @Test("A running or paused broadcast with a fresh heartbeat is On", arguments: [
        FrameRingProducerState.running, .paused
    ])
    func liveBroadcast(_ state: FrameRingProducerState) {
        #expect(ControlCaptureState.isOn(ring: Self.ring(state, beat: Self.now - 2 * Self.second), app: nil,
                                         now: Self.now))
    }

    @Test("A broadcast that ended, failed, never began or was never named is Off", arguments: [
        FrameRingProducerState.idle, .finished, .failed
    ])
    func endedBroadcast(_ state: FrameRingProducerState) {
        #expect(!ControlCaptureState.isOn(ring: Self.ring(state, beat: Self.now), app: nil, now: Self.now))
        #expect(!ControlCaptureState.isOn(ring: Self.ring(nil, beat: Self.now), app: nil, now: Self.now))
        #expect(!ControlCaptureState.isOn(ring: Self.ring(.running, session: 0, beat: Self.now), app: nil,
                                          now: Self.now))
    }

    @Test("A broadcast whose extension stopped beating, as after a crash, goes Off within three seconds")
    func staleBroadcast() {
        let ring = Self.ring(.running, beat: Self.now)
        #expect(ControlCaptureState.isOn(ring: ring, app: nil, now: Self.now + 2_900_000_000))
        #expect(!ControlCaptureState.isOn(ring: ring, app: nil, now: Self.now + 3 * Self.second))
    }

    @Test("A heartbeat from the future was left before a restart: Off")
    func heartbeatFromBeforeRestart() {
        let ring = Self.ring(.running, beat: Self.now + 600 * Self.second)
        #expect(!ControlCaptureState.isOn(ring: ring, app: nil, now: Self.now))
        let app = ControlCaptureBeacon(session: UUID(), heartbeat: Self.now + 600 * Self.second)
        #expect(!ControlCaptureState.isOn(ring: nil, app: app, now: Self.now))
        // One landing as the time is read is not from the future.
        #expect(ControlCaptureState.isOn(ring: Self.ring(.running, beat: Self.now + 100_000_000), app: nil,
                                         now: Self.now))
    }

    @Test("The app's capture is On while its report is fresh, Off once it ends or goes stale")
    func appCapture() {
        let live = ControlCaptureBeacon(session: UUID(), heartbeat: Self.now - Self.second)
        #expect(ControlCaptureState.isOn(ring: nil, app: live, now: Self.now))
        #expect(!ControlCaptureState.isOn(ring: nil, app: live, now: Self.now + 2 * Self.second + 1))
        let ended = ControlCaptureBeacon(session: nil, heartbeat: Self.now)
        #expect(!ControlCaptureState.isOn(ring: nil, app: ended, now: Self.now))
    }

    @Test("Either side capturing is enough: a broadcast outlives a crashed or suspended app")
    func eitherSide() {
        let staleApp = ControlCaptureBeacon(session: UUID(), heartbeat: Self.now - 30 * Self.second)
        #expect(ControlCaptureState.isOn(ring: Self.ring(.running, beat: Self.now), app: staleApp, now: Self.now))
        let liveApp = ControlCaptureBeacon(session: UUID(), heartbeat: Self.now)
        #expect(ControlCaptureState.isOn(ring: Self.ring(.finished, beat: Self.now), app: liveApp, now: Self.now))
    }

    @Test("A stop request answers only the capture it names")
    func stopAnswers() {
        let session = UUID()
        #expect(ControlCaptureState.answers(ControlStopRequest(session: session), session: session))
        #expect(!ControlCaptureState.answers(ControlStopRequest(session: UUID()), session: session),
                "an earlier capture's request")
        #expect(!ControlCaptureState.answers(ControlStopRequest(session: session), session: nil), "not capturing")
        #expect(!ControlCaptureState.answers(nil, session: session))
    }
}

@Suite("Control Center switch stop")
struct ControlCaptureStoreTests {
    static let second: UInt64 = 1_000_000_000

    let directory: TemporaryDirectory
    let store: ControlCaptureStore
    let ringURL: URL

    init() throws {
        directory = try TemporaryDirectory("control")
        ringURL = directory.url.appendingPathComponent("ring-v1")
        store = ControlCaptureStore(directory: directory.url, ringURL: ringURL)
    }

    func makeWriter() throws -> FrameRingWriter {
        FrameRingWriter(ring: try FrameRingMapping.create(at: ringURL,
                                                           layout: FrameRingLayout(slotCount: 2, slotCapacity: 4096)))
    }

    @Test("With nothing in the App Group, the switch is Off and a stop asks nothing")
    func empty() {
        #expect(store.readBeacon() == nil)
        #expect(store.readRing() == nil)
        #expect(!store.isOn(now: 10 * Self.second))
        #expect(store.requestStop(now: 10 * Self.second) == .init())
        #expect(store.readStopRequest() == nil)
    }

    @Test("Stopping the app's capture leaves a request naming it, and asking again changes nothing")
    func stopApp() {
        let session = UUID()
        store.write(ControlCaptureBeacon(session: session, heartbeat: 10 * Self.second))
        #expect(store.isOn(now: 11 * Self.second))
        #expect(store.requestStop(now: 11 * Self.second) == .init(app: true, broadcast: false))
        #expect(store.readStopRequest() == ControlStopRequest(session: session))
        #expect(store.requestStop(now: 11 * Self.second + 1) == .init(app: true, broadcast: false))
        #expect(store.readStopRequest() == ControlStopRequest(session: session))
        #expect(store.isOn(now: 11 * Self.second), "On until the app reports the capture over")
        store.write(ControlCaptureBeacon(session: nil, heartbeat: 12 * Self.second))
        #expect(!store.isOn(now: 12 * Self.second))
    }

    @Test("A stale or ended report of the app's capture is not asked to stop")
    func stopStaleApp() {
        store.write(ControlCaptureBeacon(session: UUID(), heartbeat: 10 * Self.second))
        #expect(store.requestStop(now: 20 * Self.second) == .init())
        #expect(store.readStopRequest() == nil)
    }

    @Test("Stopping a broadcast asks its extension through the ring, even with the app away")
    func stopBroadcast() throws {
        let writer = try makeWriter()
        writer.begin(session: 42, uptime: 10 * Self.second)
        #expect(store.isOn(now: 11 * Self.second))
        #expect(store.requestStop(now: 11 * Self.second) == .init(app: false, broadcast: true))
        #expect(writer.isStopRequested)
        #expect(store.isOn(now: 11 * Self.second), "On until the extension ends the broadcast")
        writer.end(.finished, reason: .stopRequested)
        #expect(!store.isOn(now: 11 * Self.second))
        #expect(store.requestStop(now: 11 * Self.second) == .init(), "nothing left to stop")
    }

    @Test("A broadcast left running by a killed extension, or from before a restart, is not asked to stop")
    func stopDeadBroadcast() throws {
        let writer = try makeWriter()
        writer.begin(session: 5, uptime: 10 * Self.second)
        #expect(store.requestStop(now: 20 * Self.second) == .init())
        #expect(store.requestStop(now: 2 * Self.second) == .init())
        #expect(!writer.isStopRequested)
    }
}
