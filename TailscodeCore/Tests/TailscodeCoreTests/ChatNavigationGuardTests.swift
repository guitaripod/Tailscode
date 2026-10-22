import Testing

@testable import TailscodeCore

@Suite struct ChatNavigationGuardTests {
    private let alpha = ChatTarget(contextID: "arch", sessionID: "a")
    private let beta = ChatTarget(contextID: "arch", sessionID: "b")
    private let alphaElsewhere = ChatTarget(contextID: "mini", sessionID: "a")

    @Test func aQuietStackTakesThePush() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(alpha, top: nil, transitioning: false) == .push)
        #expect(guardrail.held == nil)
    }

    @Test func theChatAlreadyOnTopIsNotPushedAgain() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(alpha, top: alpha, transitioning: false) == .alreadyOnTop)
        #expect(guardrail.request(alpha, top: alpha, transitioning: true) == .alreadyOnTop)
    }

    @Test func aSecondTapOnTheRowBeingPushedIsDropped() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(alpha, top: nil, transitioning: false) == .push)
        #expect(guardrail.request(alpha, top: alpha, transitioning: true) == .alreadyOnTop)
        #expect(guardrail.settled(top: alpha) == nil)
    }

    @Test func aPushDuringATransitionWaitsForItAndThenGoes() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: alpha, transitioning: true) == .hold)
        #expect(guardrail.held == beta)
        #expect(guardrail.settled(top: alpha) == beta)
        #expect(guardrail.held == nil)
    }

    @Test func theLatestPressWinsWhileOneIsHeld() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: nil, transitioning: true) == .hold)
        #expect(guardrail.request(alpha, top: nil, transitioning: true) == .hold)
        #expect(guardrail.settled(top: nil) == alpha)
    }

    @Test func aHeldPushForTheChatNowOnTopIsDropped() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: alpha, transitioning: true) == .hold)
        #expect(guardrail.settled(top: beta) == nil)
    }

    @Test func aPressOnTheTopChatTakesBackAHeldPush() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: alpha, transitioning: true) == .hold)
        #expect(guardrail.request(alpha, top: alpha, transitioning: true) == .alreadyOnTop)
        #expect(guardrail.settled(top: alpha) == nil)
    }

    @Test func nothingIsHeldAfterItIsReleased() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: nil, transitioning: true) == .hold)
        _ = guardrail.settled(top: nil)
        #expect(guardrail.settled(top: nil) == nil)
    }

    @Test func theSameSessionOnAnotherServerIsAnotherChat() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(alphaElsewhere, top: alpha, transitioning: false) == .push)
    }

    @Test func aQuietPushClearsAStaleHold() {
        var guardrail = ChatNavigationGuard()
        #expect(guardrail.request(beta, top: nil, transitioning: true) == .hold)
        #expect(guardrail.request(alpha, top: nil, transitioning: false) == .push)
        #expect(guardrail.settled(top: alpha) == nil)
    }
}
