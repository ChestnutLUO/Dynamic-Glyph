/// Getting the app's own sheets, alerts and pickers out of the way before the
/// Control Center button asks for screen sharing, one look at a time.
///
/// The views close their own presentations when told to, which SwiftUI then
/// animates away; the first looks give them that chance. Whatever is still up
/// afterwards, such as something no view state drives, is dismissed outright.
/// iOS's own screen-sharing sheet is never touched. Pure, so the order of the
/// looks can be tested; `PresentationDismisser` does the looking.
struct PresentationClearance {
    /// What is in front of the app's window at one look.
    enum Front: Equatable {
        case nothing
        /// iOS's screen-sharing sheet, already asking.
        case sharingSheet
        /// Being presented or dismissed right now.
        case moving
        case presented
    }

    enum Step: Equatable {
        /// Nothing is in the way: ask for screen sharing.
        case proceed
        /// Look again shortly.
        case wait
        /// Dismiss everything presented over the window, then look again.
        case dismiss
        /// Ask for nothing: a second sheet would stack, or the app's own
        /// would not go away.
        case abandon
    }

    /// Time between looks, in seconds.
    static let interval = 0.05
    /// Looks the views get to close their own presentations.
    static let graceLooks = 3
    /// Looks before giving up, about two seconds.
    static let maxLooks = 40
    /// A presentation that comes back after this many dismissals is left alone.
    static let maxDismissals = 2

    private(set) var looks = 0
    private(set) var dismissals = 0

    mutating func next(_ front: Front) -> Step {
        looks += 1
        switch front {
        case .nothing:
            return .proceed
        case .sharingSheet:
            return .abandon
        case .moving, .presented:
            if looks >= Self.maxLooks { return .abandon }
            guard front == .presented, looks > Self.graceLooks,
                  dismissals < Self.maxDismissals else { return .wait }
            dismissals += 1
            return .dismiss
        }
    }
}
