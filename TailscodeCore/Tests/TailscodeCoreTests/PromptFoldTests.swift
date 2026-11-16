import Testing

@testable import TailscodeCore

@Suite struct PromptFoldTests {
    private let listed = """
        The reconnect test fails about one run in five on CI and never on my machine.

        What I know so far:
        - it only fails on the Linux runners, never on macOS
        - the failure is always in ReconnectTests.testBackoffCeiling
        - it started after the jitter change two weeks ago
        - rerunning the job makes it pass

        Constraints:
        - do not raise the ceiling in the test
        - no sleeps in tests
        - the scheduler's public surface stays as it is

        When it is green, run the whole suite three times in a row.
        """

    @Test func aShortPromptIsShownWhole() {
        let reading = PromptFold.read("Fix the flaky test.", columns: 40, expanded: false)
        #expect(reading == .whole)
        #expect(reading.lineLimit == nil && reading.toggleLabel == nil)
    }

    @Test func aListedPromptFoldsOnADesktopAndOnAPhone() {
        #expect(PromptFold.estimatedLines(listed, columns: 200) == 14)
        let desk = PromptFold.read(listed, columns: 200, expanded: false)
        #expect(desk.foldable && desk.folded && desk.lineLimit == 7)
        #expect(desk.toggleLabel == "Show more")
        #expect(PromptFold.estimatedLines(listed, columns: 34) > 14)
        #expect(PromptFold.read(listed, columns: 34, expanded: false).folded)
    }

    @Test func anOpenedPromptKeepsItsFoldLine() {
        let opened = PromptFold.read(listed, columns: 200, expanded: true)
        #expect(opened.foldable && !opened.folded && opened.lineLimit == nil)
        #expect(opened.toggleLabel == "Show less")
    }

    @Test func aDictatedParagraphFoldsOnlyWhereItWraps() {
        let spoken = String(repeating: "and then the bridge should hold the turn ", count: 18)
        #expect(spoken.count > 700)
        #expect(PromptFold.read(spoken, columns: 34, expanded: false).folded)
        #expect(PromptFold.read(spoken, columns: 200, expanded: false) == .whole)
    }

    @Test func theCutFillsSevenLinesAndEndsOnAnEllipsis() {
        let cut = PromptFold.cut(listed, columns: 200)
        #expect(cut.hasSuffix("…"))
        #expect(PromptFold.estimatedLines(cut, columns: 200) == PromptFold.shownLines)
        #expect(cut.hasPrefix("The reconnect test fails"))
        #expect(cut.contains("rerunning the job makes it pass"))
        #expect(!cut.contains("Constraints"))
    }

    @Test func aParagraphIsCutInsideItsLastLine() {
        let spoken = String(repeating: "and then the bridge should hold the turn ", count: 18)
        let cut = PromptFold.cut(spoken, columns: 34)
        #expect(cut.hasSuffix("…") && !cut.hasSuffix(" …"))
        #expect(PromptFold.estimatedLines(cut, columns: 34) <= PromptFold.shownLines)
        #expect(cut.count > 5 * 34)
    }

    @Test func tenLinesStayAndElevenFold() {
        let ten = Array(repeating: "line", count: 10).joined(separator: "\n")
        let eleven = ten + "\nline"
        #expect(PromptFold.read(ten, columns: 80, expanded: false) == .whole)
        #expect(PromptFold.read(eleven, columns: 80, expanded: false).folded)
    }

    @Test func aFoldedPromptAlwaysHidesSomething() {
        #expect(PromptFold.foldsPast - PromptFold.shownLines >= 3)
    }

    @Test func columnsComeFromTheWidthAndTheType() {
        #expect(PromptFold.columns(width: 300, fontSize: 17, monospaced: false) == 35)
        #expect(PromptFold.columns(width: 1500, fontSize: 13, monospaced: true) == 192)
        #expect(PromptFold.columns(width: 0, fontSize: 13, monospaced: true) == 1)
        #expect(PromptFold.columns(width: .nan, fontSize: 13, monospaced: false) == 1)
    }

    @Test func aWallOfLinesIsCountedWithoutWalkingAllOfIt() {
        let wall = String(repeating: "x\n", count: 100_000)
        #expect(PromptFold.estimatedLines(wall, columns: 80) > PromptFold.foldsPast)
        #expect(PromptFold.estimatedLines(wall, columns: 80) <= 4 * PromptFold.foldsPast + 1)
    }

    @Test func aPromptsOpeningHasAKeyOfItsOwn() {
        #expect(PromptFold.key(messageID: "m7") == "prompt:m7")
    }
}
