import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Quick ask actions", .serialized)
    struct QuickAskActionTests {

        private let seeing = ModelAbilities(attachments: true, vision: true)
        private let desk = QuickAskSurfaceAbilities.desktop(screen: true, localFiles: true)

        private func withFile(_ body: (URL) throws -> Void) rethrows {
            let previous = QuickAskActions.fileURL
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-actions-\(UUID().uuidString)")
            let url = folder.appendingPathComponent("quick-actions.json")
            QuickAskActions.fileURL = url
            QuickAskActions.forget()
            defer {
                try? FileManager.default.removeItem(at: folder)
                QuickAskActions.fileURL = previous
                QuickAskActions.forget()
            }
            try body(url)
        }

        private func written(_ url: URL, _ json: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
            QuickAskActions.forget()
        }

        @Test("A brace that is not a token stays words")
        func bracesThatAreNotTokens() {
            let pieces = QuickAskTemplate.pieces("map {x: 1} then {clipboard} and {latest:~/Downloads}{")
            #expect(
                pieces == [
                    .words("map {x: 1} then "), .token(.clipboard), .words(" and "),
                    .token(.latest("~/Downloads")), .words("{"),
                ])
            #expect(QuickAskTemplate.tokens("{latest:} {Session} {nope}") == [.session])
        }

        @Test("Copied words go where the template says, or under the instruction")
        func clipboardPlacement() {
            let named = QuickAskAction(
                id: "a", title: "A", prompt: "Look at {clipboard} closely", offer: .text)
            #expect(
                QuickAskTemplate.compose(named, fill: QuickAskFill(clipboard: "this")).text
                    == "Look at this closely")
            let plain = QuickAskAction(id: "b", title: "B", prompt: "Explain this:", offer: .text)
            #expect(
                QuickAskTemplate.compose(plain, fill: QuickAskFill(clipboard: "words")).text
                    == "Explain this:\n\nwords")
            let files = QuickAskAction(id: "f", title: "F", prompt: "Review this.", offer: .files)
            #expect(
                QuickAskTemplate.compose(files, fill: QuickAskFill(clipboard: "`/a.swift`")).text
                    == "Review this.\n\n`/a.swift`")
            let starter = QuickAskAction(id: "c", title: "C", prompt: "Explain ")
            #expect(
                QuickAskTemplate.compose(starter, fill: QuickAskFill(clipboard: "words")).text
                    == "Explain ")
        }

        @Test("The caret lands on {cursor}, else at the end, and gathered tokens leave no words")
        func caretAndGathers() {
            let action = QuickAskAction(
                id: "d", title: "D", prompt: "{screen}On {date}, {cursor} about {session}.")
            let day = Date(timeIntervalSince1970: 1_793_620_800)
            let composed = QuickAskTemplate.compose(
                action, fill: QuickAskFill(session: "the chat", date: day))
            #expect(composed.text == "On 2026-11-02,  about the chat.")
            #expect(composed.caret == "On 2026-11-02, ".count)
            #expect(action.gathers == [.screen, .session])
            let latest = QuickAskAction(id: "e", title: "E", prompt: "Take {latest:~/Downloads} and ")
            let filled = QuickAskTemplate.compose(
                latest, fill: QuickAskFill(), latest: { $0 == "~/Downloads" ? "/home/me/Downloads/v.mov" : nil })
            #expect(filled.text == "Take /home/me/Downloads/v.mov and ")
            #expect(filled.caret == filled.text.count)
        }

        @Test("An action is offered only where its tokens can be gathered")
        func offeredWhereGatherable() {
            let screen = QuickAskAction(id: "s", title: "S", prompt: "{screen}What? ")
            #expect(screen.isOffered(abilities: seeing, surface: desk))
            #expect(!screen.isOffered(abilities: .words, surface: desk))
            #expect(!screen.isOffered(abilities: seeing, surface: .phone))
            let latest = QuickAskAction(id: "l", title: "L", prompt: "{latest:~/Downloads}")
            #expect(!latest.isOffered(abilities: seeing, surface: .desktop(screen: true, localFiles: false)))
            var hidden = QuickAskAction(id: "h", title: "H", prompt: "x")
            hidden.hidden = true
            #expect(!hidden.isOffered(abilities: seeing, surface: desk))
        }

        @Test("A copied link is a link only when it is one address and nothing else")
        func linkDetection() {
            #expect(QuickAskClipboard.link(in: " https://x.com/a/status/1?s=20 \n") != nil)
            #expect(QuickAskClipboard.link(in: "see https://x.com/a") == nil)
            #expect(QuickAskClipboard.link(in: "ftp://host.org/file") == nil)
            #expect(QuickAskClipboard.link(in: "https://localhost") == nil)
            let held = QuickAskClipboard.holding(of: ClipboardOffer(text: "https://www.youtube.com/watch?v=1"))
            #expect(held?.holding == .link("https://www.youtube.com/watch?v=1"))
            #expect(held?.holding.host == "youtube.com")
            #expect(QuickAskClipboard.headline(for: .link("https://github.com/a/b")) == "Copied link · github.com")
        }

        @Test("A link is offered its site's errands first and the ones for any page after")
        func linkErrands() throws {
            try withFile { _ in
                let thread = QuickAskClipboard.errands(
                    for: .link("https://mobile.x.com/a/status/1"), abilities: .words, surface: desk)
                #expect(
                    thread.map(\.id) == [
                        "link.thread", "link.source", "link.download", "link.summarize", "link.what",
                    ])
                let page = QuickAskClipboard.errands(
                    for: .link("https://example.org/post"), abilities: .words, surface: desk)
                #expect(page.map(\.id) == ["link.summarize", "link.what"])
                #expect(page.allSatisfy { $0.takes == .link })
                #expect(page[0].opening.hasSuffix("\n\n"))
            }
        }

        @Test("With no file, the actions are the app's own, and a write keeps unchanged built-ins as bare ids")
        func builtInsAndBareIDs() throws {
            try withFile { url in
                #expect(QuickAskActions.all().map(\.id) == QuickAskBuiltIns.all.map(\.id))
                let custom = QuickAskAction(
                    id: "custom.frame", title: "Frame it", glyph: "▢",
                    prompt: "Frame {latest:~/Downloads} with frames-cli", sends: true)
                QuickAskActions.save(custom)
                QuickAskActions.remove(id: "draft")
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(text.contains("\"id\" : \"web\"\n"))
                #expect(!text.contains("Search the web for"))
                #expect(text.contains("frames-cli"))
                QuickAskActions.forget()
                let read = QuickAskActions.all()
                #expect(read.last == custom)
                #expect(read.first { $0.id == "draft" }?.hidden == true)
                #expect(!QuickAskActions.visible().contains { $0.id == "draft" })
                QuickAskActions.remove(id: custom.id)
                #expect(QuickAskActions.action(id: custom.id) == nil)
            }
        }

        @Test("A built-in rewritten by hand keeps every field it does not mention")
        func handPatchedBuiltIn() throws {
            try withFile { url in
                try written(
                    url,
                    """
                    {"actions": [
                      {"id": "web", "prompt": "Research on the web: ", "aim": {"server": "arch", "model": "anthropic/opus"}},
                      {"id": "custom.x", "title": "", "prompt": "Ping {clipboard}", "offer": "text"},
                      {"title": "no id"},
                      {"id": "custom.empty", "title": "Nothing"}
                    ]}
                    """)
                let web = try #require(QuickAskActions.action(id: "web"))
                #expect(web.prompt == "Research on the web: ")
                #expect(web.title == QuickAskBuiltIns.action(id: "web")?.title)
                #expect(web.aim?.server == "arch")
                #expect(web.aim?.selection?.rawValue == "anthropic/opus")
                #expect(QuickAskActions.action(id: "custom.x")?.title == "Ping {clipboard}")
                #expect(QuickAskActions.unreadable == 2)
                #expect(QuickAskActions.all().first?.id == "web")
            }
        }

        @Test("A rewritten built-in is written as what changed, and a written action without its defaults")
        func leanFile() throws {
            try withFile { url in
                var web = try #require(QuickAskActions.action(id: "web"))
                web.aim = QuickAskActionAim(server: "arch")
                QuickAskActions.save(web)
                QuickAskActions.save(QuickAskAction(id: "custom.lean", title: "Lean", prompt: "Hi"))
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains("Search the web for"))
                #expect(text.contains("\"server\" : \"arch\""))
                #expect(!text.contains("\"hidden\" : false"))
                #expect(!text.contains("\"hosts\""))
                #expect(!text.contains("\"sparkle\""))
                QuickAskActions.forget()
                #expect(QuickAskActions.action(id: "web")?.prompt == QuickAskBuiltIns.action(id: "web")?.prompt)
                #expect(QuickAskActions.action(id: "web")?.aim?.server == "arch")
                #expect(QuickAskActions.action(id: "custom.lean")?.title == "Lean")
            }
        }

        @Test("A file that does not parse is set aside before anything overwrites it")
        func unreadableFileIsKept() throws {
            try withFile { url in
                try written(url, "{ not json")
                #expect(QuickAskActions.unreadable == 1)
                #expect(QuickAskActions.all().count == QuickAskBuiltIns.all.count)
                QuickAskActions.remove(id: "code")
                let aside = url.appendingPathExtension("unreadable")
                #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
                #expect(QuickAskActions.action(id: "code")?.hidden == true)
            }
        }

        @Test("Moving steps over hidden actions and the other kind")
        func moving() throws {
            try withFile { _ in
                let first = QuickAskActions.visible().filter { $0.offer == .always }.map(\.id)
                QuickAskActions.move(id: first[1], by: -1)
                let moved = QuickAskActions.visible().filter { $0.offer == .always }.map(\.id)
                #expect(moved[0] == first[1] && moved[1] == first[0])
                QuickAskActions.setHidden(true, id: moved[1])
                QuickAskActions.move(id: moved[0], by: 1)
                let stepped = QuickAskActions.visible().filter { $0.offer == .always }.map(\.id)
                #expect(stepped[0] == moved[2] && stepped[1] == moved[0])
                QuickAskActions.restoreBuiltIns()
                #expect(QuickAskActions.visible().map(\.id) == QuickAskBuiltIns.all.map(\.id))
            }
        }

        @Test("Starters come from the actions, in the person's order, against the surface")
        func startersFromActions() throws {
            try withFile { _ in
                let desktop = QuickAskStarters.offered(for: seeing, surface: desk, recents: [])
                #expect(desktop.contains { $0.id == "screen" })
                #expect(desktop.contains { $0.id == "continue" })
                #expect(!desktop.contains { $0.id == "camera" })
                let phone = QuickAskStarters.offered(
                    for: ModelAbilities(attachments: true, vision: true, camera: true), recents: [])
                #expect(!phone.contains { $0.id == "screen" || $0.id == "continue" || $0.id == "latest" })
                #expect(phone.first { $0.id == "photo" }?.opens == .photos)
                #expect(phone.first { $0.id == "file" }?.needs == .attachments)
            }
        }

        @Test("An aim matches a saved machine by id, then by name")
        func aimFindsMachine() {
            let profiles = [
                ConnectionProfile(id: "A1", name: "arch", backend: .claudeCode, baseURL: URL(string: "http://arch:4096")!),
                ConnectionProfile(id: "M2", name: "MacBook", backend: .openCode, baseURL: URL(string: "http://mac:4096")!),
            ]
            #expect(QuickAskActionAim(server: "M2").profileID(among: profiles) == "M2")
            #expect(QuickAskActionAim(server: "macbook").profileID(among: profiles) == "M2")
            #expect(QuickAskActionAim(server: "gone").profileID(among: profiles) == nil)
            let twins = profiles + [
                ConnectionProfile(id: "A3", name: "arch", backend: .omp, baseURL: URL(string: "http://arch:4099")!)
            ]
            let local = QuickAskActionAim(server: "arch", model: "llama-swap/bolt")
            #expect(
                local.profileID(among: twins) { id in
                    id == "A3" ? [ModelInfo(id: "bolt", name: "Bolt", providerID: "llama-swap")] : []
                } == "A3")
            #expect(local.profileID(among: twins) { _ in [] } == "A1")
            #expect(QuickAskActionAim(server: " ", model: "").isEmpty)
        }

        @Test("An action's aim holds for one question, unless the person moves it by hand")
        func aimHold() {
            let server = "tailscode.quickask.server"
            let saved = UserDefaults.standard.string(forKey: server)
            defer {
                QuickAskDefaults.clearOwnAim(forProfileID: "hold-a")
                QuickAskDefaults.clearOwnAim(forProfileID: "hold-b")
                if let saved { UserDefaults.standard.set(saved, forKey: server) } else {
                    UserDefaults.standard.removeObject(forKey: server)
                }
            }
            QuickAskDefaults.record(profileID: "hold-a")
            QuickAskDefaults.recordModel(ModelSelection(string: "x/one"), forProfileID: "hold-a")
            var hold = QuickAskAimHold.begin(profileIDs: ["hold-a", "hold-b"])
            QuickAskDefaults.record(profileID: "hold-b")
            QuickAskDefaults.recordModel(ModelSelection(string: "x/two"), forProfileID: "hold-b")
            QuickAskDefaults.recordEffort("high", forProfileID: "hold-b")
            hold.settle()
            hold.release()
            #expect(QuickAskDefaults.lastProfileID == "hold-a")
            #expect(QuickAskDefaults.model(forProfileID: "hold-a")?.rawValue == "x/one")
            #expect(!QuickAskDefaults.hasOwnAim(forProfileID: "hold-b"))

            var moved = QuickAskAimHold.begin(profileIDs: ["hold-a"])
            QuickAskDefaults.recordModel(ModelSelection(string: "x/three"), forProfileID: "hold-a")
            moved.settle()
            QuickAskDefaults.recordModel(ModelSelection(string: "x/mine"), forProfileID: "hold-a")
            moved.release()
            #expect(QuickAskDefaults.model(forProfileID: "hold-a")?.rawValue == "x/mine")
        }

        @Test("The party send reaches every slot that can answer, once")
        func partyTargets() {
            func card(_ slot: Int, _ model: String?, profile: String?, away: Bool = false, spent: Bool = false)
                -> PartyCard
            {
                let preset = model.flatMap(ModelSelection.init(string:)).map {
                    ModelPreset(selection: $0, effort: .level("high"))
                }
                return PartyCard(
                    slot: slot, preset: preset, name: nil, modelWord: model ?? "", title: "",
                    subtitle: "", chip: nil, bars: 0, takesLevels: true, machine: nil,
                    server: profile, profileID: profile, resolved: preset, isInUse: false,
                    isAway: away, isSpent: spent, serverAnswers: true, spoken: "")
            }
            let cards = [
                card(0, "a/opus", profile: "p1"), .hollow(1), card(2, "b/bolt", profile: "p2"),
                card(3, "c/away", profile: "p3", away: true), card(4, "d/spent", profile: "p1", spent: true),
                card(5, "a/opus", profile: "p1"),
            ]
            #expect(QuickAskParty.targets(cards).map(\.word) == ["a/opus", "b/bolt"])
        }

        @Test("A conversation is named so an agent can find it")
        func sessionWords() {
            let entry = SessionEntry(
                profileID: "p", profileName: "arch", host: "arch", backendType: .omp,
                session: AgentSession(
                    id: "5C83", agentType: .omp, title: "God of War setup", parentID: nil,
                    directory: "/home/me/games", createdAt: Date(), updatedAt: Date()))
            let words = QuickAskSessionReference.words(for: entry)
            #expect(words.contains("Oh My Pi"))
            #expect(words.contains("“God of War setup”"))
            #expect(words.contains("id 5C83"))
            #expect(words.contains("/home/me/games"))
            #expect(words.contains("arch"))
        }

        @Test("The newest file in a folder, hidden and partial ones left out")
        func latestFile() throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("latest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let now = Date()
            for (name, age) in [("old.mov", 300.0), ("new.mov", 100.0), (".hidden", 0.0), ("get.part", 0.0)] {
                let url = folder.appendingPathComponent(name)
                try Data("x".utf8).write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            #expect(QuickAskLocal.latestFile(in: folder.path) == folder.appendingPathComponent("new.mov").path)
            #expect(QuickAskLocal.latestFile(in: folder.appendingPathComponent("none").path) == nil)
            #expect(QuickAskLocal.mention(["/a b", "/c"]) == "`/a b`\n`/c`")
        }
    }
}
