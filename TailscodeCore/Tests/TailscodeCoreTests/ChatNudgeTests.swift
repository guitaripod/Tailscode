import Foundation
import Testing

@testable import TailscodeCore

@Suite("Chat nudges")
struct ChatNudgeTests {
    private func offered(
        running: Bool = false, holdsWords: Bool = false, holdsAttachments: Bool = false,
        editingQueued: Bool = false, dictating: Bool = false, hasTranscript: Bool = true
    ) -> Bool {
        ChatNudge.offers(
            running: running, holdsWords: holdsWords, holdsAttachments: holdsAttachments,
            editingQueued: editingQueued, dictating: dictating, hasTranscript: hasTranscript
        )
    }

    @Test func aQuietChatWithAnEmptyBoxOffersThem() {
        #expect(offered())
        #expect(ChatNudge.all.map(\.id) == ["resume", "status"])
    }

    @Test func theWordsSentAreTheOnesPeopleType() {
        #expect(ChatNudge.resume.prompt == "resume")
        #expect(ChatNudge.status.prompt == "status?")
        #expect(ChatNudge.status.hint.contains("status?"))
    }

    @Test func aRunningTurnOffersThemNot() {
        #expect(offered(running: true) == false)
    }

    @Test func anythingInTheBoxHoldsThemBack() {
        #expect(offered(holdsWords: true) == false)
        #expect(offered(holdsAttachments: true) == false)
        #expect(offered(editingQueued: true) == false)
        #expect(offered(dictating: true) == false)
    }

    @Test func aChatNothingWasSaidInOffersThemNot() {
        #expect(offered(hasTranscript: false) == false)
    }

    @Test func everyNudgeHasAGlyphForAToolkitWithoutSymbols() {
        for nudge in ChatNudge.all {
            #expect(!nudge.glyph.isEmpty)
            #expect(!nudge.symbol.isEmpty)
            #expect(!nudge.title.isEmpty)
        }
        #expect(Set(ChatNudge.all.map(\.id)).count == ChatNudge.all.count)
    }
}
