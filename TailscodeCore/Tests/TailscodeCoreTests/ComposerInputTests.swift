import Testing

@testable import TailscodeCore

private func ink(_ text: String, commands: Set<String> = ["compact", "goal"]) -> [DraftInk.Run] {
    DraftInk.read(text, knowsCommand: commands.contains)
}

private func words(_ runs: [DraftInk.Run], in text: String) -> [String] {
    let units = Array(text.utf16)
    return runs.map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) }
}

@Suite struct DraftInkTests {
    @Test func aKnownCommandIsInkedAndAnUnknownOneIsNot() {
        #expect(ink("/compact keep the tests") == [DraftInk.Run(start: 0, length: 8, kind: .command)])
        #expect(ink("/nonsense keep the tests").isEmpty)
        #expect(ink("please /compact").isEmpty)
        #expect(ink("/").isEmpty)
    }

    @Test func aPathAfterAnAtIsAMentionAndAnAttributeIsAWord() {
        let text = "look at @Sources/BridgeStream.swift, then @MainActor and @objc"
        let runs = ink(text)
        #expect(runs.map(\.kind) == [.mention])
        #expect(words(runs, in: text) == ["@Sources/BridgeStream.swift"])
    }

    @Test func anAddressIsNotAMention() {
        #expect(ink("mail me@example.com about it").isEmpty)
    }

    @Test func aQuotedPathKeepsItsSpaces() {
        let text = "open @\"My Notes/plan one.md\" now"
        #expect(words(ink(text), in: text) == ["@\"My Notes/plan one.md\""])
    }

    @Test func closedBackticksAreCodeAndAnOpenOneIsNot() {
        let text = "rename `ReconnectScheduler` to `Backoff and stop"
        let runs = ink(text)
        #expect(runs.map(\.kind) == [.code])
        #expect(words(runs, in: text) == ["`ReconnectScheduler`"])
    }

    @Test func aFenceIsOneRunAcrossLines() {
        let text = "this:\n```\nlet a = 1\n@Package.swift\n```\ndone"
        let runs = ink(text)
        #expect(runs.map(\.kind) == [.code])
        #expect(words(runs, in: text) == ["```\nlet a = 1\n@Package.swift\n```"])
    }

    @Test func codeWinsOverWhatIsWrittenInsideIt() {
        let text = "`@Package.swift` and ultracode"
        #expect(ink(text).map(\.kind) == [.code, .power])
    }

    @Test func thePowerWordIsFoundAsAWordInAnyCase() {
        let text = "go UltraCode on it, not ultracodes"
        let runs = ink(text)
        #expect(words(runs, in: text) == ["UltraCode"])
    }

    @Test func offsetsCountInUTF16() {
        let text = "👍 see @a/b.swift"
        let runs = ink(text)
        #expect(runs == [DraftInk.Run(start: 7, length: 10, kind: .mention)])
    }

    @Test func runsComeBackInOrder() {
        let text = "/goal fix `x` in @a/b.c with ultracode"
        #expect(ink(text).map(\.kind) == [.command, .code, .mention, .power])
    }
}

@Suite struct MentionTokenTests {
    @Test func theTokenEndsAtTheCaret() {
        let text = "why does @Sour"
        #expect(MentionToken.at(caret: 14, in: text) == MentionToken(start: 9, length: 5, query: "Sour"))
        #expect(MentionToken.at(caret: 10, in: text) == MentionToken(start: 9, length: 1, query: ""))
    }

    @Test func ordinaryWordsHaveNoToken() {
        #expect(MentionToken.at(caret: 5, in: "hello there") == nil)
        #expect(MentionToken.at(caret: 14, in: "me@example.com") == nil)
        #expect(MentionToken.at(caret: 9, in: "@one two") == nil)
        #expect(MentionToken.at(caret: 0, in: "@one") == nil)
    }

