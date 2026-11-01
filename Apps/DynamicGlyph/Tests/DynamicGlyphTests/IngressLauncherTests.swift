import Foundation
import Testing

@Suite("Opening Ingress")
struct IngressLauncherTests {
    /// Records what was asked for and answers from a fixed script.
    private final class Opener: @unchecked Sendable {
        var requests: [(URL, Bool)] = []
        let answers: [Bool]
        init(_ answers: [Bool]) { self.answers = answers }
        func open(_ url: URL, _ universalOnly: Bool) -> Bool {
            requests.append((url, universalOnly))
            return answers[requests.count - 1]
        }
    }

    @Test("The game opens through its universal link, and nothing else is tried")
    func opensGame() async {
        let opener = Opener([true])
        let outcome = await IngressLauncher { opener.open($0, $1) }.launch()
        #expect(outcome == .openedGame)
        #expect(opener.requests.count == 1)
        #expect(opener.requests[0].0 == IngressLauncher.universalLink)
        // Only as a universal link: a browser page is never an acceptable result.
        #expect(opener.requests[0].1)
    }

    @Test("Without the game installed, the App Store page opens instead")
    func fallsBackToAppStore() async {
        let opener = Opener([false, true])
        let outcome = await IngressLauncher { opener.open($0, $1) }.launch()
        #expect(outcome == .openedAppStore)
        #expect(opener.requests.map(\.0) == [IngressLauncher.universalLink, IngressLauncher.appStorePage])
        #expect(opener.requests[1].1 == false)
    }

    @Test("When nothing opens, the launcher says so")
    func reportsFailure() async {
        let opener = Opener([false, false])
        #expect(await IngressLauncher { opener.open($0, $1) }.launch() == .failed)
    }
}
