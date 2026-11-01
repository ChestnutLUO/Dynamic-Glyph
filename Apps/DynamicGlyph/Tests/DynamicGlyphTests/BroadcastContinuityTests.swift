import Testing

@Suite("Broadcast continuity")
struct BroadcastContinuityTests {
    @Test("Only a running producer with a fresh heartbeat vouches for a still screen")
    func stillScreenHeartbeat() {
        #expect(BroadcastContinuity.canAdvanceStill(state: .running, heartbeatAge: 0))
        #expect(BroadcastContinuity.canAdvanceStill(state: .running, heartbeatAge: 1.49))
        let stopped: [FrameRingProducerState?] = [nil, .idle, .paused, .finished, .failed]
        for state in stopped {
            #expect(!BroadcastContinuity.canAdvanceStill(state: state, heartbeatAge: 0))
        }
        for age in [-1.0, 1.5, 3.0, Double.infinity, Double.nan] {
            #expect(!BroadcastContinuity.canAdvanceStill(state: .running, heartbeatAge: age))
        }
    }

    @Test("Known losses revoke still-screen evidence until another valid image is delivered")
    func lostStillBaseline() {
        var continuity = BroadcastContinuity()
        func eligible(_ value: BroadcastContinuity) -> Bool {
            value.mayAdvanceStill(state: .running, heartbeatAge: 0)
        }
        #expect(!eligible(continuity), "a heartbeat before any image proves nothing")
        _ = continuity.frame(arrival: 1, losses: 0)
        continuity.deliveredFrame()
        #expect(eligible(continuity))
        // A rejected/torn ring slot can be the last event before silence.
        continuity.noteLosses(1)
        #expect(!eligible(continuity), "fresh heartbeats cannot restore missing pixels")
        continuity.noteLosses(1)
        #expect(!eligible(continuity))
        #expect(continuity.frame(arrival: 2, losses: 1).continuityBroken)
        #expect(!eligible(continuity), "reading a frame is not yet successful delivery")
        continuity.deliveredFrame()
        #expect(eligible(continuity))
        // The same revocation covers remaps, sessions, pauses, failed sample
        // creation and queue admission failures, all of which interrupt().
        continuity.interrupt()
        #expect(!eligible(continuity))
        _ = continuity.frame(arrival: 3, losses: 1)
        continuity.interrupt() // sampleBuffer(for:) failed
        #expect(!eligible(continuity))
        _ = continuity.frame(arrival: 4, losses: 1)
        continuity.deliveredFrame()
        #expect(eligible(continuity))
        #expect(!continuity.mayAdvanceStill(state: .paused, heartbeatAge: 0))
        #expect(!continuity.mayAdvanceStill(state: .running, heartbeatAge: 1.5))
    }

    @Test("A pause between frames is not a break by itself: a still screen may deliver nothing")
    func silenceIsNotABreak() {
        var continuity = BroadcastContinuity()
        #expect(continuity.frame(arrival: 10, losses: 0) == .init(gapMilliseconds: nil, continuityBroken: false))
        let later = continuity.frame(arrival: 14.5, losses: 0)
        #expect(later.gapMilliseconds == 4500)
        #expect(!later.continuityBroken)
    }

    @Test("Frames lost in the ring break continuity once, at the next frame")
    func losses() {
        var continuity = BroadcastContinuity()
        _ = continuity.frame(arrival: 1, losses: 0)
        #expect(continuity.frame(arrival: 1.05, losses: 2).continuityBroken)
        #expect(!continuity.frame(arrival: 1.10, losses: 2).continuityBroken)
    }

    @Test("An interruption between frames breaks the next one only")
    func interruption() {
        var continuity = BroadcastContinuity()
        _ = continuity.frame(arrival: 1, losses: 0)
        continuity.interrupt()
        #expect(continuity.frame(arrival: 1.05, losses: 0).continuityBroken)
        #expect(!continuity.frame(arrival: 1.10, losses: 0).continuityBroken)
    }
}
