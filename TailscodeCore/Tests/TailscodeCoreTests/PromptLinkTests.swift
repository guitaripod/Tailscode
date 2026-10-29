import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PromptLinkTests {
    @Test func aComposeLinkCarriesItsWords() {
        let url = URL(string: "tailscode://compose?text=Fix%20the%20build")!
        #expect(PromptLink.text(in: url) == "Fix the build")
    }

    @Test func anAskLinkReadsTheSameWay() {
        let url = URL(string: "tailscode://ask?text=what%20is%20this%3F")!
        #expect(PromptLink.text(in: url) == "what is this?")
    }

    @Test func aLinkWithoutWordsCarriesNothing() {
        #expect(PromptLink.text(in: URL(string: "tailscode://compose")!) == nil)
        #expect(PromptLink.text(in: URL(string: "tailscode://compose?text=")!) == nil)
        #expect(PromptLink.text(in: URL(string: "tailscode://compose?text=%20%0A%20")!) == nil)
    }

    @Test func theWordsAreTrimmedOfTheWhitespaceALinkAdds() {
        let url = URL(string: "tailscode://compose?text=%0A%20hello%20%0A")!
        #expect(PromptLink.text(in: url) == "hello")
    }

    @Test func anotherQueryDoesNotStandInForTheWords() {
        #expect(PromptLink.text(in: URL(string: "tailscode://compose?project=arch")!) == nil)
    }

    @Test func aLongPromptSurvivesWhole() {
        let words = String(repeating: "a prompt that has to arrive as it was written. ", count: 200) + "end"
        let encoded = words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "tailscode://compose?text=\(encoded)")!
        #expect(PromptLink.text(in: url)?.count == words.count)
    }
}