    @Test func aQuoteLetsTheNameHoldSpaces() {
        let text = "see @\"My Notes/pl"
        #expect(MentionToken.at(caret: 17, in: text)?.query == "My Notes/pl")
        #expect(MentionToken.at(caret: 21, in: "see @\"a b\" and c") == nil)
    }

    @Test func aChosenFileReplacesTheWholeName() {
        let text = "see @Sour and more"
        let token = MentionToken.at(caret: 7, in: text)
        #expect(token?.query == "So")
        #expect(token?.replaced(in: text) == 4..<9)
    }

    @Test func completionsEndAsTheNextKeystrokeNeeds() {
        #expect(MentionToken.completion(for: MentionEntry(path: "Sources", isDirectory: true)) == "@Sources/")
        #expect(MentionToken.completion(for: MentionEntry(path: "a/b.swift", isDirectory: false)) == "@a/b.swift ")
        #expect(
            MentionToken.completion(for: MentionEntry(path: "My Notes/a.md", isDirectory: false))
                == "@\"My Notes/a.md\" ")
    }

    @Test func aPathHasAFolderOrAnExtension() {
        #expect(MentionToken.looksLikePath("Sources/Transport"))
        #expect(MentionToken.looksLikePath("Package.swift"))
        #expect(!MentionToken.looksLikePath("MainActor"))
        #expect(!MentionToken.looksLikePath("2.0"))
        #expect(!MentionToken.looksLikePath("a@b.c"))
    }
}

private func shelf() -> MentionShelf {
    var shelf = MentionShelf(root: "/srv/pulse/")
    shelf.shelve(
        [("Tests", true), ("Sources", true), ("Package.swift", false), (".git", true), ("README.md", false)],
        in: "")
    shelf.shelve([("Transport", true), ("Pulse.swift", false)], in: "Sources")
    shelf.shelve(
        [("BridgeStream.swift", false), ("Backoff.swift", false), ("ReconnectScheduler.swift", false)],
        in: "Sources/Transport")
    shelf.changed = ["Sources/Transport/ReconnectScheduler.swift", "Tests/TransportTests/ReconnectTests.swift"]
    return shelf
}

@Suite struct MentionShelfTests {
    @Test func theOpeningListIsTheChangeThenTheRoot() {
        let answer = shelf().answer("")
        #expect(answer.sections.map(\.title) == [.changed, .files])
        #expect(answer.sections[0].rows.map(\.entry.name) == ["ReconnectScheduler.swift", "ReconnectTests.swift"])
        #expect(answer.sections[1].rows.map(\.entry.name) == ["Sources", "Tests", "Package.swift", "README.md"])
        #expect(answer.wanted == nil)
    }

    @Test func lettersFindAFileAnywhereAndSayWhere() {
        let answer = shelf().answer("brst")
        #expect(answer.rows.first?.entry.path == "Sources/Transport/BridgeStream.swift")
        #expect(answer.rows.first?.highlight == [0, 1, 6, 7])
    }

