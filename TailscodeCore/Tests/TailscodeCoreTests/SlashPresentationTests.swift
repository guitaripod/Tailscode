import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Slash presentation")
struct SlashPresentationTests {
    private func command(
        _ name: String, hint: String? = nil, details: String = "", source: AgentCommand.Source = .builtin
    ) -> AgentCommand {
        AgentCommand(name: name, details: details, argumentHint: hint, source: source)
    }

    @Test("Ordinary prose hides the surface")
    func plain() {
        #expect(SlashPresentation.of(text: "hello", commands: []) == .hidden)
        #expect(SlashPresentation.of(text: "", commands: []) == .hidden)
    }

    @Test("Naming ranks and no-match says so instead of vanishing")
    func naming() {
        let catalog = [command("compact"), command("goal", hint: "<condition>")]
        guard case .naming(let matches) = SlashPresentation.of(
            text: "/co", commands: catalog)
        else {
            Issue.record("expected naming")
            return
        }
        #expect(matches.map(\.command.name) == ["compact"])

        guard case .noMatch(let query) = SlashPresentation.of(
            text: "/zzzz", commands: catalog)
        else {
            Issue.record("expected noMatch")
            return
        }
        #expect(query == "zzzz")

        #expect(SlashPresentation.of(text: "/", commands: []) == .hidden)
    }

    @Test("Past the name the surface is that command's signature")
    func arguments() {
        let catalog = [command("goal", hint: "<condition> | clear", details: "Keep working")]
        guard case .arguments(let command, let typed) = SlashPresentation.of(
            text: "/goal ship it", commands: catalog)
        else {
            Issue.record("expected arguments")
            return
        }
        #expect(command.name == "goal")
        #expect(typed == "ship it")
        #expect(command.argumentHint == "<condition> | clear")

        #expect(
            SlashPresentation.of(text: "/unknown stuff", commands: catalog) == .hidden)
    }

    @Test("Catalog sections group by source unsearched and rank when searched")
    func catalog() {
        let commands = [
            command("compact", details: "Summarise"),
            command("deploy", details: "Ship it", source: .project),
            command("pr:open", details: "Open a PR", source: .plugin),
        ]
        SlashRecents.clear()
        SlashRecents.record("deploy")
        let unsearched = CommandCatalogGrouping.sections(commands: commands, query: "")
        #expect(unsearched.first?.id == "·recent")
        #expect(unsearched.first?.commands.map(\.name) == ["deploy"])
        #expect(unsearched.contains { $0.id == AgentCommand.Source.builtin.rawValue })

        let searched = CommandCatalogGrouping.sections(commands: commands, query: "ship")
        #expect(searched.count == 1)
        #expect(searched[0].commands.map(\.name).contains("deploy"))
    }
}
