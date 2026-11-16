import Testing
@testable import GlyphRecognition

@Suite("Portal reads stop once a screen's levels have settled")
struct PortalReadLimiterTests {
    private static func read(_ time: Double, _ levels: [Int], unread: Int = 0, hue: Double? = 259,
                             faction: PortalFaction? = .resistance) -> PortalScreenEvidence {
        PortalScreenEvidence(sourceTime: time, resonators: levels, unreadSlots: unread, badgeHue: hue,
                             faction: faction)
    }

    /// A screen that shows from `start` at 20 Hz until `end`, exactly.
    private static func show(_ limiter: inout PortalReadLimiter, from start: Double, to end: Double,
                             faction: PortalFaction = .resistance) {
        let steps = Int(((end - start) / 0.05).rounded())
        for step in 0...steps {
            limiter.candidate(at: step == steps ? end : start + Double(step) * 0.05, faction: faction)
        }
    }

    @Test("One complete read with a badge naming its level settles the screen; the next screen is read")
    func decisiveRead() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 0.5)
        #expect(limiter.wantsRead(at: 0.5))
        limiter.accept(Self.read(0.2, Array(repeating: 8, count: 8)))
        #expect(limiter.isSettled)
        Self.show(&limiter, from: 0.55, to: 3)
        #expect(!limiter.wantsRead(at: 3))
        // Gone for longer than the observer's same-screen window: whatever
        // shows next is another screen.
        limiter.absent(at: 3.5)
        #expect(!limiter.wantsRead(at: 3.5), "a screen gone for half a second may still be the same one")
        limiter.absent(at: 4.6)
        #expect(limiter.wantsRead(at: 4.6) && !limiter.isSettled)
        limiter.candidate(at: 4.65, faction: .resistance)
        #expect(limiter.wantsRead(at: 4.65))
    }

    @Test("A read that leaves the level open, or whose badge does not confirm one level, does not settle alone",
          arguments: [
            (Array(repeating: 8, count: 7), 1, 259) as ([Int], Int, Double?),
            (Array(repeating: 8, count: 8), 0, nil),
            // L1's badge is not calibrated: its hue allows L1 to L4.
            (Array(repeating: 1, count: 8), 0, 30),
            // The ring says L6, the badge L8.
            ([6, 6, 6, 6, 6, 6, 6, 6], 0, 259)
          ])
    func openRead(_ levels: [Int], _ unread: Int, _ hue: Double?) {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 0.3)
        limiter.accept(Self.read(0.1, levels, unread: unread, hue: hue))
        #expect(!limiter.isSettled && limiter.wantsRead(at: 0.3))
    }

    @Test("Two reads in a row that agree settle the screen, whatever order the labels came in")
    func agreeingReads() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 1)
        limiter.accept(Self.read(0.2, [7, 6, 8, 6], unread: 4, hue: 300))
        #expect(!limiter.isSettled)
        limiter.accept(Self.read(0.6, [6, 6, 7, 8], unread: 4, hue: 294))
        #expect(limiter.isSettled && !limiter.wantsRead(at: 1))
    }

    @Test("Reads that differ in levels, unread labels, badge or faction, or lack a badge, keep the screen read",
          arguments: [
            PortalScreenEvidence(sourceTime: 0.6, resonators: [6, 6, 7, 7], unreadSlots: 4, badgeHue: 300,
                                 faction: .resistance),
            PortalScreenEvidence(sourceTime: 0.6, resonators: [7, 6, 8, 6], unreadSlots: 3, badgeHue: 300,
                                 faction: .resistance),
            PortalScreenEvidence(sourceTime: 0.6, resonators: [7, 6, 8, 6], unreadSlots: 4, badgeHue: 308,
                                 faction: .resistance),
            PortalScreenEvidence(sourceTime: 0.6, resonators: [7, 6, 8, 6], unreadSlots: 4, badgeHue: nil,
                                 faction: .resistance),
            PortalScreenEvidence(sourceTime: 0.6, resonators: [7, 6, 8, 6], unreadSlots: 4, badgeHue: 300,
                                 faction: nil)
          ])
    func disagreeingReads(_ second: PortalScreenEvidence) {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 1)
        limiter.accept(Self.read(0.2, [7, 6, 8, 6], unread: 4, hue: 300))
        limiter.accept(second)
        #expect(!limiter.isSettled && limiter.wantsRead(at: 1))
    }

    @Test("Two reads without a badge never agree: the labels were still fading in")
    func fadingInWithoutBadge() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 1)
        // A recorded clip: [1, 1, 6, 6] twice with no badge, then six labels.
        limiter.accept(Self.read(0.2, [1, 1, 6, 6], unread: 4, hue: nil))
        limiter.accept(Self.read(0.4, [1, 1, 6, 6], unread: 4, hue: nil))
        #expect(!limiter.isSettled)
        #expect(!PortalReadLimiter.agree(Self.read(0, [], hue: 259), Self.read(1, [], hue: 259)),
                "two reads of no labels at all agree on nothing")
    }

    @Test("Two reads with a badge still fading in never agree: its hue names no level yet")
    func fadingInBadge() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 2)
        // The primary recording: an L8 badge at 236° and 238° with two labels,
        // then 254° with two labels again and later seven.
        limiter.accept(Self.read(0.25, [8, 8], unread: 6, hue: 235.6))
        limiter.accept(Self.read(0.5, [8, 8], unread: 6, hue: 237.5))
        #expect(!limiter.isSettled)
        limiter.accept(Self.read(0.75, [8, 8], unread: 6, hue: 254.7))
        #expect(!limiter.isSettled, "17° from the read before")
        limiter.accept(Self.read(1, [8, 8], unread: 6, hue: 254.5))
        #expect(limiter.isSettled)
    }

    @Test("Another faction's screen is another screen, read afresh")
    func factionChange() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 0.5)
        limiter.accept(Self.read(0.2, Array(repeating: 8, count: 8)))
        #expect(!limiter.wantsRead(at: 0.5))
        limiter.candidate(at: 0.55, faction: .enlightened)
        #expect(limiter.wantsRead(at: 0.55) && !limiter.isSettled)
        // A late read of the old screen does not settle the new one.
        limiter.accept(Self.read(0.3, Array(repeating: 8, count: 8)))
        limiter.accept(Self.read(0.6, Array(repeating: 8, count: 8), faction: .resistance))
        #expect(!limiter.isSettled)
        limiter.accept(Self.read(0.6, Array(repeating: 8, count: 8), faction: .enlightened))
        #expect(limiter.isSettled)
    }

    @Test("A reset, as on lost continuity or a hack claiming its screen, reads the screen afresh")
    func reset() {
        var limiter = PortalReadLimiter()
        Self.show(&limiter, from: 0, to: 0.5)
        limiter.accept(Self.read(0.2, Array(repeating: 8, count: 8)))
        limiter.reset()
        #expect(limiter.wantsRead(at: 0.5) && !limiter.isSettled)
        limiter.candidate(at: 0.55, faction: .resistance)
        // A read from before the reset belongs to no current screen.
        limiter.accept(Self.read(0.3, Array(repeating: 8, count: 8)))
        #expect(!limiter.isSettled && limiter.wantsRead(at: 0.6))
    }

    @Test("Reads out of order, before the screen, or at no time are ignored; a clock going back ends the screen")
    func strayReads() {
        var limiter = PortalReadLimiter()
        limiter.accept(Self.read(0, Array(repeating: 8, count: 8)))
        #expect(!limiter.isSettled, "no screen yet")
        Self.show(&limiter, from: 1, to: 2)
        limiter.accept(Self.read(0.9, Array(repeating: 8, count: 8)))
        limiter.accept(Self.read(.nan, Array(repeating: 8, count: 8)))
        limiter.accept(Self.read(.infinity, Array(repeating: 8, count: 8)))
        #expect(!limiter.isSettled)
        limiter.accept(Self.read(1.5, [7, 6, 8, 6], unread: 4, hue: 300))
        limiter.accept(Self.read(1.2, [7, 6, 8, 6], unread: 4, hue: 300))
        #expect(!limiter.isSettled, "a read older than the last one does not agree with it")
        limiter.accept(Self.read(1.8, [7, 6, 8, 6], unread: 4, hue: 300))
        #expect(limiter.isSettled && !limiter.wantsRead(at: 2))
        #expect(limiter.wantsRead(at: .nan), "no time, no withholding")
        limiter.absent(at: 1.9)
        #expect(limiter.wantsRead(at: 1.9) && !limiter.isSettled)
        Self.show(&limiter, from: 3, to: 3.5)
        limiter.accept(Self.read(3.1, Array(repeating: 8, count: 8)))
        limiter.candidate(at: .nan, faction: .resistance)
        #expect(!limiter.isSettled && limiter.wantsRead(at: 3.6))
    }

    @Test("A settled screen held on is read again before its reading would be too old to attach to a hack")
    func refresh() {
        var limiter = PortalReadLimiter()
        let refresh = limiter.refreshAfter
        #expect(refresh == PortalLevelObserver.Policy().attachWindow / 2)
        Self.show(&limiter, from: 0, to: 0.5)
        limiter.accept(Self.read(0.2, Array(repeating: 8, count: 8)))
        Self.show(&limiter, from: 0.55, to: 0.15 + refresh)
        #expect(!limiter.wantsRead(at: 0.15 + refresh))
        Self.show(&limiter, from: 0.2 + refresh, to: 0.3 + refresh)
        #expect(limiter.wantsRead(at: 0.3 + refresh))
        // The refreshing read starts the reading afresh: an open read leaves
        // the screen unsettled, an agreeing second one settles it again.
        limiter.accept(Self.read(0.3 + refresh, [7, 6, 8, 6], unread: 4, hue: 300))
        #expect(!limiter.isSettled && limiter.wantsRead(at: 0.35 + refresh))
        limiter.accept(Self.read(0.5 + refresh, [7, 6, 8, 6], unread: 4, hue: 300))
        #expect(limiter.isSettled && !limiter.wantsRead(at: 0.55 + refresh))
    }

    /// A screen held for 17 s, as in a field session, with reads taking
    /// 0.7 s and offered whenever the lane is free: the observer's claim
    /// at the hack is the same level with the limiter as without, and
    /// never too old to attach.
    @Test("A long-held screen still attaches to its hack, with far fewer reads")
    func longHeldScreen() throws {
        func run(limited: Bool) -> (reads: Int, claim: PortalScreenEvidence?) {
            var limiter = PortalReadLimiter(), observer = PortalLevelObserver()
            var pending: PortalScreenEvidence?, reads = 0
            var time = 0.0
            while time <= 17 + 1e-9 {
                if let read = pending, time >= read.sourceTime + 0.7 {
                    observer.accept(read)
                    if limited { limiter.accept(read) }
                    pending = nil
                }
                if limited { limiter.candidate(at: time, faction: .resistance) }
                if pending == nil, !limited || limiter.wantsRead(at: time) {
                    pending = Self.read(time, Array(repeating: 8, count: 8))
                    reads += 1
                }
                time += 0.05
            }
            // The command screen, then the hack's first Glyph 4 s later.
            return (reads, observer.claim(at: 21))
        }
        let all = run(limited: false), limited = run(limited: true)
        let claim = try #require(limited.claim)
        #expect(claim.resonators == Array(repeating: 8, count: 8))
        #expect(PortalLevelRules.estimate(screen: claim, glyphCount: 5)
                == PortalLevelRules.estimate(screen: try #require(all.claim), glyphCount: 5))
        #expect(limited.reads * 4 < all.reads, "\(limited.reads) reads against \(all.reads)")
    }
}
