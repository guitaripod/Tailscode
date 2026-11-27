import Testing

@testable import TailscodeCore

@Suite struct ChatTrailTests {
    private let alpha = ChatTarget(contextID: "arch", sessionID: "a")
    private let beta = ChatTarget(contextID: "arch", sessionID: "b")
    private let gamma = ChatTarget(contextID: "arch", sessionID: "c")
    private let delta = ChatTarget(contextID: "arch", sessionID: "d")
    private let everything: (ChatTarget) -> Bool = { _ in true }

    private func walked(_ targets: ChatTarget...) -> ChatTrail {
        var trail = ChatTrail()
        for target in targets { trail.visit(target) }
        return trail
    }

    @Test func anEmptyTrailGoesNowhere() {
        var trail = ChatTrail()
        #expect(trail.step(.back, reaching: everything) == nil)
        #expect(trail.step(.forward, reaching: everything) == nil)
        #expect(!trail.canGoBack && !trail.canGoForward)
        #expect(trail.settle() == nil)
    }

    @Test func backAndForwardWalkTheOrderChatsWereShown() {
        var trail = walked(alpha, beta, gamma)
        #expect(trail.step(.back, reaching: everything) == beta)
        #expect(trail.step(.back, reaching: everything) == alpha)
        #expect(trail.step(.back, reaching: everything) == nil)
        #expect(trail.step(.forward, reaching: everything) == beta)
        #expect(trail.step(.forward, reaching: everything) == gamma)
        #expect(trail.step(.forward, reaching: everything) == nil)
    }

    @Test func hoppingBetweenTwoChatsLeavesExactlyThoseTwo() {
        var trail = walked(alpha, beta, alpha, beta, alpha)
        #expect(trail.visited == [beta, alpha])
        #expect(trail.step(.back, reaching: everything) == beta)
        #expect(trail.step(.forward, reaching: everything) == alpha)
    }

    @Test func openingFromTheMiddleEndsWhatLayAhead() {
        var trail = walked(alpha, beta, gamma)
        _ = trail.step(.back, reaching: everything)
        trail.visit(delta)
        #expect(trail.visited == [alpha, beta, delta])
        #expect(!trail.canGoForward)
        #expect(trail.canGoBack)
    }

    @Test func visitingTheChatTheTrailStandsOnChangesNothing() {
        var trail = walked(alpha, beta, gamma)
        _ = trail.step(.back, reaching: everything)
        trail.visit(beta)
        #expect(trail.visited == [alpha, beta, gamma])
        #expect(trail.canGoForward)
    }

    @Test func aChatReachedByAStepIsTheOneThePaneIsAskedToOpen() {
        var trail = walked(alpha, beta)
        #expect(trail.settle() == nil)
        _ = trail.step(.back, reaching: everything)
        #expect(trail.settle() == alpha)
        #expect(trail.settle() == nil)
    }

    @Test func aBurstOfStepsAsksForOnlyTheLastChat() {
        var trail = walked(alpha, beta, gamma, delta)
        _ = trail.step(.back, reaching: everything)
        _ = trail.step(.back, reaching: everything)
        _ = trail.step(.back, reaching: everything)
        #expect(trail.settle() == alpha)
        #expect(trail.settle() == nil)
    }

    @Test func steppingAwayAndBackBeforeTheFrameAsksForNothing() {
        var trail = walked(alpha, beta)
        _ = trail.step(.back, reaching: everything)
        _ = trail.step(.forward, reaching: everything)
        #expect(trail.settle() == nil)
    }

    @Test func aStepSkipsChatsThatCannotBeReachedAndKeepsThem() {
        var trail = walked(alpha, beta, gamma)
        let skipping: (ChatTarget) -> Bool = { $0 != beta }
        #expect(trail.step(.back, reaching: skipping) == alpha)
        #expect(trail.visited == [alpha, beta, gamma])
        #expect(trail.step(.forward, reaching: skipping) == gamma)
    }

    @Test func aStepWithNothingReachableLeavesThePlaceAlone() {
        var trail = walked(alpha, beta)
        #expect(trail.step(.back, reaching: { _ in false }) == nil)
        #expect(trail.current == beta)
    }

    @Test func theNeighbourIsReadWithoutMovingThePlace() {
        let trail = walked(alpha, beta, gamma)
        #expect(trail.neighbour(.back, reaching: everything) == beta)
        #expect(trail.neighbour(.forward, reaching: everything) == nil)
        #expect(trail.current == gamma)
    }

    @Test func theTrailIsCappedAtItsLimit() {
        var trail = ChatTrail()
        for number in 0..<(ChatTrail.limit + 10) {
            trail.visit(ChatTarget(contextID: "arch", sessionID: "s\(number)"))
        }
        #expect(trail.visited.count == ChatTrail.limit)
        #expect(trail.current?.sessionID == "s\(ChatTrail.limit + 9)")
        #expect(trail.visited.first?.sessionID == "s10")
    }

    @Test func aDeletedChatLeavesTheTrailWithoutLosingThePlace() {
        var trail = walked(alpha, beta, gamma)
        _ = trail.step(.back, reaching: everything)
        trail.forget(alpha)
        #expect(trail.visited == [beta, gamma])
        #expect(trail.current == beta)
        #expect(trail.canGoForward)
    }

    @Test func forgettingTheChatOnShowMovesToThePreviousOne() {
        var trail = walked(alpha, beta, gamma)
        trail.forget(gamma)
        #expect(trail.visited == [alpha, beta])
        #expect(trail.current == beta)
        trail.forget(beta)
        trail.forget(alpha)
        #expect(trail.visited.isEmpty)
        #expect(trail.current == nil)
        #expect(!trail.canGoBack && !trail.canGoForward)
    }

    @Test func theSameSessionOnAnotherServerIsAnotherChat() {
        let elsewhere = ChatTarget(contextID: "mini", sessionID: "a")
        let trail = walked(alpha, elsewhere)
        #expect(trail.visited == [alpha, elsewhere])
    }

    @Test func aPointerReadsItsSideButtonsTheWayABrowserDoes() {
        #expect(ChatTrail.Direction(gdkButton: 8) == .back)
        #expect(ChatTrail.Direction(gdkButton: 9) == .forward)
        #expect(ChatTrail.Direction(gdkButton: 10) == .forward)
        #expect(ChatTrail.Direction(gdkButton: 11) == .back)
        #expect(ChatTrail.Direction(gdkButton: 1) == nil)
        #expect(ChatTrail.Direction(gdkButton: 2) == nil)
        #expect(ChatTrail.Direction(gdkButton: 3) == nil)
        #expect(ChatTrail.Direction(gdkButton: 12) == nil)
        #expect(ChatTrail.Direction(cocoaButton: 3) == .back)
        #expect(ChatTrail.Direction(cocoaButton: 4) == .forward)
        #expect(ChatTrail.Direction(cocoaButton: 2) == nil)
    }
}
