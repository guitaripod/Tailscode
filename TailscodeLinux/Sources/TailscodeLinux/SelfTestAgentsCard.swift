import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    private static func widgets(
        under root: UnsafeMutablePointer<GtkWidget>, _ visit: (UnsafeMutablePointer<GtkWidget>) -> Void
    ) {
        visit(root)
        var child = gtk_widget_get_first_child(root)
        while let current = child {
            widgets(under: current, visit)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    private static func holds(_ root: UnsafeMutablePointer<GtkWidget>, css names: [String]) -> Bool {
        var found = false
        widgets(under: root) { widget in
            if names.contains(where: { gtk_widget_has_css_class(widget, $0) != 0 }) { found = true }
        }
        return found
    }

    private static func sayings(of root: UnsafeMutablePointer<GtkWidget>, containing needle: String) -> Int {
        var count = 0
        widgets(under: root) { widget in
            guard tailscode_is_label(widget) != 0, gtk_widget_get_visible(widget) != 0,
                let text = gtk_label_get_text(op(widget))
            else { return }
            if String(cString: text).lowercased().contains(needle) { count += 1 }
        }
        return count
    }

    static func checkAgentsSidebar(
        reading: AgentsReading, expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        tailscode_set_animations_enabled(1)
        let previousDemo = DemoMode.isActive
        DemoMode.isActive = true
        let flag = ShimmerFlag()
        let host = MainWindow()
        host.agentsShimmer = flag.memory
        let pane = host.makeSidebarPane()
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 300, 900)
        gtk_window_set_child(ptr(window), pane)
        gtk_window_present(ptr(window))
        defer {
            AgentsWindow.close()
            pump(0.3)
            gtk_window_destroy(ptr(window))
            DemoMode.isActive = previousDemo
            tailscode_set_animations_enabled(1)
        }
        pump(0.5)
        guard let column = host.sidebarColumn, let entry = host.agentsEntry else {
            throw SelfTestFailure("entry: the sidebar has no Agents card")
        }

        try note(
            gtk_widget_get_first_child(column) == entry.widget
                && gtk_widget_get_next_sibling(entry.widget) == host.searchEntry
                && gtk_widget_get_next_sibling(host.searchEntry) == host.sidebarBanner,
            "the card heads the sidebar and the filter follows it with nothing between it and the list")
        try note(
            !holds(column, css: ["agents-now", "agents-now-row", "agents-pill", "agents-pill-text"]),
            "there is no On now section and no pill: the card is the one entry")
        try note(
            gtk_widget_get_tooltip_text(entry.button).map { String(cString: $0) }
                == "What every agent is doing · Ctrl+Shift+A",
            "the tooltip names the shortcut")
        try note(
            gtk_widget_get_focusable(entry.button) != 0 && gtk_widget_get_can_target(entry.button) != 0,
            "the card is a button the keyboard reaches")
        gtk_widget_grab_focus(entry.button)
        pump(0.2)
        try note(gtk_widget_has_focus(entry.button) != 0, "and takes focus")
        try note(
            entry.ownsKey(Keymap.enter, state: 0, in: window) && entry.ownsKey(0x20, state: 0, in: window)
                && !entry.ownsKey(Keymap.enter, state: KeyChord.controlMask, in: window)
                && !entry.ownsKey(0x61, state: 0, in: window),
            "Enter and Space belong to the focused card, and no other key does")
        gtk_widget_grab_focus(host.searchEntry)
        pump(0.2)
        try note(
            !entry.ownsKey(Keymap.enter, state: 0, in: window),
            "and Enter is the window's again once focus is elsewhere")
        gtk_widget_grab_focus(entry.button)
        pump(0.2)

        host.refreshAgentsEntry()
        pump(0.4)
        try note(
            entry.chips.texts == ["2", "1", "1"] && entry.mood == .needs
                && entry.spokenName == "Agents, 2 working, 1 needs you, 3 agents, 1 in the background",
            "demo mode shows the card alive: \(entry.chips.texts) \(entry.spokenName)")
        try note(
            entry.sentenceText == "CI migration needs you" && entry.isSentenceShown
                && entry.orb.running == 4 && AgentsOrbit.shown(entry.orb.running) == 4
                && entry.orb.isTurning,
            "the sentence names the chat that waits and four lights circle the orb: \(entry.sentenceText)")
        try note(entry.glow.sweeps == 1, "the sidebar played its sweep when something first ran")
        try note(
            sayings(of: column, containing: "needs you") == 1,
            "what needs you is said once in the whole sidebar: \(sayings(of: column, containing: "needs you"))")

        gtk_widget_activate(entry.button)
        pump(0.6)
        try note(AgentsWindow.current != nil, "Enter or Space on the card opens the board")
        AgentsWindow.close()
        pump(0.4)
        tailscode_emit_clicked(entry.button)
        pump(0.6)
        try note(AgentsWindow.current != nil, "and so does a click")
        AgentsWindow.close()
        pump(0.4)

        claims += try checkAgentsRowChip(host: host, expect: expect, pump: pump)
        claims += try checkAgentsNarrow(host: host, pane: pane, window: window, expect: expect, pump: pump)
        return claims
    }

    static func checkAgentsRowChip(
        host: MainWindow, expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        let with = listRow("l", active: true, agents: 2)
        let without = listRow("w", active: true)
        let idle = listRow("i", active: false)
        let opened = ShimmerFlag()
        let chip = SidebarRow.agentsChip(with) { opened.set() }
        try note(
            chip != nil && SidebarRow.agentsChip(without) {} == nil && SidebarRow.agentsChip(idle) {} == nil,
            "only a working row with live sub-agents gets the chip")
        if let chip {
            tailscode_emit_clicked(chip)
            try note(opened.value, "a press on the chip is its own")
            var words = ""
            widgets(under: chip) { if tailscode_is_label($0) != 0 { words = String(cString: gtk_label_get_text(op($0))) } }
            try note(words == "2 agents", "it says how many: \(words)")
            g_object_ref_sink(UnsafeMutableRawPointer(chip))
            g_object_unref(UnsafeMutableRawPointer(chip))
        }
        let row = SidebarRow.make(
            with, focused: false, vocabulary: .full, onOpen: {},
            onAgents: { Gtk.onMain { [weak host] in host?.presentAgentPeek(of: with.entry) } }, onMenu: { _, _, _ in })
        var found: UnsafeMutablePointer<GtkWidget>?
        widgets(under: row) { if gtk_widget_has_css_class($0, "row-agents") != 0 { found = $0 } }
        try note(found != nil, "the chip sits in the row's meta line")
        if let found {
            tailscode_emit_clicked(found)
            pump(0.7)
            try note(
                AgentsWindow.current?.selectedKey == AgentDemo.homelab + "/l",
                "and opens that chat's peek in the board: \(String(describing: AgentsWindow.current?.selectedKey))")
            AgentsWindow.close()
            pump(0.4)
        }
        g_object_ref_sink(UnsafeMutableRawPointer(row))
        g_object_unref(UnsafeMutableRawPointer(row))
        return claims
    }

    static func checkAgentsNarrow(
        host: MainWindow, pane: UnsafeMutablePointer<GtkWidget>, window: UnsafeMutablePointer<GtkWidget>,
        expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        guard let column = host.sidebarColumn, let entry = host.agentsEntry,
            let long = MainWindow.agentsFace("long")
        else { throw SelfTestFailure("entry: no sidebar to narrow") }
        entry.apply(long)
        entry.fit(sidebarWidth: agentsNarrowWidth)
        gtk_window_set_default_size(ptr(window), Self.agentsNarrowWidth, 900)
        pump(0.6)
        let width = Double(gtk_widget_get_width(column))
        guard let card = Gtk.bounds(of: entry.button, in: column),
            let chips = Gtk.bounds(of: entry.chips.widget, in: column),
            let title = Gtk.bounds(of: entry.titleLabelWidget, in: column),
            let orb = Gtk.bounds(of: entry.orb.widget, in: column)
        else { throw SelfTestFailure("entry: the narrow card has no geometry") }
        try note(
            card.x >= 0 && card.x + card.width <= width + 1,
            "at \(Int(width)) wide the card stays inside the sidebar: \(card.x)+\(card.width)")
        try note(
            chips.x + chips.width <= card.x + card.width + 1 && chips.x >= title.x + title.width - 1
                && (!entry.isOrbShown || title.x >= orb.x + orb.width - 1),
            "the orb, the word and the chips never overlap: orb \(orb.x)+\(orb.width), title \(title.x)+\(title.width), chips \(chips.x)+\(chips.width)")
        try note(entry.chips.texts == ["345", "12", "7"], "three digits keep all their digits: \(entry.chips.texts)")
        if entry.isSentenceShown {
            let room = gtk_widget_get_width(entry.sentenceWidget)
            let lines = AgentsSidebarEntry.lines(entry.sentenceText, room: room, in: entry.sentenceWidget)
            try note(
                lines <= AgentsSidebarEntry.sentenceLines,
                "the sentence takes at most two lines where it is set: \(lines) at \(room)")
            try note(
                wholeWordsOnly(entry.sentenceText, of: long.waiting ?? ""),
                "and the name is cut between words, never through one: \(entry.sentenceText)")
        }
        try note(
            card.height <= Double(gtk_widget_get_height(entry.titleLabelWidget)) * 3.6 + 22,
            "the card is never taller than three lines: \(card.height)")
        entry.fit(sidebarWidth: 150)
        pump(0.2)
        try note(
            !entry.isSentenceShown && entry.chips.isShown(.working),
            "at the narrowest the sentence goes and the chips stay")
        entry.fit(sidebarWidth: 600)
        entry.apply(.quiet)
        try note(entry.sentenceText == "all quiet · Ctrl+Shift+A", "a quiet card shows the shortcut when it has the room")
        entry.fit(sidebarWidth: 215)
        try note(entry.sentenceText == "all quiet", "and leaves it out whole when it has not: \(entry.sentenceText)")
        return claims
    }

    private static func wholeWordsOnly(_ sentence: String, of name: String) -> Bool {
        guard let range = sentence.range(of: " needs you", options: .backwards) else { return false }
        let shown = String(sentence[..<range.lowerBound])
        if shown == name { return true }
        guard shown.hasSuffix("…") else { return false }
        let kept = String(shown.dropLast())
        guard name.hasPrefix(kept) else { return false }
        let after = name.index(name.startIndex, offsetBy: kept.count)
        return after == name.endIndex || name[after] == " "
    }

    static let agentsNarrowWidth: Int32 = 200
}
