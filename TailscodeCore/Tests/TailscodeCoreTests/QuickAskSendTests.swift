import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A quick ask is a composer, so `/` means there what it means in a chat — decided before the mint,
/// because the conversation it will run in does not exist yet.
@Suite struct QuickAskSendTests {
    private let catalog = [
        AgentCommand(name: "review", details: "", argumentHint: "<path>", source: .user),
        AgentCommand(name: "compact", details: "", source: .builtin),
    ]

    @Test func aKnownCommandRunsAsACommand() {
        let send = QuickAskSend.decide(
            text: "/review Sources", commands: catalog, resolvesFromPromptText: false)

        guard case .command(let command, let arguments) = send.kind else {
            Issue.record("expected a command")
            return
        }
        #expect(command.name == "review")
        #expect(arguments == "Sources")
        #expect(send.text == "/review Sources")
    }

    @Test func aWordTheServerHasNeverHeardGoesOutAsTheWords() {
        let send = QuickAskSend.decide(
            text: "/nonesuch", commands: catalog, resolvesFromPromptText: false)

        #expect(send.kind == .prompt)
    }

    /// The server is the authority on its own grammar.
    @Test func anAgentThatResolvesItsOwnGrammarGetsThePromptUntouched() {
        let send = QuickAskSend.decide(
            text: "/review Sources", commands: catalog, resolvesFromPromptText: true)

        #expect(send.kind == .prompt)
    }

    /// Compacting a conversation with no turns in it is meaningless, and the preflight it would
    /// open is the one irreversible thing in the app.
    @Test func compactionIsNeverWhatAQuickAskMeans() {
        let send = QuickAskSend.decide(
            text: "/compact keep the plan", commands: catalog, resolvesFromPromptText: false)

        #expect(send.kind == .prompt)
    }

    @Test func aTranscriptRelativeCommandIsNotEvenOffered() {
        let offered = CommandCatalogStore.forQuickAsk(catalog)

        #expect(offered.map(\.name) == ["review"])
    }

    @Test func plainWordsStayPlainWords() {
        let send = QuickAskSend.decide(
            text: "what changed today?", commands: catalog, resolvesFromPromptText: false)

        #expect(send.kind == .prompt)
    }

    /// A repository's own commands are not in a directory-less catalog and could not be resolved by
    /// the turn it starts either, so the wording says which is which.
    @Test func aMissingWordSaysWhyItIsMissing() {
        let outside = SlashPresentation.noMatchWording("commit", hasProject: false)
        let inside = SlashPresentation.noMatchWording("commit", hasProject: true)

        #expect(outside != inside)
        #expect(outside.contains("commit"))
        #expect(inside.contains("commit"))
    }
}
