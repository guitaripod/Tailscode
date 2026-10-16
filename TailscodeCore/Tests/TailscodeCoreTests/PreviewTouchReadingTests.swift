import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PreviewTouchReadingTests {
    private let pane = PreviewTouchSize(width: 800, height: 600)
    private let phone = PreviewTouchSize(width: 604, height: 1312)

    @Test func thePictureIsFittedAndCentredInThePane() throws {
        let frame = try #require(PreviewTouchReading.pictureFrame(in: pane, picture: phone))
        #expect(abs(frame.height - 600) < 0.001)
        #expect(abs(frame.width - 600 * 604 / 1312) < 0.001)
        #expect(abs(frame.x - (800 - frame.width) / 2) < 0.001)
        #expect(frame.y == 0)
    }

    @Test func aPressIsMeasuredFromThePicturesCornerNotThePanes() throws {
        let frame = try #require(PreviewTouchReading.pictureFrame(in: pane, picture: phone))
        let centre = try #require(
            PreviewTouchReading.fraction(x: frame.x + frame.width / 2, y: 300, container: pane, picture: phone))
        #expect(abs(centre.x - 0.5) < 0.0001)
        #expect(abs(centre.y - 0.5) < 0.0001)
        let corner = try #require(PreviewTouchReading.fraction(x: frame.x, y: 0, container: pane, picture: phone))
        #expect(corner == PreviewTouchPoint(x: 0, y: 0))
    }

    @Test func aPressOnTheMarginIsNothing() {
        #expect(PreviewTouchReading.fraction(x: 10, y: 300, container: pane, picture: phone) == nil)
        #expect(PreviewTouchReading.fraction(x: 790, y: 300, container: pane, picture: phone) == nil)
        #expect(PreviewTouchReading.fraction(x: 400, y: -1, container: pane, picture: phone) == nil)
        #expect(PreviewTouchReading.fraction(x: 400, y: 300, container: PreviewTouchSize(width: 0, height: 0), picture: phone) == nil)
        #expect(PreviewTouchReading.fraction(x: 400, y: 300, container: pane, picture: PreviewTouchSize(width: 0, height: 10)) == nil)
    }

    @Test func aDragOffThePictureEndsAtItsEdge() throws {
        let end = try #require(PreviewTouchReading.clampedFraction(x: 5, y: 900, container: pane, picture: phone))
        #expect(end == PreviewTouchPoint(x: 0, y: 1))
    }

    @Test func aHeldFingerThatStaysPutIsATapWhereItBegan() throws {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        let pressed = tracker.press(x: 400, y: 300, at: 10)
        #expect(pressed)
        tracker.move(x: 403, y: 302)
        let released = tracker.release(x: 403, y: 302, at: 12.5)
        let gesture = try #require(released)
        guard case .tap(let point) = gesture else {
            Issue.record("a still finger is a tap")
            return
        }
        #expect(abs(point.y - 0.5) < 0.0001)
        #expect(gesture.request.action == .tap)
        #expect(!tracker.isDown)
    }

    @Test func aDragPastTheThresholdIsASwipeOverTheTimeItTook() throws {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        tracker.press(x: 400, y: 500, at: 1)
        tracker.move(x: 400, y: 300)
        let released = tracker.release(x: 400, y: 100, at: 1.4)
        let gesture = try #require(released)
        guard case .swipe(let from, let to, let seconds) = gesture else {
            Issue.record("a long drag is a swipe")
            return
        }
        #expect(abs(from.y - 500 / 600) < 0.0001)
        #expect(abs(to.y - 100 / 600) < 0.0001)
        #expect(abs(seconds - 0.4) < 0.0001)
    }

    @Test func aFlickIsNeverFasterThanTheShortestSwipe() throws {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        tracker.press(x: 400, y: 500, at: 1)
        let released = tracker.release(x: 400, y: 200, at: 1.01)
        let gesture = try #require(released)
        guard case .swipe(_, _, let seconds) = gesture else {
            Issue.record("a flick is a swipe")
            return
        }
        #expect(seconds == PreviewTouchReading.shortestSwipe)
    }

    @Test func aSlowDragIsHeldToTheLongestSwipe() throws {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        tracker.press(x: 400, y: 500, at: 1)
        let released = tracker.release(x: 400, y: 200, at: 30)
        let gesture = try #require(released)
        guard case .swipe(_, _, let seconds) = gesture else {
            Issue.record("a slow drag is a swipe")
            return
        }
        #expect(seconds == PreviewTouchReading.longestSwipe)
    }

    @Test func aDragThatWentOutAndBackIsStillASwipeOnlyIfItEndedAway() throws {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        tracker.press(x: 400, y: 300, at: 0)
        tracker.move(x: 400, y: 380)
        let released = tracker.release(x: 400, y: 301, at: 0.3)
        let gesture = try #require(released)
        guard case .swipe(let from, let to, _) = gesture else {
            Issue.record("travel counts even if it came back")
            return
        }
        #expect(abs(from.y - to.y) < 0.01)
    }

    @Test func aPressOutsideThePictureStartsNothing() {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        let pressed = tracker.press(x: 5, y: 5, at: 0)
        let released = tracker.release(x: 5, y: 5, at: 1)
        #expect(!pressed)
        #expect(!tracker.isDown)
        #expect(released == nil)
    }

    @Test func aCancelledGestureLeavesNothingToRelease() {
        var tracker = PreviewTouchTracker(container: pane, picture: phone)
        tracker.press(x: 400, y: 300, at: 0)
        tracker.cancel()
        let released = tracker.release(x: 400, y: 300, at: 0.1)
        #expect(released == nil)
    }

    @Test func typedTextIsKeptToWhatTheKeyboardTakes() {
        #expect(PreviewTouchReading.text(typed: "Hello, World!")?.text == "Hello, World!")
        #expect(PreviewTouchReading.text(typed: "café")?.text == "caf")
        #expect(PreviewTouchReading.text(typed: "\u{7F}\u{1B}") == nil)
        #expect(PreviewTouchReading.text(typed: "") == nil)
    }

    @Test func namedKeysAreTheOnesTheHostKnows() {
        #expect(PreviewTouchReading.key(named: "Return")?.key == "return")
        #expect(PreviewTouchReading.key(named: "f13") == nil)
    }

    @Test func aRefusalIsPutInTheClientsOwnWords() {
        #expect(PreviewTouchReading.failure(AgentError.http(status: 409, body: "")).contains("not showing"))
        #expect(PreviewTouchReading.failure(AgentError.http(status: 501, body: "")).contains("no way"))
        #expect(PreviewTouchReading.failure(AgentError.http(status: 401, body: "")).contains("password"))
        #expect(PreviewTouchReading.failure(AgentError.http(status: 502, body: "")).contains("could not deliver"))
        #expect(PreviewTouchReading.failure(AgentError.connection("down")) == "The Mac is not answering")
        #expect(PreviewTouchReading.isUnsupported(AgentError.http(status: 501, body: "")))
        #expect(!PreviewTouchReading.isUnsupported(AgentError.http(status: 409, body: "")))
    }
}
