import Testing

@Suite("Capture counters")
struct CaptureCountersTests {
    @Test("Frames are counted by status, and only a new picture counts as changed")
    func counts() {
        var counters = CaptureCounters()
        let changes = [counters.count(.complete, hash: 7),
                       counters.count(.complete, hash: 7),   // the same picture again
                       counters.count(.idle, hash: 0),       // no hash: unknown, not a change
                       counters.count(.complete, hash: 9),
                       counters.count(.blank, hash: 9)]
        #expect(changes == [true, false, false, true, false])
        #expect(counters.frames == 5)
        #expect(counters.completeFrames == 3)
        #expect(counters.idleFrames == 1)
        #expect(counters.changedFrames == 2)
    }
}
