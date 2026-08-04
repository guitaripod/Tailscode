import CodingAgentKit
import Testing

@testable import TailscodeCore

private func command(
    _ name: String, hint: String? = nil, source: AgentCommand.Source = .builtin
) -> AgentCommand {
    AgentCommand(name: name, details: "", argumentHint: hint, source: source)
}

private let catalog = [
    command("compact"), command("context"), command("review"), command("goal", hint: "<condition>"),
    command("project:planner"), command("git:merge"), command("init"),
]

@Suite struct SlashRankingTests {
    @Test func exactTypingWinsOverEveryOtherKind() {
        let ranked = SlashCompletion.ranked(catalog, query: "init")
        #expect(ranked.first?.command.name == "init")
        #expect(ranked.first?.kind == .exact)
    }

    @Test func prefixOutranksInner() {
        let ranked = SlashCompletion.ranked(
            [command("recontext"), command("context")], query: "context")
        #expect(ranked.map(\.command.name) == ["context", "recontext"])
        #expect(ranked[0].kind == .exact)
        #expect(ranked[1].kind == .inner)
    }

    @Test func namespacedCommandAnswersToItsBareName() {
        let ranked = SlashCompletion.ranked(catalog, query: "planner")
        #expect(ranked.first?.command.name == "project:planner")
        #expect(ranked.first?.kind == .segment)
        #expect(ranked.first?.highlight == Array(8..<15))
    }

    @Test func segmentOutranksInnerAcrossCommands() {
        let ranked = SlashCompletion.ranked(
            [command("undo:merge"), command("git:merge")], query: "merge")
        #expect(ranked.first?.kind == .segment)
    }

    @Test func scatteredLettersStillFindTheCommand() {
        let ranked = SlashCompletion.ranked(catalog, query: "gm")
        #expect(ranked.contains { $0.command.name == "git:merge" && $0.kind == .scattered })
    }

    @Test func nothingMatchesReportsNothing() {
        #expect(SlashCompletion.ranked(catalog, query: "zzzz").isEmpty)
    }

    @Test func emptyQueryListsEverythingAlphabetically() {
        let names = SlashCompletion.ranked(catalog, query: "").map(\.command.name)
        #expect(names == catalog.map(\.name).sorted())
    }

    @Test func recentsFloatWithinTheirTierButNeverAboveABetterMatch() {
        let ranked = SlashCompletion.ranked(
            catalog, query: "", recents: ["review", "goal"])
        #expect(ranked.prefix(2).map(\.command.name) == ["review", "goal"])

        let tiered = SlashCompletion.ranked(
            [command("context"), command("recontext")], query: "context",
            recents: ["recontext"])
        #expect(tiered.map(\.command.name) == ["context", "recontext"])
    }

    @Test func highlightPointsAtTheLettersThatMatched() {
        let match = SlashCompletion.ranked([command("compact")], query: "pac").first
        #expect(match?.highlight == [3, 4, 5])
    }

    @Test func matchesKeepsItsOldShape() {
        #expect(SlashCompletion.matches(catalog, query: "co").map(\.name) == ["compact", "context"])
    }
}

@Suite struct SlashStageTests {
    @Test func plainProseIsNotASlashDraft() {
        #expect(SlashStage.of("hello") == .none)
        #expect(SlashStage.of("") == .none)
        #expect(SlashStage.of("//TODO: escape") == .none)
    }

    @Test func namingUntilTheFirstSpace() {
        #expect(SlashStage.of("/comp") == .naming(query: "comp"))
        #expect(SlashStage.of("/") == .naming(query: ""))
    }

    @Test func pastTheSpaceItIsArguments() {
        #expect(SlashStage.of("/goal ship it") == .arguments(name: "goal", arguments: "ship it"))
        #expect(SlashStage.of("/goal ") == .arguments(name: "goal", arguments: ""))
    }

    @Test func aNewlineEndsTheNameJustLikeASpace() {
        #expect(
            SlashStage.of("/compact\nkeep the API notes")
                == .arguments(name: "compact", arguments: "keep the API notes"))
    }
}

@Suite struct SlashDispatchTests {
    private func decide(
        _ text: String, compaction: Bool = true, fromPromptText: Bool = false
    ) -> SlashDispatch {
        SlashDispatch.decide(
            text: text, commands: catalog, supportsCompaction: compaction,
            resolvesFromPromptText: fromPromptText)
    }

    @Test func compactAlwaysPassesThroughItsPreflight() {
        #expect(decide("/compact") == .compactPreflight(instruction: ""))
        #expect(decide("/compact keep the API notes")
            == .compactPreflight(instruction: "keep the API notes"))
        #expect(decide("/compact", fromPromptText: true) == .compactPreflight(instruction: ""))
    }

    @Test func withoutCompactionTheWordIsAnOrdinaryCommand() {
        #expect(decide("/compact", compaction: false) == .run(command: command("compact"), arguments: nil))
        #expect(
            SlashDispatch.decide(
                text: "/compact", commands: [], supportsCompaction: false,
                resolvesFromPromptText: false) == .plainText)
    }

    @Test func aKnownCommandRunsAsACommand() {
        #expect(decide("/review") == .run(command: command("review"), arguments: nil))
        #expect(
            decide("/goal ship it")
                == .run(command: command("goal", hint: "<condition>"), arguments: "ship it"))
    }

    @Test func anAgentThatReadsItsOwnPromptGetsThePromptUntouched() {
        #expect(decide("/review", fromPromptText: true) == .plainText)
    }

    @Test func anUnknownSlashWordIsJustWords() {
        #expect(decide("/nonsense whatever") == .plainText)
        #expect(decide("not a command") == .plainText)
    }
}

@Suite(.serialized) struct SlashRecentsTests {
    @Test func mostRecentFirstWithoutRepeats() {
        SlashRecents.clear()
        SlashRecents.record("review")
        SlashRecents.record("goal")
        SlashRecents.record("review")
        #expect(SlashRecents.names() == ["review", "goal"])
        SlashRecents.clear()
    }

    @Test func aCommandTheServerDroppedStopsBeingOffered() {
        SlashRecents.clear()
        SlashRecents.record("gone")
        SlashRecents.record("review")
        #expect(SlashRecents.surviving(in: catalog) == ["review"])
        SlashRecents.clear()
    }
}
