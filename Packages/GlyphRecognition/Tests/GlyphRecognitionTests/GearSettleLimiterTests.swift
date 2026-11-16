import Testing
import GlyphRecognition

/// The `gearSettle` cut's limiter: which gear reads due on a settled panel
/// it answers with the settling read, and everything that sends the panel
/// back to being read.
@Suite("Gear settle limiter")
struct GearSettleLimiterTests {
    private static let bounds = GearDropPanelBounds(top: 0.286, bottom: 0.455)
    private static let region = PanelRegion(left: 38, top: 549, width: 1004, height: 325)

    /// A grid of one grey level everywhere: two such grids differ by the
    /// difference of their levels.
    private static func signature(_ grey: Int, frameWidth: Int = 1080, frameHeight: Int = 1920) -> StillSignature? {
        StillSignature(columns: GearSettleLimiter.columns, rows: GearSettleLimiter.rows,
                       width: GearSettleLimiter.columns, height: GearSettleLimiter.rows,
                       frameWidth: frameWidth, frameHeight: frameHeight) { _, left, right in (right - left) * grey }
    }

    private static func read(at time: Double, stage: GearDropStage = .bonus) -> GearDropFrameEvidence {
        GearDropFrameEvidence(sourceTime: time, stage: stage, bounds: bounds,
                              entries: [GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known,
                                                      level: 5, quantity: 3)],
                              effects: ["ITO EN (+)"])
    }

    /// Settled on a read of the frame at 10 s, grey 100.
    private static func settled() -> GearSettleLimiter {
        var limiter = GearSettleLimiter()
        limiter.accept(read(at: 10), settled: true, signature: signature(100), region: region, bounds: bounds)
        return limiter
    }

    /// One analysed frame's look; the tracker calls the panel settled
    /// unless told otherwise.
    private static func look(_ limiter: inout GearSettleLimiter, at time: Double, settled: Bool = true,
                             signature: StillSignature?? = nil,
                             bounds: GearDropPanelBounds?? = nil) -> GearDropFrameEvidence? {
        limiter.look(at: time, settled: settled, signature: signature ?? Self.signature(100),
                     bounds: bounds ?? Self.bounds)
    }

    @Test("A settled, still panel's read is issued again at the due frame's time, with its rows")
    func issuesSettledRead() throws {
        var limiter = Self.settled()
        #expect(limiter.isSettled && limiter.region == Self.region)
        let first = Self.look(&limiter, at: 10.2, signature: Self.signature(101))
        let issued = try #require(first)
        #expect(issued == Self.read(at: 10).at(sourceTime: 10.2))
        #expect(issued.sourceTime == 10.2 && issued.entries == Self.read(at: 10).entries && issued.stage == .bonus)
        let second = Self.look(&limiter, at: 10.4)
        #expect(second?.sourceTime == 10.4)
    }

    @Test("A read that leaves the panel unsettled, or of no panel, or without a signature anchors nothing")
    func onlySettledReadsAnchor() {
        var unsettled = GearSettleLimiter()
        unsettled.accept(Self.read(at: 10), settled: false, signature: Self.signature(100), region: Self.region,
                         bounds: Self.bounds)
        let unsettledLook = Self.look(&unsettled, at: 10.2)
        #expect(!unsettled.isSettled && unsettledLook == nil)

        var noPanel = GearSettleLimiter()
        noPanel.accept(Self.read(at: 10, stage: .unknown), settled: true, signature: Self.signature(100),
                       region: Self.region, bounds: Self.bounds)
        #expect(!noPanel.isSettled)

        var unsigned = GearSettleLimiter()
        unsigned.accept(Self.read(at: 10), settled: true, signature: nil, region: Self.region, bounds: Self.bounds)
        #expect(!unsigned.isSettled)

        var timeless = GearSettleLimiter()
        timeless.accept(Self.read(at: .nan), settled: true, signature: Self.signature(100), region: Self.region,
                        bounds: Self.bounds)
        #expect(!timeless.isSettled)

        var unsettledLater = Self.settled()
        unsettledLater.accept(Self.read(at: 10.4), settled: false, signature: Self.signature(100),
                              region: Self.region, bounds: Self.bounds)
        #expect(!unsettledLater.isSettled, "A later read that unsettles the panel ends the anchor")
    }

    @Test("Pixels that change beyond the tolerance send the panel back to reading until it settles again")
    func changeEndsTheAnchor() {
        var limiter = Self.settled()
        let edge = Int(GearSettleLimiter.tolerance)
        let atTolerance = Self.look(&limiter, at: 10.1, signature: Self.signature(100 + edge))
        #expect(atTolerance != nil, "At the tolerance the panel is still")
        let beyond = Self.look(&limiter, at: 10.2, signature: Self.signature(100 + edge + 1))
        #expect(beyond == nil && !limiter.isSettled)
        let stillAgain = Self.look(&limiter, at: 10.3)
        #expect(stillAgain == nil, "Still again is not enough: only a new settling read anchors")
        limiter.accept(Self.read(at: 10.4), settled: true, signature: Self.signature(100), region: Self.region,
                       bounds: Self.bounds)
        let reArmed = Self.look(&limiter, at: 10.6)
        #expect(reArmed?.sourceTime == 10.6, "A new settling read re-arms it")
    }

    @Test("Bounds that move by more than the new-panel shift, or leave, end the anchor")
    func boundsEndTheAnchor() {
        var limiter = Self.settled()
        let jitter = Self.look(&limiter, at: 10.1, bounds: GearDropPanelBounds(top: 0.289, bottom: 0.452))
        #expect(jitter != nil, "Sparks move a resting panel's bounds by up to 0.003")
        let moved = Self.look(&limiter, at: 10.2, bounds: GearDropPanelBounds(
            top: 0.286, bottom: 0.455 + GearSettleLimiter.boundsTolerance + 0.001))
        #expect(moved == nil && !limiter.isSettled)

        var gone = Self.settled()
        let goneLook = Self.look(&gone, at: 10.1, bounds: .some(nil))
        #expect(goneLook == nil && !gone.isSettled)

        var nonFinite = Self.settled()
        let nonFiniteLook = Self.look(&nonFinite, at: 10.1, bounds: GearDropPanelBounds(top: .nan, bottom: 0.455))
        #expect(nonFiniteLook == nil && !nonFinite.isSettled)
    }

    @Test("The tracker calling the panel unsettled, a missing signature or a reset ends the anchor")
    func reArmReasons() {
        var unsettled = Self.settled()
        let unsettledLook = Self.look(&unsettled, at: 10.1, settled: false)
        #expect(unsettledLook == nil && !unsettled.isSettled)

        var unsigned = Self.settled()
        let unsignedLook = Self.look(&unsigned, at: 10.1, signature: .some(nil))
        #expect(unsignedLook == nil && !unsigned.isSettled)

        var otherFrame = Self.settled()
        let otherFrameLook = Self.look(&otherFrame, at: 10.1,
                                       signature: Self.signature(100, frameWidth: 1170, frameHeight: 2532))
        #expect(otherFrameLook == nil && !otherFrame.isSettled, "Another frame size is never still")

        var reset = Self.settled()
        reset.reset()
        let resetLook = Self.look(&reset, at: 10.1)
        #expect(resetLook == nil && !reset.isSettled)
    }

    @Test("A settling read over a second old is not issued: the next due read is real, the anchor kept")
    func safetyInterval() {
        var limiter = Self.settled()
        let atLimit = Self.look(&limiter, at: 10 + GearSettleLimiter.refreshAfter)
        #expect(atLimit != nil)
        let pastLimit = Self.look(&limiter, at: 10 + GearSettleLimiter.refreshAfter + 0.05)
        #expect(pastLimit == nil && limiter.isSettled, "Age alone ends nothing: the real read settles it again")
        let changed = Self.look(&limiter, at: 11.1, signature: Self.signature(110))
        #expect(changed == nil && !limiter.isSettled, "Its frames are still compared, and a change still ends it")

        var refreshed = Self.settled()
        refreshed.accept(Self.read(at: 11.2), settled: true, signature: Self.signature(100), region: Self.region,
                         bounds: Self.bounds)
        let afterRefresh = Self.look(&refreshed, at: 11.4)
        #expect(afterRefresh?.sourceTime == 11.4)
    }

    @Test("A time that is not finite, or goes back, ends the anchor")
    func timesOutOfOrder() {
        var nonFinite = Self.settled()
        let nonFiniteLook = Self.look(&nonFinite, at: .infinity)
        #expect(nonFiniteLook == nil && !nonFinite.isSettled)

        var beforeRead = Self.settled()
        let beforeReadLook = Self.look(&beforeRead, at: 9.9)
        #expect(beforeReadLook == nil && !beforeRead.isSettled)

        var backwards = Self.settled()
        let forwards = Self.look(&backwards, at: 10.4)
        let back = Self.look(&backwards, at: 10.2)
        #expect(forwards != nil && back == nil && !backwards.isSettled)
    }

    @Test("The region is the reader's rectangle of the panel's rows, clamped to the frame")
    func region() throws {
        let region = try #require(GearSettleLimiter.region(Self.bounds, width: 1080, height: 1920))
        #expect(region == PanelRegion(left: 37, top: 549, width: 1006, height: 325))
        let clamped = try #require(GearSettleLimiter.region(GearDropPanelBounds(top: -0.1, bottom: 1.2),
                                                            width: 100, height: 200))
        #expect(clamped.top == 0 && clamped.height == 200)
        #expect(GearSettleLimiter.region(GearDropPanelBounds(top: 0.5, bottom: 0.5), width: 100, height: 200)
                == nil)
        #expect(GearSettleLimiter.region(GearDropPanelBounds(top: .nan, bottom: 0.5), width: 100, height: 200)
                == nil)
    }
}