    @Test func aChangedFileOutranksAnUnchangedOneOfTheSameKind() {
        var shelf = shelf()
        shelf.shelve([("Reconnect.swift", false)], in: "Tests")
        let answer = shelf.answer("reconnect")
        #expect(
            answer.rows.map(\.entry.name)
                == ["ReconnectTests.swift", "ReconnectScheduler.swift", "Reconnect.swift"])
        #expect(answer.rows.map(\.changed) == [true, true, false])
    }

    @Test func theTighterNameComesBeforeItsTests() {
        var shelf = shelf()
        shelf.shelve([("BridgeStreamTests.swift", false)], in: "Tests")
        #expect(
            shelf.answer("brst").rows.map(\.entry.name)
                == ["BridgeStream.swift", "BridgeStreamTests.swift"])
    }

    @Test func aPathFromOutsideTheProjectGetsNoRows() {
        #expect(shelf().answer("/etc/hosts") == MentionAnswer(sections: []))
        #expect(shelf().answer("~/notes").isEmpty)
    }

    @Test func theShallowerNameWinsATie() {
        var shelf = shelf()
        shelf.shelve([("Package.swift", false)], in: "Tests")
        #expect(shelf.answer("pack").rows.map(\.entry.path) == ["Package.swift", "Tests/Package.swift"])
    }

    @Test func aSlashWalksAFolder() {
        let answer = shelf().answer("Sources/Transport/")
        #expect(answer.sections.map(\.title) == [.folder("Sources/Transport")])
        #expect(answer.rows.map(\.entry.name) == ["Backoff.swift", "BridgeStream.swift", "ReconnectScheduler.swift"])
        #expect(answer.rows.last?.changed == true)
        #expect(
            shelf().answer("Sources/Transport/ba").rows.map(\.entry.name)
                == ["Backoff.swift", "BridgeStream.swift"])
        #expect(shelf().answer("Sources/Transport/back").rows.map(\.entry.name) == ["Backoff.swift"])
    }

    @Test func anUnlistedFolderIsAskedForOnceAndADeadOneNever() {
        var shelf = shelf()
        #expect(shelf.answer("Tests/").wanted == "Tests")
        shelf.fail("Tests")
        #expect(shelf.answer("Tests/").wanted == nil)
        #expect(MentionShelf(root: "/srv/pulse").answer("").wanted == "")
    }

    @Test func hiddenEntriesStayOffTheShelf() {
        let names = shelf().answer("").rows.map(\.entry.name)
        #expect(!names.contains(".git"))
    }

    @Test func theWalkGoesNearestFirstAndSkipsBuildOutput() {
        var shelf = MentionShelf(root: "/srv/pulse")
        #expect(shelf.frontier(excluding: [], limit: 4) == [""])
        #expect(shelf.frontier(excluding: [""], limit: 4).isEmpty)
        shelf.shelve([("Sources", true), ("node_modules", true), ("App.xcodeproj", true), ("Tests", true)], in: "")
        #expect(shelf.frontier(excluding: [], limit: 4) == ["Sources", "Tests"])
        #expect(shelf.frontier(excluding: ["Sources"], limit: 4) == ["Tests"])
        shelf.shelve([("Deep", true)], in: "Sources")
        #expect(shelf.frontier(excluding: [], limit: 1) == ["Tests"])
    }

    @Test func pathsAreNamedFromTheRoot() {
        let shelf = shelf()
        #expect(shelf.absolute("") == "/srv/pulse")
        #expect(shelf.absolute("Sources/Transport") == "/srv/pulse/Sources/Transport")
        #expect(shelf.relative("/srv/pulse/Sources/a.swift") == "Sources/a.swift")
        #expect(shelf.relative("Sources/a.swift", under: "/srv/pulse") == "Sources/a.swift")
        #expect(shelf.relative("a.swift", under: "/srv/other") == nil)
        #expect(shelf.holds("Sources/Transport/Backoff.swift"))
        #expect(shelf.holds("Tests/TransportTests/ReconnectTests.swift"))
        #expect(!shelf.holds("Sources/Nope.swift"))
    }
}

@Suite struct ComposerLiftTests {
    @Test func theWordsAreHeldBetweenALineAndTheCap() {
        #expect(ComposerLift.height(natural: 10, cap: 132, floor: 22) == 22)
        #expect(ComposerLift.height(natural: 88, cap: 132, floor: 22) == 88)
        #expect(ComposerLift.height(natural: 400, cap: 132, floor: 22) == 132)
        #expect(ComposerLift.restingCap(lineHeight: 21.5) == 131)
    }

    @Test func theHandleShowsOnlyWhenThereIsMoreOrTheBoxIsUp() {
        #expect(!ComposerLift.offersHandle(natural: 132, resting: 132, lifted: false))
        #expect(ComposerLift.offersHandle(natural: 160, resting: 132, lifted: false))
        #expect(ComposerLift.offersHandle(natural: 40, resting: 132, lifted: true))
    }

