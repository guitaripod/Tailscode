import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quick ask menu")
struct QuickAskMenuTests {
    private func starter(_ id: String, prompt: String = "Do ", aim: QuickAskActionAim? = nil) -> QuickAskStarter {
        QuickAskStarter(action: QuickAskAction(id: id, title: id.capitalized, prompt: prompt, aim: aim))
    }

    private func entry(_ id: String, title: String = "A chat") -> SessionEntry {
        SessionEntry(
            profileID: "p", profileName: "arch", host: "arch", backendType: .claudeCode,
            session: AgentSession(
                id: id, agentType: .claudeCode, title: title, parentID: nil, directory: nil,
                createdAt: Date(), updatedAt: Date()))
    }

    @Test("Typed words go where {cursor} stands, or after the action's own words")
    func typedArgument() {
        let web = QuickAskAction(id: "w", title: "W", prompt: "Search the web for ")
        let composed = QuickAskTemplate.compose(web, fill: QuickAskFill(typed: "  ipad mini rumours \n"))
        #expect(composed.text == "Search the web for ipad mini rumours")
        #expect(composed.caret == composed.text.count)
        let fix = QuickAskAction(id: "f", title: "F", prompt: "Fix:")
        #expect(QuickAskTemplate.compose(fix, fill: QuickAskFill(typed: "sound")).text == "Fix: sound")
        let port = QuickAskAction(id: "p", title: "P", prompt: "Set up {cursor} in Steam.")
        let ported = QuickAskTemplate.compose(port, fill: QuickAskFill(typed: "Crash"))
        #expect(ported.text == "Set up Crash in Steam.")
        #expect(ported.caret == "Set up Crash".count)
        #expect(QuickAskTemplate.compose(web, fill: QuickAskFill(typed: "   ")).text == "Search the web for ")
    }

    @Test("Actions lead with digits, a new-action line closes them, later and recent follow")
    func sections() {
        let later = QuickAskLater(text: "Rumours", profileID: "p", fireAt: Date().addingTimeInterval(600))
        let copied = QuickAskCopied(
            fingerprint: "f", holding: .link("https://x.com/a"), headline: "Copied link · x.com",
            preview: "https://x.com/a",
            errands: QuickAskBuiltIns.copied.filter { $0.offer == .link }.prefix(2)
                .map(QuickAskClipboardErrand.init(action:)))
        let sections = QuickAskMenu.sections(
            copied: copied,
            starters: [starter("find", aim: QuickAskActionAim(server: "arch")), starter("web")],
            later: [later], recents: [entry("r1")],
            aimWords: { $0.server.map { "on " + $0 } })
        #expect(sections.map(\.id) == ["copied", "actions", "later", "recent"])
        #expect(sections[0].isCopied && sections[0].note == "https://x.com/a")
        #expect(sections[0].items.map(\.digit) == [1, 2])
        #expect(sections[0].items.first?.action != nil)
        let actions = sections[1].items
        #expect(actions.map(\.id) == ["action:find", "action:web", "new-action"])
        #expect(actions.map(\.digit) == [3, 4, nil])
        #expect(actions[0].badge == "on arch" && actions[1].badge == nil)
        #expect(actions[0].action?.id == "find" && actions[2].action == nil)
        #expect(sections[2].items.first?.title == "Rumours" && sections[2].items.first?.digit == nil)
        #expect(QuickAskMenu.items(sections).count == 7)
        let empty = QuickAskMenu.sections(starters: [], later: [], recents: [])
        #expect(empty.map(\.id) == ["actions"] && empty[0].items.count == 1)
    }

    @Test("Chats to hand on are numbered from one")
    func sessions() {
        let items = QuickAskMenu.items(QuickAskMenu.sessions((0..<11).map { entry("s\($0)") }))
        #expect(items.first?.digit == 1 && items[8].digit == 9 && items[9].digit == nil)
        #expect(items.first?.detail == "Claude Code · arch")
    }

    @Test("A typed question is offered every action that can take it, never the hand-on")
    func verbs() {
        let starters = [starter("continue", prompt: "Read {session}")] + (0..<11).map { starter("v\($0)") }
        let sections = QuickAskMenu.verbs(starters)
        #expect(sections.map(\.id) == ["verbs"])
        let items = sections[0].items
        #expect(items.count == 11 && items.first?.id == "verb:v0")
        #expect(items[8].digit == 9 && items[9].digit == nil)
        #expect(QuickAskMenu.verbs([starter("continue", prompt: "Read {session}")]).isEmpty)
    }

    @Test("The cursor waits for an arrow, stops at the ends and follows its line")
    func cursor() {
        var cursor = QuickAskMenuCursor()
        #expect(cursor.index == nil)
        cursor.move(by: 1, count: 3)
        #expect(cursor.index == 0)
        cursor.move(by: 5, count: 3)
        #expect(cursor.index == 2)
        cursor.move(by: -3, count: 3)
        #expect(cursor.index == nil)
        cursor.move(by: -1, count: 3)
        #expect(cursor.index == 2)
        let items = QuickAskMenu.items(QuickAskMenu.sections(starters: [starter("x"), starter("y")], later: [], recents: []))
        cursor.follow(id: "action:y", in: items)
        #expect(cursor.index == 1)
        cursor.follow(id: "gone", in: items)
        #expect(cursor.index == nil)
        cursor.move(by: 1, count: 0)
        #expect(cursor.index == nil)
    }

    @Test("The footer says what the keys do for the box as it is")
    func footer() {
        let typing = QuickAskFooter.keys(platform: .linux, typing: true, party: true, screen: false, verbs: 3)
        #expect(typing.map(\.keys) == ["↵", "↓", "alt+↵", "alt+L"])
        let empty = QuickAskFooter.keys(platform: .apple, typing: false, party: false, screen: true, verbs: 0)
        #expect(empty.map(\.keys) == ["↑↓", "↩", "⌘1–9", "⇥", "⌘⇧S"])
    }
}
