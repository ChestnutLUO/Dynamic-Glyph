import Testing

@Suite("Live Activity update schedule")
struct ActivityUpdateScheduleTests {
    @Test("A returned observation cancels an obsolete pending change")
    func returnsToDisplayedState() {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "A", at: 0)
        #expect(schedule.offer("obsolete B", key: "B", freshUntil: nil, at: 0.1) != nil)
        #expect(schedule.offer("current A", key: "A", freshUntil: nil, at: 0.2) == nil)
        #expect(schedule.take(at: 0.4) == nil)
    }

    @Test("The newest observation replaces a change held by the throttle")
    func newestWins() {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "A", at: 0)
        _ = schedule.offer("B", key: "B", freshUntil: nil, at: 0.1)
        _ = schedule.offer("C", key: "C", freshUntil: nil, at: 0.2)
        #expect(schedule.take(at: 0.39) == nil)
        #expect(schedule.take(at: 0.4)?.content == "C")
        #expect(schedule.take(at: 0.8) == nil)
    }

    @Test("Watching for gear is renewed every 10 s, so a stopped capture lapses within 30 s")
    func watchingRenewsSlowly() throws {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "watching", at: 0)
        var sentAt: [Double] = []
        for tick in 1...600 {
            let now = Double(tick) / 20
            if let delay = schedule.offer("watching", key: "watching", freshUntil: now + 30, at: now, pace: .watching),
               delay == 0 {
                let pending = schedule.take(at: now)
                _ = try #require(pending)
                schedule.sendFinished()
                sentAt.append(now)
            }
        }
        #expect(sentAt == [10, 20, 30])
    }

    @Test("Fresh observations renew unchanged guidance through a long input slot")
    func freshGuidanceKeepsUpdating() throws {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "draw A", at: 0)
        var sentAt: [Double] = []
        for tick in 1...100 {
            let now = Double(tick) / 20
            if let delay = schedule.offer("draw A", key: "draw A", freshUntil: now + 3, at: now), delay == 0 {
                let pending = schedule.take(at: now)
                let update = try #require(pending)
                #expect(update.freshUntil == now + 3)
                schedule.sendFinished()
                sentAt.append(now)
            }
        }
        #expect(sentAt == [1, 2, 3, 4, 5], "renew once a second, not once per frame")
        // A timer alone must not replay the last observation as fresh evidence.
        #expect(schedule.take(at: 10) == nil)
    }

    @Test("Delayed guidance expires with its evidence, not with its send time")
    func delayedExpiry() throws {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "A", at: 0)
        _ = schedule.offer("B", key: "B", freshUntil: 3.1, at: 0.1)
        let pending = schedule.take(at: 0.4)
        #expect(try #require(pending).freshUntil == 3.1)
        _ = schedule.offer("C", key: "C", freshUntil: 3.5, at: 0.5)
        #expect(schedule.take(at: 4) == nil)
        #expect(schedule.offer("C", key: "C", freshUntil: 3.5, at: 4) == nil)
    }

    @Test("While the player draws, a change is prompt but unchanged guidance renews only every 1.5 seconds")
    func fasterDuringInput() throws {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "draw A", at: 0)
        schedule.sendFinished()
        // The standard pace would hold this for 0.4 s.
        let offered = schedule.offer("draw B", key: "draw B", freshUntil: 3, at: 0.05, pace: .input)
        #expect(abs(try #require(offered) - 0.1) < 1e-9)
        #expect(schedule.take(at: 0.14) == nil)
        let drawB = schedule.take(at: 0.15)
        #expect(try #require(drawB).content == "draw B")
        schedule.sendFinished()

        var sentAt: [Double] = []
        for tick in 4...40 {
            let now = Double(tick) / 20
            if schedule.offer("draw B", key: "draw B", freshUntil: now + 3, at: now, pace: .input) == 0,
               schedule.take(at: now) != nil {
                schedule.sendFinished()
                sentAt.append(now)
            }
        }
        #expect(sentAt == [1.65], "renew before expiry without reanimating unchanged glyphs")
    }

    @Test("Only one update is outstanding, and the newest goes next")
    func oneInFlight() throws {
        var schedule = ActivityUpdateSchedule<String>()
        #expect(schedule.offer("A", key: "A", freshUntil: nil, at: 0, pace: .input) == 0)
        let first = schedule.take(at: 0)
        #expect(try #require(first).content == "A")
        _ = schedule.offer("B", key: "B", freshUntil: nil, at: 0.2, pace: .input)
        _ = schedule.offer("C", key: "C", freshUntil: nil, at: 0.3, pace: .input)
        // A has not been acknowledged: nothing else is sent, and C is kept.
        #expect(schedule.take(at: 0.3) == nil)
        #expect(schedule.pending?.content == "C")
        schedule.sendFinished()
        #expect(schedule.delayUntilDue(at: 0.35) == 0)
        let next = schedule.take(at: 0.35)
        #expect(try #require(next).content == "C")
    }

    @Test("Content without guidance needs no heartbeat and reset discards pending work")
    func noGuidanceAndReset() {
        var schedule = ActivityUpdateSchedule<String>()
        schedule.didSend(key: "waiting", at: 0)
        #expect(schedule.offer("waiting", key: "waiting", freshUntil: nil, at: 20) == nil)
        _ = schedule.offer("drawing", key: "drawing", freshUntil: 23, at: 20)
        schedule = ActivityUpdateSchedule()
        #expect(schedule.take(at: 21) == nil)
        #expect(schedule.offer("waiting", key: "waiting", freshUntil: nil, at: 21) == 0)
    }
}
