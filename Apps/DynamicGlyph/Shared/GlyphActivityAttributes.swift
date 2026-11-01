import ActivityKit
import Foundation

/// The Live Activity's model: its content, and what is fixed for its life.
struct GlyphActivityAttributes: ActivityAttributes {
    typealias ContentState = GlyphActivityContentState

    /// Fixed for the life of the activity.
    var captureSessionID: UInt64
}
