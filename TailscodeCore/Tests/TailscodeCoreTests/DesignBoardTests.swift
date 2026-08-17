import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Design boards")
struct DesignBoardTests {
    private func write(_ path: String, id: String = "t1", tool: String = "Write") -> MessagePart {
        MessagePart(
            id: "p-\(id)",
            kind: .tool(
                ToolCall(
                    id: id, name: tool, status: .completed,
                    input: .object(["file_path": .string(path)]))))
    }

    private func assistant(_ parts: [MessagePart], id: String = "m1") -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode, parts: parts, createdAt: Date(),
            completedAt: Date())
    }

    private let manifestJSON = """
        {
          "title": "Composer redesign",
          "brief": "redesign the composer for what people actually use it for",
          "artboards": [
            {"letter": "A", "name": "Conservative", "rationale": "Keeps the layout, swaps one control.",
             "file": "A.html", "notes": ["Switch model replaces MCP"]},
            {"letter": "B", "name": "Adaptive row", "rationale": "Frequent actions come first.",
             "file": "B.html", "notes": ["The long tail folds under +", "Edit stays reachable"]}
          ]
        }
        """

    @Test("A written manifest is what makes a board, whatever the tool was called")
    func sighting() {
        let messages = [
            assistant([
                write("/home/me/app/.tailscode/design/composer-0818-1423/A.html", id: "a"),
                write("/home/me/app/.tailscode/design/composer-0818-1423/board.json", id: "m"),
            ])
        ]
        let sightings = DesignReading.sightings(in: messages)
        #expect(sightings.count == 1)
        #expect(
            sightings.first?.source
                == .board(directory: "/home/me/app/.tailscode/design/composer-0818-1423"))
        #expect(sightings.first?.toolUseID == "m")
    }

    @Test("An agent that calls its writer something else still makes a board")
    func otherWriters() {
        for tool in ["write", "edit", "str_replace_editor", "create_file", "patch"] {
            let messages = [assistant([write("design/board.json", id: "x", tool: tool)])]
            #expect(DesignReading.sightings(in: messages).count == 1, "\(tool)")
        }
    }

    @Test("A board is claimed once, however many times its manifest is rewritten")
    func rewrittenOnce() {
        let messages = [
            assistant([write("d/board.json", id: "one")], id: "m1"),
            assistant([write("d/board.json", id: "two")], id: "m2"),
        ]
        #expect(DesignReading.sightings(in: messages).count == 1)
        #expect(DesignReading.sightings(in: messages).first?.toolUseID == "one")
    }

    @Test("Ordinary files are not boards")
    func notBoards() {
        let messages = [
            assistant([
                write("src/board.json.bak", id: "a"),
                write("src/Composer.swift", id: "b"),
                write("boardjson", id: "c"),
            ])
        ]
        #expect(DesignReading.sightings(in: messages).isEmpty)
    }

    @Test("A published artifact is surfaced as the link it is")
    func artifactLink() {
        let text = MessagePart(
            id: "t",
            kind: .text(
                "Publishing: https://claude.ai/code/artifact/7c31b9e4-4f2d-4b8e-9a30-c2e58f16d4aa"))
        let sightings = DesignReading.sightings(in: [assistant([text])])
        #expect(
            sightings.first?.source
                == .artifact(
                    url: "https://claude.ai/code/artifact/7c31b9e4-4f2d-4b8e-9a30-c2e58f16d4aa"))
    }

    @Test("Somebody else's claude.ai link stays ordinary text")
    func otherLinks() {
        let text = MessagePart(id: "t", kind: .text("See https://claude.ai/chat/abc for context"))
        #expect(DesignReading.sightings(in: [assistant([text])]).isEmpty)
    }

    @Test("The manifest reads as written")
    func manifest() {
        let manifest = DesignManifest.parse(manifestJSON)
        #expect(manifest?.title == "Composer redesign")
        #expect(manifest?.artboards.count == 2)
        #expect(manifest?.artboards[1].caption == "B · Adaptive row")
        #expect(manifest?.artboards[1].notes.count == 2)
    }

    @Test("A manifest wrapped in prose or a fence still reads")
    func lenientManifest() {
        let fenced = "```json\n\(manifestJSON)\n```"
        #expect(DesignManifest.parse(fenced)?.artboards.count == 2)
        let chatty = "Here is the board:\n\(manifestJSON)\nThat's everything."
        #expect(DesignManifest.parse(chatty)?.title == "Composer redesign")
        #expect(DesignManifest.parse("not json at all") == nil)
        #expect(DesignManifest.parse("") == nil)
    }

    @Test("An artboard missing its letter or file is still pickable")
    func settledArtboards() {
        let sparse = """
            {"title": "T", "artboards": [{"name": "First"}, {"name": "Second"}]}
            """
        let manifest = DesignManifest.parse(sparse)
        #expect(manifest?.artboards.first?.letter == "A")
        #expect(manifest?.artboards.first?.file == "A.html")
        #expect(manifest?.artboards.last?.letter == "B")
        #expect(manifest?.artboards.last?.file == "B.html")
    }

    @Test("A manifest that names its parts differently is not thrown away")
    func alternativeKeys() {
        let other = """
            {"name": "Composer", "options": [
              {"title": "Dense", "description": "Everything at once", "path": "one.html"}]}
            """
        let manifest = DesignManifest.parse(other)
        #expect(manifest?.title == "Composer")
        #expect(manifest?.artboards.first?.name == "Dense")
        #expect(manifest?.artboards.first?.rationale == "Everything at once")
        #expect(manifest?.artboards.first?.file == "one.html")
    }

    @Test("The brief states the convention the board surface reads back")
    func briefConvention() {
        let brief = DesignBrief(
            request: "redesign the composer", count: 3, reference: "ComposerView.swift",
            notes: "keep the send button",
            at: Date(timeIntervalSince1970: 1_787_003_846))
        #expect(brief.directory.hasPrefix(".tailscode/design/redesign-the-composer-"))
        #expect(brief.prompt.contains(brief.directory + "/board.json"))
        #expect(brief.prompt.contains("<LETTER>.html"))
        #expect(brief.prompt.contains("ComposerView.swift"))
        #expect(brief.prompt.contains("keep the send button"))
        #expect(brief.prompt.contains("Design 3 alternative artboards"))
        #expect(brief.prompt.contains("do not change the app's own source"))
    }

    @Test("Asking twice keeps both boards")
    func distinctSlugs() {
        let one = DesignBrief(request: "the composer", at: Date(timeIntervalSince1970: 1_000_000))
        let two = DesignBrief(request: "the composer", at: Date(timeIntervalSince1970: 1_100_000))
        #expect(one.directory != two.directory)
    }

    @Test("A brief is clamped to a number of alternatives worth looking at")
    func countClamped() {
        #expect(DesignBrief(request: "x", count: 1).count == DesignBrief.minimumCount)
        #expect(DesignBrief(request: "x", count: 40).count == DesignBrief.maximumCount)
    }

    @Test("A request of nothing is not ready to send")
    func emptyRequest() {
        #expect(DesignBrief(request: "   ").isReady == false)
        #expect(DesignBrief(request: "the composer").isReady)
    }

    @Test("The follow-ups say which artboard and what a mock is")
    func followUps() {
        let board = DesignBoard(
            directory: ".tailscode/design/composer-0818",
            manifest: DesignManifest.parse(manifestJSON)!)
        let b = board.artboards[1]
        let implement = DesignFollowUp.implement(board: board, artboard: b, notes: "tighter gaps")
        #expect(implement.contains(".tailscode/design/composer-0818/B.html"))
        #expect(implement.contains("Adaptive row"))
        #expect(implement.contains("picture of the result"))
        #expect(implement.contains("tighter gaps"))

        let tweak = DesignFollowUp.tweak(board: board, artboard: b, instruction: "bigger targets")
        #expect(tweak.contains("Rewrite .tailscode/design/composer-0818/B.html in place"))
        #expect(tweak.contains("bigger targets"))
        #expect(tweak.contains("do not touch the app's source"))

        let another = DesignFollowUp.another(board: board, instruction: "one for a tablet")
        #expect(another.contains("next free letter after A, B"))
    }

    @Test("The surface names its state rather than collapsing it to no board")
    func phases() {
        var state = DesignBoardState(directory: ".tailscode/design/composer-0818")
        #expect(state.phase == .loading)
        #expect(state.title == "composer 0818")
        state.failed("the manifest would not parse")
        #expect(state.subtitle == "the manifest would not parse")
        state.arrived(DesignBoard(directory: "d", manifest: DesignManifest(title: "T", artboards: [])))
        #expect(state.phase == .empty)
    }

    @Test("Picking walks and wraps, and never leaves the board")
    func selection() {
        var state = DesignBoardState(directory: "d")
        state.arrived(
            DesignBoard(directory: "d", manifest: DesignManifest.parse(manifestJSON)!))
        #expect(state.isReady)
        #expect(state.current?.letter == "A")
        state.step(1)
        #expect(state.current?.letter == "B")
        state.step(1)
        #expect(state.current?.letter == "A")
        state.step(-1)
        #expect(state.current?.letter == "B")
        state.select(99)
        #expect(state.current?.letter == "B")
        state.select(-3)
        #expect(state.current?.letter == "A")
        #expect(state.subtitle == "1 of 2 · A · Conservative")
        #expect(state.implementTitle == "Build A")
    }

    @Test("A mock is readable on a phone even when the agent forgot the tag")
    func viewport() {
        let bare = "<html><head><title>A</title></head><body>hi</body></html>"
        #expect(DesignRender.prepared(bare).contains("width=device-width"))
        let already =
            "<html><head><meta name=\"viewport\" content=\"width=device-width\"></head></html>"
        #expect(DesignRender.prepared(already) == already)
        let headless = "<div>just a fragment</div>"
        #expect(DesignRender.prepared(headless).contains("width=device-width"))
    }

    @Test("The card says what it has, before and after the board is read")
    func card() {
        let sighting = DesignSighting(
            source: .board(directory: "d/composer-redesign"), messageID: "m", toolUseID: "t",
            at: Date())
        let blind = DesignCardReading.make(sighting: sighting, board: nil)
        #expect(blind.title == "composer redesign")
        #expect(blind.action == "Open board")
        let read = DesignCardReading.make(
            sighting: sighting,
            board: DesignBoard(
                directory: "d/composer-redesign", manifest: DesignManifest.parse(manifestJSON)!))
        #expect(read.title == "Composer redesign")
        #expect(read.detail == "2 artboards to choose from")
        #expect(read.letters == ["A", "B"])
    }

    @Test("The app answers /design itself, and only where a board could be read back")
    func dispatch() {
        let catalog = [
            AgentCommand(name: "design", details: "the server's own", source: .skill),
            AgentCommand(name: "commit", details: "", source: .builtin),
        ]
        #expect(
            SlashDispatch.decide(
                text: "/design the composer", commands: catalog, supportsCompaction: true,
                resolvesFromPromptText: false, supportsDesign: true)
                == .designPreflight(request: "the composer"))
        #expect(
            SlashDispatch.decide(
                text: "/design", commands: catalog, supportsCompaction: true,
                resolvesFromPromptText: false, supportsDesign: true)
                == .designPreflight(request: ""))
        #expect(
            SlashDispatch.decide(
                text: "/design the composer", commands: catalog, supportsCompaction: true,
                resolvesFromPromptText: false, supportsDesign: false)
                == .run(command: catalog[0], arguments: "the composer"))
    }

    @Test("The composer's catalog offers the word exactly once")
    func catalogContribution() {
        let server = [
            AgentCommand(name: "design", details: "the server's own", source: .skill),
            AgentCommand(name: "commit", details: "", source: .builtin),
        ]
        let offered = CommandCatalogStore.forComposer(server, supportsDesign: true)
        #expect(offered.filter { $0.name == "design" }.count == 1)
        #expect(offered.first?.scope == "Tailscode")
        #expect(CommandCatalogStore.forComposer(server, supportsDesign: false) == server)
    }
}
