import Testing
import GlyphRecognition

/// The `resultSettle` cut's limiter: a complete result read the same twice is
/// issued again while its panel stays still, and everything else reads.
@Suite("Result settle limiter")
struct ResultSettleLimiterTests {
    private static let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 3,
                                                   glyphs: ["see", "truth", "see"])
    private static let region = PanelRegion(left: 0, top: 211, width: 1080, height: 980)

    private static func signature(_ grey: Int, frameWidth: Int = 1080) -> StillSignature? {
        StillSignature(columns: ResultSettleLimiter.columns, rows: ResultSettleLimiter.rows,
                       width: ResultSettleLimiter.columns, height: ResultSettleLimiter.rows,
                       frameWidth: frameWidth, frameHeight: 1920) { _, left, right in (right - left) * grey }
    }

    private static func read(at time: Double, hackingBonus: Int? = 163, appearances: [ResultSlotAppearance] =
                                 [.gold, .gold, .gold], context: ResultReadContext = context,
                             panelPresent: Bool = true) -> ResultFrameEvidence {
        ResultFrameEvidence(context: context, sourceTime: time, panelPresent: panelPresent, stageIndex: nil,
                            hackingBonus: hackingBonus, speedBonus: 54, appearances: appearances,
                            lines: [ResultTextLine(text: "HACKING BONUS", confidence: time, x: 0.1, y: 0.5,
                                                   width: 0.3, height: 0.02)],
                            labelLanguage: .english)
    }

    /// Two agreeing complete reads, at 10.0 and 10.2 s, the second anchored
    /// on grey 100.
    private static func settled() -> ResultSettleLimiter {
        var limiter = ResultSettleLimiter()
        limiter.accept(read(at: 10), complete: true, signature: signature(100), region: region)
        limiter.accept(read(at: 10.2), complete: true, signature: signature(100), region: region)
        return limiter
    }

    private static func look(_ limiter: inout ResultSettleLimiter, at time: Double, grey: Int? = 100,
                             context: ResultReadContext? = context,
                             panelCandidate: Bool = true) -> ResultFrameEvidence? {
        limiter.look(at: time, context: context, panelCandidate: panelCandidate,
                     signature: grey.flatMap { signature($0) })
    }

    @Test("A complete result read the same twice is issued again at the due frame's time")
    func issuesSettledRead() throws {
        var limiter = Self.settled()
        #expect(limiter.isSettled && limiter.region == Self.region)
        let looked = Self.look(&limiter, at: 10.4, grey: 100 + Int(ResultSettleLimiter.tolerance))
        let issued = try #require(looked)
        #expect(issued == Self.read(at: 10.2).at(sourceTime: 10.4))
    }

    @Test("A single read, an incomplete result or two reads that disagree settle nothing")
    func needsTwoAgreeingCompleteReads() {
        var once = ResultSettleLimiter()
        once.accept(Self.read(at: 10), complete: true, signature: Self.signature(100), region: Self.region)
        #expect(!once.isSettled)

        var incomplete = ResultSettleLimiter()
        incomplete.accept(Self.read(at: 10), complete: false, signature: Self.signature(100), region: Self.region)
        incomplete.accept(Self.read(at: 10.2), complete: false, signature: Self.signature(100), region: Self.region)
        #expect(!incomplete.isSettled)

        for later in [Self.read(at: 10.2, hackingBonus: 130), Self.read(at: 10.2, appearances: [.gold, .gold, .magenta]),
                      Self.read(at: 10.2, panelPresent: false)] {
            var disagreeing = ResultSettleLimiter()
            disagreeing.accept(Self.read(at: 10), complete: true, signature: Self.signature(100), region: Self.region)
            disagreeing.accept(later, complete: true, signature: Self.signature(100), region: Self.region)
            #expect(!disagreeing.isSettled, "\(later)")
        }

        var unsigned = ResultSettleLimiter()
        unsigned.accept(Self.read(at: 10), complete: true, signature: Self.signature(100), region: Self.region)
        unsigned.accept(Self.read(at: 10.2), complete: true, signature: nil, region: Self.region)
        #expect(!unsigned.isSettled)

        var unsettledLater = Self.settled()
        unsettledLater.accept(Self.read(at: 10.4, hackingBonus: 130), complete: true, signature: Self.signature(100),
                              region: Self.region)
        #expect(!unsettledLater.isSettled, "A later read that disagrees ends the anchor")
    }

    @Test("A change beyond the tolerance, no panel, another context or a missing signature ends the anchor")
    func changeEndsTheAnchor() {
        var changed = Self.settled()
        let changedLook = Self.look(&changed, at: 10.4, grey: 100 + Int(ResultSettleLimiter.tolerance) + 1)
        let stillAgain = Self.look(&changed, at: 10.6)
        #expect(changedLook == nil && stillAgain == nil && !changed.isSettled)

        var noPanel = Self.settled()
        let noPanelLook = Self.look(&noPanel, at: 10.4, panelCandidate: false)
        #expect(noPanelLook == nil && !noPanel.isSettled)

        var other = Self.settled()
        let otherContext = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 4, glyphs: ["see"])
        let otherLook = Self.look(&other, at: 10.4, context: otherContext)
        #expect(otherLook == nil && !other.isSettled)

        var none = Self.settled()
        let noneLook = Self.look(&none, at: 10.4, context: nil)
        #expect(noneLook == nil && !none.isSettled)

        var unsigned = Self.settled()
        let unsignedLook = Self.look(&unsigned, at: 10.4, grey: nil)
        #expect(unsignedLook == nil && !unsigned.isSettled)

        var reset = Self.settled()
        reset.reset()
        let resetLook = Self.look(&reset, at: 10.4)
        #expect(resetLook == nil && !reset.isSettled)
        reset.accept(Self.read(at: 10.6), complete: true, signature: Self.signature(100), region: Self.region)
        #expect(!reset.isSettled, "A reset forgets the read before: two agreeing reads are needed again")
    }

    @Test("A last read over a second old is not issued; times out of order end the anchor")
    func safetyIntervalAndTimes() {
        var limiter = Self.settled()
        let atLimit = Self.look(&limiter, at: 10.2 + ResultSettleLimiter.refreshAfter)
        let pastLimit = Self.look(&limiter, at: 10.2 + ResultSettleLimiter.refreshAfter + 0.05)
        #expect(atLimit != nil && pastLimit == nil && limiter.isSettled)
        limiter.accept(Self.read(at: 11.3), complete: true, signature: Self.signature(100), region: Self.region)
        let refreshed = Self.look(&limiter, at: 11.5)
        #expect(refreshed?.sourceTime == 11.5, "A real read that agrees re-anchors at once")

        var nonFinite = Self.settled()
        let nonFiniteLook = Self.look(&nonFinite, at: .nan)
        #expect(nonFiniteLook == nil && !nonFinite.isSettled)

        var backwards = Self.settled()
        let forwards = Self.look(&backwards, at: 10.6)
        let back = Self.look(&backwards, at: 10.4)
        #expect(forwards != nil && back == nil && !backwards.isSettled)
    }

    @Test("The region is the result reader's band, the full width")
    func region() throws {
        let region = try #require(ResultSettleLimiter.region(width: 1080, height: 1920))
        #expect(region == PanelRegion(left: 0, top: 211, width: 1080, height: 980))
        #expect(ResultSettleLimiter.region(width: 0, height: 1920) == nil)
    }
}
