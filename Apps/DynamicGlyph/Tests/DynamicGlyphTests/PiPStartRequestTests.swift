import Testing

@Suite("PiP manual startup")
struct PiPStartRequestTests {
    @Test("Readiness timeout releases Show for another attempt")
    func readinessTimeout() {
        var request = PiPStartRequest()
        let first = request.begin()
        #expect(request.expire(first) == .waitingForReadiness)
        #expect(request.phase == nil)
        let retry = request.begin()
        #expect(retry != first)
        #expect(request.expire(first) == nil)
        #expect(request.phase == .waitingForReadiness)
    }

    @Test("Issuing start still times out if AVKit never acknowledges it")
    func missingAcknowledgment() {
        var request = PiPStartRequest()
        let id = request.begin()
        let issued = request.issue()
        let issuedAgain = request.issue()
        #expect(issued)
        #expect(!issuedAgain)
        #expect(request.id == id)
        #expect(request.expire(id) == .starting)
        #expect(request.id == nil)
    }

    @Test("Success, failure, or cancellation invalidates the old timer", arguments: [false, true])
    func completion(issued: Bool) {
        var request = PiPStartRequest()
        let id = request.begin()
        if issued {
            let didIssue = request.issue()
            #expect(didIssue)
        }
        request.finish()
        #expect(request.expire(id) == nil)
        let issuedAfterFinish = request.issue()
        #expect(!issuedAfterFinish)
        let retry = request.begin()
        let issuedRetry = request.issue()
        #expect(issuedRetry)
        #expect(request.expire(id) == nil)
        #expect(request.id == retry && request.phase == .starting)
    }
}