    @Test func theCeilingIsTheWordsOrThePage() {
        #expect(ComposerLift.ceiling(natural: 300, resting: 132, page: 500) == 300)
        #expect(ComposerLift.ceiling(natural: 900, resting: 132, page: 500) == 500)
        #expect(ComposerLift.ceiling(natural: 60, resting: 132, page: 500) == 132)
    }

    @Test func aDragTracksTheFingerAndGivesSoftlyPastEitherEnd() {
        #expect(ComposerLift.dragged(from: 132, travel: 100, resting: 132, ceiling: 400) == 232)
        let over = ComposerLift.dragged(from: 132, travel: 400, resting: 132, ceiling: 400)
        #expect(over > 400 && over < 436)
        let under = ComposerLift.dragged(from: 132, travel: -200, resting: 132, ceiling: 400)
        #expect(under < 132 && under > 96)
    }

    @Test func aFlickDecidesAndOtherwiseTheNearerEnd() {
        #expect(ComposerLift.settlesLifted(cap: 140, velocity: 600, resting: 132, ceiling: 400))
        #expect(!ComposerLift.settlesLifted(cap: 390, velocity: -600, resting: 132, ceiling: 400))
        #expect(ComposerLift.settlesLifted(cap: 300, velocity: 0, resting: 132, ceiling: 400))
        #expect(!ComposerLift.settlesLifted(cap: 200, velocity: 0, resting: 132, ceiling: 400))
    }
}

@Suite struct SendFaceTests {
    @Test func theFaceIsTheVerbAPressPerforms() {
        #expect(SendFace.read(holdsWords: false, busy: false, editingQueued: false) == .idle)
        #expect(SendFace.read(holdsWords: true, busy: false, editingQueued: false) == .send)
        #expect(SendFace.read(holdsWords: true, busy: true, editingQueued: false) == .queue)
        #expect(SendFace.read(holdsWords: false, busy: true, editingQueued: false) == .stop)
        #expect(SendFace.read(holdsWords: true, busy: true, editingQueued: true) == .save)
        #expect(SendFace.read(holdsWords: false, busy: false, editingQueued: true) == .takeBack)
    }

    @Test func onlyIdleDoesNothingAndOnlyWordsLaunch() {
        let still = SendFace.allCases.filter { !$0.acts }
        #expect(still == [.idle])
        let launching = SendFace.allCases.filter { $0.launches }
        #expect(launching == [.send, .queue])
        let symbols = Set(SendFace.allCases.filter { $0 != .idle }.map(\.symbol))
        #expect(symbols.count == 5)
    }
}

@Suite struct DraftVerbsTests {
    @Test func aNameIsWrappedAndAWrappedNameIsBare() {
        #expect(DraftVerbs.code("Backoff").text == "`Backoff`")
        #expect(DraftVerbs.code("`Backoff`").text == "Backoff")
        #expect(DraftVerbs.code("a `b` c").text == "``a `b` c``")
    }

    @Test func linesBecomeAFenceAndBack() {
        #expect(DraftVerbs.code("let a = 1\nlet b = 2").text == "```\nlet a = 1\nlet b = 2\n```")
        #expect(DraftVerbs.code("```\nlet a = 1\n```").text == "let a = 1")
    }

    @Test func nothingSelectedLeavesTheCaretBetweenAPair() {
        #expect(DraftVerbs.code("") == DraftVerbs.Edit(text: "``", selectedStart: 1, selectedLength: 0))
    }

    @Test func aQuoteMarksEveryLineAndUndoesItself() {
        #expect(DraftVerbs.quote("one\ntwo").text == "> one\n> two")
        #expect(DraftVerbs.quote("> one\n> two").text == "one\ntwo")
    }
}
