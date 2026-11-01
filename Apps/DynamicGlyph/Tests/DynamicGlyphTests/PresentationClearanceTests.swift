import Testing

@Suite("Clearing presentations before a Control Center start")
struct PresentationClearanceTests {
    typealias Front = PresentationClearance.Front

    @Test("Nothing in front: screen sharing is asked for at once")
    func nothingInFront() {
        var clearance = PresentationClearance()
        #expect(clearance.next(.nothing) == .proceed)
        #expect(clearance.dismissals == 0)
    }

    @Test("iOS's own sharing sheet is never dismissed, and no second one is asked for",
          arguments: [1, 5, 39])
    func sharingSheetLeftAlone(after looks: Int) {
        var clearance = PresentationClearance()
        for _ in 1..<looks { #expect(clearance.next(.moving) == .wait) }
        #expect(clearance.next(.sharingSheet) == .abandon)
        #expect(clearance.dismissals == 0)
    }

    @Test("A sheet the views close themselves is waited for, not dismissed again")
    func viewsCloseTheirOwn() {
        var clearance = PresentationClearance()
        #expect(clearance.next(.presented) == .wait)
        #expect(clearance.next(.moving) == .wait)
        #expect(clearance.next(.moving) == .wait)
        #expect(clearance.next(.moving) == .wait)
        #expect(clearance.next(.nothing) == .proceed)
        #expect(clearance.dismissals == 0)
    }

    @Test("Something no view state drives is dismissed after the grace looks")
    func untrackedPresentationDismissed() {
        var clearance = PresentationClearance()
        for _ in 0..<PresentationClearance.graceLooks {
            #expect(clearance.next(.presented) == .wait)
        }
        #expect(clearance.next(.presented) == .dismiss)
        #expect(clearance.next(.nothing) == .proceed)
        #expect(clearance.dismissals == 1)
    }

    @Test("A transition in progress is never dismissed over")
    func transitionNotInterrupted() {
        var clearance = PresentationClearance()
        for _ in 0..<10 { #expect(clearance.next(.moving) == .wait) }
        #expect(clearance.dismissals == 0)
        #expect(clearance.next(.presented) == .dismiss)
    }

    @Test("A presentation that keeps coming back is given up on, with nothing asked for")
    func stubbornPresentation() {
        var clearance = PresentationClearance()
        var steps: [PresentationClearance.Step] = []
        while steps.last != .abandon && steps.count < 100 {
            steps.append(clearance.next(.presented))
        }
        #expect(steps.filter { $0 == .dismiss }.count == PresentationClearance.maxDismissals)
        #expect(steps.count == PresentationClearance.maxLooks)
        #expect(steps.last == .abandon)
        #expect(!steps.contains(.proceed))
    }

    @Test("A transition that never ends is given up on")
    func endlessTransition() {
        var clearance = PresentationClearance()
        for _ in 1..<PresentationClearance.maxLooks { #expect(clearance.next(.moving) == .wait) }
        #expect(clearance.next(.moving) == .abandon)
    }
}
