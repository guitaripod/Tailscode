import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Compaction story")
struct CompactionStoryTests {

    @Test("A finished compaction states the trade, the share and what carried over")
    func doneStory() {
        let story = CompactionStory.done(
            Compaction(
                trigger: .manual, tokensBefore: 150_000, tokensAfter: 12_000, duration: 95,
                preservedMessageCount: 4, summary: "kept the failing tests"))
        #expect(story.title == "Context compacted")
        #expect(story.detail == "150.0k → 12.0k tokens · 1m 35s")
        #expect(
            story.footnote
                == "92% of the context was replaced by a summary; the last 4 messages carried over.")
        #expect(story.keptFraction.map { abs($0 - 0.08) < 0.001 } == true)
        #expect(!story.sweeps)
        #expect(story.isReadable)
    }

    @Test("An automatic compaction says so in its title")
    func autoTitle() {
        let story = CompactionStory.done(Compaction(trigger: .auto))
        #expect(story.title == "Context compacted automatically")
        #expect(story.detail == "The conversation so far was replaced by a summary of it.")
        #expect(story.keptFraction == nil)
        #expect(!story.isReadable)
    }

    @Test("The kept sliver never renders as nothing")
    func keptFloor() {
        let story = CompactionStory.done(Compaction(tokensBefore: 1_000_000, tokensAfter: 1))
        #expect(story.keptFraction == 0.02)
    }

    @Test("A running compaction sweeps and counts its own wait")
    func runningStory() {
        let start = Date(timeIntervalSince1970: 0)
        let story = CompactionStory.running(
            startedAt: start, now: start.addingTimeInterval(75))
        #expect(story.sweeps)
        #expect(story.keptFraction == nil)
        #expect(story.footnote == "Running for 1m 15s")
        #expect(!story.isReadable)
    }

    @Test("A refused compaction leads with the reason and ends on reassurance")
    func failedStory() {
        let story = CompactionStory.failed("Context too small to compact")
        #expect(story.tone == .warn)
        #expect(story.title == "Couldn't compact")
        #expect(story.detail == "Context too small to compact")
        #expect(story.footnote == "The conversation is unchanged.")
        #expect(!story.sweeps)
    }

    @Test("The summary reader's header restates the trade")
    func summaryHeader() {
        let header = CompactionStory.summaryHeader(
            Compaction(tokensBefore: 100_000, tokensAfter: 10_000, duration: 61))
        #expect(header == "100.0k → 10.0k tokens · 90% freed · 1m 1s — this is what the agent carries forward.")
        #expect(
            CompactionStory.summaryHeader(Compaction())
                == "What the agent carries forward from here.")
    }

    @Test("The preflight carries the count, the promise and the previous result")
    func preflight() {
        let preflight = CompactPreflight.make(
            messageCount: 42,
            lastCompaction: Compaction(tokensBefore: 80_000, tokensAfter: 9_000, duration: 70))
        #expect(preflight.subtitle == "42 messages in this conversation")
        #expect(preflight.paragraphs.count == 2)
        #expect(preflight.lastTime == "Last time: 80.0k → 9.0k tokens in 1m 10s.")
        #expect(preflight.confirmTitle == "Compact conversation")
    }

    @Test("A first compaction has no last time to promise")
    func preflightFirstRun() {
        let preflight = CompactPreflight.make(messageCount: 0, lastCompaction: nil)
        #expect(preflight.subtitle == "This conversation")
        #expect(preflight.lastTime == nil)
    }
}
