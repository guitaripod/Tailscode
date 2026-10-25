import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    static func checkAgentsWrapping(
        _ window: AgentsWindow, expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws {
        let now = Date()
        let long = AgentsStress.board(now: now)
        window.apply(board: long)
        pump(0.45)
        let key = AgentDemo.homelab + "/ask"
        guard let card = window.boardView.askCard(key), let row = window.boardView.row(AgentDemo.homelab + "/busy")
        else { throw SelfTestFailure("agents: the long board lost a card or a row") }
        let column = window.boardView.contentColumn
        func fits(_ widget: UnsafeMutablePointer<GtkWidget>, _ label: String) throws {
            guard let box = Gtk.bounds(of: widget, in: window.window) else {
                throw SelfTestFailure("agents: \(label) has no place in the window")
            }
            var least: Int32 = 0
            var natural: Int32 = 0
            var ignoredA: Int32 = 0
            var ignoredB: Int32 = 0
            gtk_widget_measure(
                widget, GTK_ORIENTATION_VERTICAL, Int32(box.width.rounded()), &least, &natural, &ignoredA,
                &ignoredB)
            try expect(
                box.height >= Double(natural) - 1,
                "\(label) is not clipped: allocated \(box.height) of \(natural) at \(box.width)")
        }
        let object = card.objectLabel
        try fits(object, "a command four hundred characters long")
        var lineLeast: Int32 = 0
        var lineNatural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        let probe = Gtk.label("x", css: "agents-object", selectable: false)
        gtk_widget_measure(probe, GTK_ORIENTATION_VERTICAL, -1, &lineLeast, &lineNatural, &ignoredA, &ignoredB)
        try expect(
            gtk_widget_get_height(object) >= lineNatural * 3,
            "the command wraps onto several lines: \(gtk_widget_get_height(object)) against \(lineNatural)")
        if let inside = Gtk.bounds(of: object, in: column) {
            try expect(
                inside.x >= 0 && inside.x + inside.width <= Double(gtk_widget_get_width(column)) + 1,
                "and stays inside the column: \(inside.x)+\(inside.width) of \(gtk_widget_get_width(column))")
        }
        try fits(card.widget, "the whole card")
        try fits(card.leadLabel, "its lead")
        try fits(row.titleLabel, "a title two hundred characters long")
        try fits(row.widget, "its row")
        let lineHeight = gtk_widget_get_height(row.lineLabel)
        var oneLine: Int32 = 0
        let probeLine = Gtk.label("x", css: "agents-line", selectable: false)
        gtk_widget_measure(probeLine, GTK_ORIENTATION_VERTICAL, -1, &lineLeast, &oneLine, &ignoredA, &ignoredB)
        try expect(
            lineHeight <= oneLine * 2 + 4,
            "a row's line stops at two lines: \(lineHeight) against \(oneLine)")
        var oneTitle: Int32 = 0
        let probeTitle = Gtk.label("x", css: "agents-title", selectable: false)
        gtk_widget_measure(probeTitle, GTK_ORIENTATION_VERTICAL, -1, &lineLeast, &oneTitle, &ignoredA, &ignoredB)
        try expect(
            gtk_widget_get_height(row.titleLabel) >= oneTitle * 2 - 2 && gtk_label_get_ellipsize(op(row.titleLabel)) == PANGO_ELLIPSIZE_NONE,
            "while its title wraps whole: \(gtk_widget_get_height(row.titleLabel)) against \(oneTitle)")
        let five = "ls\ncd /tmp/build\nrm -rf ./cache ./derived\ngit clean -fdx\necho finished all of it, every last line"
        window.apply(board: AgentsStress.board(now: now, askCommand: five))
        pump(0.45)
        guard let multi = window.boardView.askCard(key) else {
            throw SelfTestFailure("agents: the five-line ask has no card")
        }
        let shown = gtk_label_get_text(op(multi.objectLabel)).map { String(cString: $0) } ?? ""
        try expect(shown == five, "every line of a five-line command is shown: \(shown.split(separator: "\n").count) lines")
        try fits(multi.objectLabel, "the five-line command")
        guard let labelBox = Gtk.bounds(of: multi.objectLabel, in: window.window),
            let holderBox = Gtk.bounds(of: multi.objectBox, in: window.window)
        else { throw SelfTestFailure("agents: the five-line command has no place") }
        try expect(
            labelBox.height >= Double(lineNatural) * 2.5 && holderBox.height >= labelBox.height - 1,
            "and the card holds all five without scrolling: \(labelBox.height) in \(holderBox.height)")
        try expect(!multi.objectScrolls, "five lines are laid out whole, not scrolled")
        let forty = (0..<40).map { "step \($0): swift build --configuration release" }.joined(separator: "\n")
        window.apply(board: AgentsStress.board(now: now, askCommand: forty))
        pump(0.45)
        guard let tall = window.boardView.askCard(key),
            let tallHolder = Gtk.bounds(of: tall.objectBox, in: window.window)
        else { throw SelfTestFailure("agents: the forty-line ask has no card") }
        var tallLeast: Int32 = 0
        var tallNatural: Int32 = 0
        gtk_widget_measure(
            tall.objectLabel, GTK_ORIENTATION_VERTICAL, gtk_widget_get_width(tall.objectLabel),
            &tallLeast, &tallNatural, &ignoredA, &ignoredB)
        try expect(
            tall.objectScrolls && tallHolder.height <= Double(AgentsAskCard.objectCeiling) + 24
                && tallNatural > AgentsAskCard.objectCeiling,
            "a command too long for a card scrolls inside it and loses no line: box \(tallHolder.height) of \(tallNatural)")
        try expect(
            (gtk_label_get_text(op(tall.objectLabel)).map { String(cString: $0) } ?? "") == forty,
            "all forty lines are in the box")
        window.apply(board: AgentDemo.board(now: now))
        pump(0.4)
    }

    static func checkAgentsHour(
        _ window: AgentsWindow, source: ScriptedAgentsSource, now: Date,
        expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws {
        window.show(.hour)
        pump(1.0)
        let core = AgentDemo.hour(now: now)
        try expect(
            window.hourView.laneCount == core.lanes.count && window.hourView.laneIDs == core.lanes.map(\.id),
            "the hour has Core's lanes, in Core's order: \(window.hourView.laneCount) of \(core.lanes.count)")
        let layout = window.hourView.layout
        for (index, lane) in layout.lanes.enumerated() {
            let middle = layout.top(ofLane: index) + layout.height(of: lane) / 2
            try expect(layout.lane(atY: middle) == index, "the middle of lane \(index) is lane \(index)")
        }
        try expect(layout.lane(atY: 2) == nil, "the ruler is no lane")
        let tops = layout.lanes.indices.map { layout.top(ofLane: $0) }
        try expect(tops == tops.sorted() && Set(tops).count == tops.count, "no lane sits on another")
        try expect(
            layout.x(of: Date(), now: Date()) >= layout.trackRight - 1
                && layout.x(of: Date().addingTimeInterval(-3600), now: Date()) <= layout.trackLeft + 1,
            "now is the right edge and an hour ago the left")
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(
            window.hourView.area, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, &ignoredA, &ignoredB)
        try expect(
            Double(minimum) >= layout.contentHeight,
            "the area is tall enough for every lane: \(minimum) for \(layout.contentHeight)")
        let before = window.hourView.draws
        pump(1.2)
        let drawn = window.hourView.draws - before
        try expect(drawn >= 1 && drawn <= 3, "the hour draws about once a second and no faster: \(drawn) in 1.5 seconds")
        window.hourView.chooseLane(at: 3)
        pump(0.45)
        let lane = layout.lanes[3]
        try expect(
            window.selectedKey == "demo-homelab/ask" && window.peek.key == "demo-homelab/ask"
                && window.peek.askCard != nil,
            "a demo lane opens the peek of the board's own session, by exact key: \(window.selectedKey ?? "nil")")
        window.hourView.chooseLane(at: 1)
        pump(0.4)
        try expect(
            window.selectedKey == "demo-studio/w" && window.selectedLane == "demo-studio/w#x",
            "and an agent's lane opens its session's peek: \(window.selectedKey ?? "nil")")
        window.hourView.chooseLane(at: 3)
        pump(0.4)
        try expect(
            window.selectedKey == lane.profileID + "/" + lane.sessionID && window.selectedLane == lane.id
                && window.peekRevealed,
            "selecting a lane fills the inspector with its peek: \(window.selectedKey ?? "nil")")
        window.show(.now)
        pump(0.3)
        let hidden = window.hourView.draws
        pump(1.2)
        try expect(
            window.hourView.draws - hidden <= 1,
            "a hidden hour draws nothing: \(window.hourView.draws - hidden)")
        window.deselect()
    }

    /// The real tower over Core's scripted demo servers: opened by the window it holds a watch on a
    /// running session, closed it holds none, and opened again it watches once more.
    static func checkAgentsTower(pump: (Double) -> Void) throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("agents tower: \(label)") }
            claims += 1
        }
        let profile = DemoWorld.claudeProfile
        guard let backend = DemoWorld.backend(for: profile.id) else {
            throw SelfTestFailure("agents tower: the demo world has no backend")
        }
        let sessions: [AgentSession] = agentsBlocking { (try? await backend.listSessions()) ?? [] }
        let entries = sessions.map {
            SessionEntry(
                profileID: profile.id, profileName: profile.name, host: "studio",
                backendType: .claudeCode, session: $0)
        }
        try expect(entries.contains { $0.session.isWorking }, "the demo world lists a running session")
        let tower = AgentTower(
            setup: AgentTowerSetup(
                backend: { $0 == profile.id ? DemoWorld.backend(for: $0) : nil }, catalog: { _ in [] }))
        agentsBlocking {
            await tower.update(entries: entries, reachability: [profile.id: true], unread: [])
        }
        let working = entries.first { $0.session.isWorking }.map { profile.id + "/" + $0.session.id } ?? ""
        func watched() -> Bool {
            agentsBlocking { await Self.firstFacts(tower, key: working) } != nil
        }
        try expect(!watched(), "a closed tower watches nothing")
        let log = AgentsHookLog()
        let window = AgentsWindow.present(parent: nil, source: TowerSource(tower: tower), hooks: log.hooks)
        var waited = 0.0
        while !watched(), waited < 6 {
            pump(0.1)
            waited += 0.1
        }
        try expect(watched(), "an open board watches the running session")
        try expect(
            agentsBlocking { await tower.current }.working.contains { $0.id == working }
                || agentsBlocking { await tower.current }.finished.contains { $0.id == working }
                || agentsBlocking { await tower.current }.background.contains { $0.id == working }
                || agentsBlocking { await tower.current }.needsYou.contains { $0.id == working },
            "and the board it publishes carries that session")
        window.close()
        pump(0.5)
        try expect(!window.isLive && AgentsWindow.current == nil, "closing the window ends its work")
        var gone = 0.0
        while watched(), gone < 4 {
            pump(0.1)
            gone += 0.1
        }
        try expect(!watched(), "and the tower is left holding no watch")
        let reopened = AgentsWindow.present(parent: nil, source: TowerSource(tower: tower), hooks: log.hooks)
        var back = 0.0
        while !watched(), back < 6 {
            pump(0.1)
            back += 0.1
        }
        try expect(watched(), "a reopened board watches again")
        reopened.close()
        pump(0.5)
        var again = 0.0
        while watched(), again < 4 {
            pump(0.1)
            again += 0.1
        }
        try expect(!watched(), "and lets it go again")
        return claims
    }

    static func firstFacts(_ tower: AgentTower, key: String) async -> AgentFacts? {
        for await facts in await tower.facts(for: key) { return facts }
        return nil
    }

    static func agentsBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = AgentsBlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await work()
            done.signal()
        }
        while done.wait(timeout: .now()) != .success {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(2000)
        }
        return box.value!
    }
}

private final class AgentsBlockingBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}
