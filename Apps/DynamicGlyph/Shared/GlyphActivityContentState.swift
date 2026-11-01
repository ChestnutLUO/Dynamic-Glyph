import Foundation
import GlyphRecognition

/// The Live Activity's changing content.
///
/// Deliberately small and self-contained. The widget extension runs in its own
/// process and cannot read the app's Documents folder, so it cannot look a
/// Glyph up in the shape table; each slot therefore carries the node walk that
/// draws it — at most eight characters — and the extension needs nothing else.
/// No image buffers and no tables are ever sent.
///
/// Kept apart from `GlyphActivityAttributes` so it needs no ActivityKit and the
/// app's tests, which run where ActivityKit cannot be linked, can build it.
struct GlyphActivityContentState: Codable, Hashable {
    /// One slot, already reduced to what a renderer needs.
    struct Slot: Codable, Hashable {
        enum Provenance: String, Codable, Hashable {
            /// Held across an independently verified boundary.
            case observed
            /// Visible now, not yet part of the sequence.
            case observing
            /// From the sequence table, not seen.
            case predicted
            /// Evidence existed but did not settle.
            case uncertain
            /// The boundary passed with nothing legible.
            case missing
            /// Not reached yet, and nothing predicts it.
            case pending
        }

        var provenance: Provenance
        var name: String?
        /// The node walk, as the shape table encodes it, e.g. "0568a975".
        /// Nil when there is nothing to draw.
        var shape: String?
        var inputCheck: InputCheckDisplay? = nil

        var path: GlyphPath? { shape.flatMap(GlyphPath.init(encoded:)) }
    }

    var slots: [Slot]
    /// `TrackingState` raw value.
    var phase: String
    /// The single line the other surfaces show, built in one place so they
    /// cannot disagree about how certain the display is.
    var statusLine: String
    /// `PredictionState` raw value.
    var predictionState: String
    var candidateCount: Int
    var expectedSlotCount: Int?
    /// The Glyph to draw now and the one after it, already reduced. Empty
    /// whenever nothing honest can be said; never padded to fill the space.
    var upcoming: [Slot] = []
    /// One-based slot the player is on, present only with `upcoming`.
    var inputSlotNumber: Int?
    /// The slot indicators have been hidden, by a window or a banner, for
    /// longer than a glance between frames.
    var indicatorsObstructed = false
    /// `StatusTone` raw value: the colour of the Picture in Picture edge for
    /// the same moment, which the Island's keyline repeats.
    var statusTone = StatusTone.idle.rawValue
    var hackID: Int
    var revision: Int
    /// The display is not claiming these slots are the required sequence.
    var isProvisional: Bool
    /// The player's choice, carried here because the extension cannot read
    /// the app's settings. Off, the compact Island switches without the
    /// system's update animation, which slides it a few points on every
    /// update and read as shaking.
    var animatesUpdates = false
    /// Optional for compatibility with an activity started by an older build.
    var gear: GearDropDisplay? = nil

    var observedCount: Int { slots.filter { $0.provenance == .observed }.count }

    /// Seconds this content stays true without a newer observation, after
    /// which the Island shows it as paused; nil for waiting, which claims
    /// nothing that can go out of date. Guidance and a drop's reading last
    /// briefly. Watching for gear is a claim that capture runs, so it too
    /// lapses, but slowly: renewed every 10 s, it costs few updates between
    /// drops, and the items counted so far stay shown once it has lapsed.
    var freshnessLifetime: Double? {
        if !upcoming.isEmpty { return 3 }
        guard let gear else { return nil }
        return gear.state == .watching ? 30 : 3
    }

    /// What changing would justify sending an update. Freshness and the
    /// sample counter are deliberately absent: a Live Activity that updates
    /// twenty times a second is not a display, it is a battery drain.
    var semanticKey: String {
        "\(hackID)|\(phase)|\(predictionState)|\(candidateCount)|"
            + "\(expectedSlotCount ?? -1)|\(isProvisional)|\(statusLine)|"
            + "in:\(inputSlotNumber ?? -1)|covered:\(indicatorsObstructed)|tone:\(statusTone)|"
            + "animates:\(animatesUpdates)|"
            + "gear:\(gear?.renderKey ?? "-")|"
            + "next:" + upcoming.map { "\($0.provenance.rawValue):\($0.name ?? "-")" }.joined(separator: ",")
            + "|" + slots.map { "\($0.provenance.rawValue):\($0.name ?? "-"):\($0.inputCheck?.renderKey ?? "-")" }.joined(separator: ",")
    }

    /// What the compact and minimal Island draw, for diagnostics only: two
    /// states with the same key look the same there, so an update between
    /// them changed nothing the player could see in those presentations.
    /// Mirrors `GlyphLiveActivity`'s compactLeading, compactTrailing, minimal
    /// and keyline. Whether the activity is stale is decided on the device by
    /// its stale date; the key carries only what changes how staleness is
    /// drawn. Not used to decide whether to send.
    var compactKey: String {
        func drawn(_ slot: Slot?) -> String {
            guard let slot else { return "none" }
            return "\(slot.provenance.rawValue):\(slot.shape ?? "?")"
        }
        let common = "tone:\(statusTone)|stales:\(freshnessLifetime != nil)"
        if let gear {
            // Gear icon both sides of the Island; the trailing value becomes
            // a dash once stale unless watching.
            return "\(common)|gear:\(gear.symbol):\(gear.compactValue):\(gear.state == .watching)"
        }
        let progress = IslandProgress(self)
        let centre: String
        switch progress.centre {
        case .next: centre = "next"
        case .slot(let index): centre = "slot:" + drawn(slots[index])
        case .covered: centre = "covered"
        case .waiting(let provisional): centre = "waiting:\(provisional)"
        }
        let ring = progress.marks.map { "\($0)" }.joined(separator: ",")
        let counter = "\(observedCount)/\(expectedSlotCount.map(String.init) ?? "?")"
        return "\(common)|ring:\(ring)@\(progress.current ?? -1)|centre:\(centre)"
            + "|first:\(drawn(upcoming.first))|second:\(drawn(upcoming.dropFirst().first))"
            + "|count:\(counter)"
    }
}
