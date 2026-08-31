import Testing

@testable import TailscodeCore

@Suite("Transcript expansion")
struct TranscriptExpansionTests {
    @Test("A row shut by hand stays shut, whatever reason it had to be open")
    func closedIsRemembered() {
        var expansion = TranscriptExpansion()
        #expect(!expansion.isClosed("m1:t1"))
        expansion.set("m1:t1", open: false)
        #expect(expansion.isClosed("m1:t1"))
        expansion.set("m1:t1", open: true)
        #expect(!expansion.isClosed("m1:t1"))
        #expect(expansion.isOpen("m1:t1"))
        expansion.reset()
        #expect(!expansion.isOpen("m1:t1"))
        #expect(!expansion.isClosed("m1:t1"))
    }

    @Test("A run reads open when a step inside it is")
    func runFollowsItsSteps() {
        var expansion = TranscriptExpansion()
        expansion.set("run:m1:p1:s2", open: true)
        #expect(expansion.reads("run:m1:p1"))
        #expect(!expansion.reads("run:m1:p2"))
    }
}
