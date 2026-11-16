/// Where the game's phase evidence sits, as fractions of the delivered frame.
///
/// Every number here was measured, not guessed, from 603 x 1311 captures of the
/// English portrait layout: the eight recording fixtures in
/// `Fixtures/Recording/` and the screenshots of a field session.
/// `GameUILayoutTests` re-measures them, so a changed layout fails a test
/// instead of silently mis-cropping.
///
/// Fractions rather than pixels because the capture resolution is chosen by the
/// system and has already differed between runs. They are *not* claimed to hold
/// for other languages, landscape, or devices without a Dynamic Island; a
/// caller that cannot validate the layout should report an unknown phase rather
/// than read these regions anyway.
public struct GameUILayout: Sendable, Equatable {
    /// Below the status bar and the Dynamic Island cut-out. The island's
    /// recording ring reaches 0.059 in the field captures, and the header's
    /// cap height starts at 0.066, so the crop starts between them.
    public var headerTextTop = 0.060
    /// Header descenders end at 0.099; the slot indicators start at 0.102.
    public var headerTextBottom = 0.104

    /// The row of 2-5 hexagonal slot indicators. Their glow spans 0.107-0.169;
    /// the band starts below the header's separator rule at 0.101.
    public var slotStripTop = 0.104
    public var slotStripBottom = 0.176

    /// The player-input countdown bar, measured at 0.230-0.234.
    public var inputTimerBarTop = 0.218
    public var inputTimerBarBottom = 0.246
    /// The centred progress shrinks to a few percent of the frame before
    /// expiring. The complete violet rail and both endpoints are required too.
    public var inputTimerBarMinimumWidth = 0.03

    /// A slot indicator measured 78-82 px wide in 603 px frames (0.129-0.136).
    public var slotMarkerMinimumWidth = 0.085
    public var slotMarkerMaximumWidth = 0.190
    /// Columns need this many marker pixels before they count as part of an
    /// indicator, which rejects single-pixel colour noise.
    public var slotMarkerMinimumColumnHits = 3
    /// Indicator centres are evenly pitched (96.3 px at 603 px wide). A row
    /// whose spacing disagrees by more than this is not the game's strip.
    public var slotPitchTolerance = 0.18
    /// Four- and five-slot recordings both use a centred row with 96 px pitch
    /// in 603 px frames. A surviving fragment must not become a shorter row.
    public var slotCenterPitch = 0.16
    public var slotCenterTolerance = 0.035

    /// Both ends of the countdown track remain visible as it drains: gold
    /// progress over a violet rail. Require that rail's measured placement,
    /// not just a long gold run that could be the edge of a floating window.
    public var inputTimerTrackLeft = 0.11
    public var inputTimerTrackRight = 0.89
    public var inputTimerEndpointTolerance = 0.035

    /// A notification banner over the strip lit at least 0.85 of the columns
    /// of every covered row in a field recording; four indicators
    /// with the gold glow lit at most 0.24. Five indicators stay well below.
    public var bannerMinimumRowCoverage = 0.75
    /// Shorter runs of lit rows at the top of the strip are the lower edge of
    /// a window just above it: skipped, but not a reason to accept shortened
    /// indicators.
    public var bannerMinimumHeight = 0.004
    /// Below a banner, each indicator must still show this much of its height
    /// relative to its width. The pointed hexagon keeps its full width from its
    /// vertical sides down; 0.60 was visible in the field recording.
    public var coveredMarkerMinimumHeight = 0.4

    /// Rows allowed for the banner's shadowed lower edge, about 2 px in a
    /// 1218 px frame.
    func bannerEdgeTolerance(frameHeight: Int) -> Int {
        max(1, Int((0.002 * Double(frameHeight)).rounded(.up)))
    }

    /// Columns at each side of the frame that no slot indicator can reach
    /// (`margin`) or start in (`zone`), less a hundredth of the width (6 px
    /// at 603) spare for antialiasing and rounding.
    ///
    /// The outer indicators of a full row are centred at most (n - 1) / 2 x
    /// `slotCenterPitch` + `slotCenterTolerance` from the centre, and each is
    /// between `slotMarkerMinimumWidth` and `slotMarkerMaximumWidth` wide.
    /// With the defaults and five slots, no indicator comes within 0.05 of the
    /// width of either edge (0.5 - 0.32 - 0.035 - 0.095), so `margin` is 0.04.
    /// None starts within 0.1875 of the right edge, or ends within 0.1875 of
    /// the left (0.5 - 0.32 - 0.035 + 0.0425), so `zone` is 0.1775. The
    /// measured row's outer indicators lie from 0.115 to 0.885.
    ///
    /// A run of indicator-coloured columns wholly within `zone` of an edge
    /// holds no whole indicator, and one that reaches into `margin` holds
    /// something that is no part of one: an object at the screen's edge, such
    /// as a tucked floating window's tab.
    func slotEdgeColumns(frameWidth: Int, maximumSlots: Int) -> (margin: Int, zone: Int) {
        let allowance = 0.01
        let outerCentre = 0.5 - Double(maximumSlots - 1) / 2 * slotCenterPitch - slotCenterTolerance
        let width = Double(frameWidth)
        let margin = Int((outerCentre - slotMarkerMaximumWidth / 2 - allowance) * width)
        let zone = Int((outerCentre + slotMarkerMinimumWidth / 2 - allowance) * width)
        return (max(0, margin), max(0, zone))
    }

    /// The whole band a caller must decode in colour to use this layout.
    public var topBandBottom: Double { inputTimerBarBottom }

    public init() {}

    /// Whether the detected array sits below every region read here. A fit that
    /// overlaps the header means the frame is not the layout these fractions
    /// describe, and the phase must be reported unknown.
    public func isConsistent(with fit: NodeArrayDetection) -> Bool {
        fit.imageHeight > 0 && fit.origin.y > topBandBottom * Double(fit.imageHeight)
    }
}
