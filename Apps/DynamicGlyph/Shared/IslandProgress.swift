import Foundation
import GlyphRecognition

/// What the Island's smallest presentations can say without words.
///
/// While the screen-recording indicator holds a place in the Island, which is
/// all the time this app is capturing on most phones, the activity only ever
/// gets the minimal presentation: a circle a couple of dozen points across.
/// Showing nothing but an icon until input began left the player unable to see
/// whether a hack had been picked up at all. A ring with one segment per slot
/// can say that, and how far collection has got, whether a slot was lost, and
/// which slot the player is drawing, without a single character of text.
struct IslandProgress: Equatable {
    /// One segment of the ring.
    enum Mark: Equatable {
        /// Collected across a verified boundary.
        case held
        /// A shape is on screen for this slot right now.
        case seeing
        /// The slot closed without a legible shape, or its entry is a guess.
        case lost
        /// Not seen; the sequence table supplies it.
        case predicted
        /// Not reached yet.
        case ahead
    }

    /// What sits inside the ring.
    enum Centre: Equatable {
        /// The Glyph to draw now, from the guidance window.
        case next
        /// The Glyph in this slot of the row: the one on screen, or the one
        /// just collected, while the presentation runs.
        case slot(Int)
        /// The slot indicators are hidden, which is why nothing is moving.
        case covered
        /// No hack to follow yet.
        case waiting(provisional: Bool)
    }

    /// One per slot; empty until the game has shown how many there are.
    let marks: [Mark]
    /// The segment to emphasise: the slot being drawn during input, else the
    /// slot being seen during the presentation.
    let current: Int?
    let centre: Centre

    init(_ state: GlyphActivityContentState) {
        let marks = state.slots.map { slot -> Mark in
            switch slot.provenance {
            case .observed: return .held
            case .observing: return .seeing
            case .uncertain, .missing: return .lost
            case .predicted: return .predicted
            case .pending: return .ahead
            }
        }
        self.marks = marks

        let seeing = marks.firstIndex(of: .seeing)
        if let number = state.inputSlotNumber, marks.indices.contains(number - 1) {
            current = number - 1
        } else {
            current = seeing
        }

        let drawable = { (index: Int) in state.slots[index].shape != nil }
        if !state.upcoming.isEmpty {
            centre = .next
        } else if state.indicatorsObstructed {
            centre = .covered
        } else if TrackingState(rawValue: state.phase) == .presenting,
                  let index = seeing ?? marks.lastIndex(of: .held),
                  drawable(index) {
            centre = .slot(index)
        } else {
            centre = .waiting(provisional: state.isProvisional)
        }
    }
}
