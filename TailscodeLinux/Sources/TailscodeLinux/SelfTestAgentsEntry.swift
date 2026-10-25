import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

final class ShimmerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    var value: Bool { lock.withLock { held } }
    func set() { lock.withLock { held = true } }
    var memory: AgentsShimmerMemory {
        AgentsShimmerMemory(seen: { [self] in value }, remember: { [self] in set() })
    }
}

extension SelfTest {
    /// The sidebar's Agents card, its "On now" rows and its footer pill: what they say over Core's
    /// demo fiction, where they sit in the real sidebar, that a press on each reaches the board,
    /// that nothing overlaps or runs past a narrow column, and that the movement is arithmetic the
    /// desk can switch off — a still frame is the same frame at any time.
    static func checkAgentsEntry(
        expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        let now = Date()
        let reading = AgentsReading(board: AgentDemo.board(now: now))
        try note(
            reading.chip == AgentsChip(needsYou: 1, working: 2) && reading.mood == .needs,
            "the demo reads 2 working and 1 needing you, and is amber")
        try note(
            reading.rows.map(\.title) == ["CI migration", "Fix reconnect test", "Landing page refresh"]
                && reading.rows.map(\.needsYou) == [true, false, false],
            "the rows are what waits first, then what works: \(reading.rows.map(\.title))")
        try note(reading.running == 4, "four are running with the one in the background: \(reading.running)")
        try note(
            reading.footerText == Localized.text("%d needs you", 1),
            "the pill says what waits on you: \(reading.footerText)")
        try note(
            AgentsReading(chip: AgentsChip(needsYou: 0, working: 2), running: 4, rows: []).footerText
                == Localized.text("%d running", 4)
                && AgentsReading.quiet.footerText == Localized.text("All quiet"),
            "a working board says how many run and a quiet one says all quiet")

        guard gtk_init_check() != 0 else { return claims }
        MatrixTheme.install()
        claims += try checkAgentsStillness(expect: expect)
        claims += try checkAgentsMotion(expect: expect, pump: pump)
        claims += try checkAgentsSidebar(reading: reading, expect: expect, pump: pump)
        return claims
    }

    private static func orbPixels(_ mood: AgentsMood, time: Double, animated: Bool) -> [UInt8] {
        let side: Int32 = 22
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side)!
        let cr = cairo_create(surface)!
        AgentsMiniOrb.paint(cr, size: Double(side), mood: mood, time: time, animated: animated)
        cairo_surface_flush(surface)
        let data = cairo_image_surface_get_data(surface)!
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(side) * Int(side) * 4))
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
        return bytes
    }

    static func checkAgentsStillness(expect: (Bool, String) throws -> Void) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        for mood in [AgentsMood.working, .needs] {
            try note(
                orbPixels(mood, time: 0, animated: false) == orbPixels(mood, time: 0.95, animated: false),
                "\(mood) with reduced motion is the same picture at any time")
            try note(
                orbPixels(mood, time: 0, animated: true) != orbPixels(mood, time: 0.4, animated: true),
                "\(mood) moves when the desk allows it")
        }
        try note(
            orbPixels(.idle, time: 0, animated: true) == orbPixels(.idle, time: 0.95, animated: true),
            "and an idle bead is still whatever the desk allows")
        try note(
            AgentsSwell.at(.needs, time: 3, animated: false) == AgentsSwell.at(.needs, time: 9, animated: false),
            "the swell is a constant under reduced motion")
        return claims
    }

    static func checkAgentsMotion(
        expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        tailscode_set_animations_enabled(1)
        defer { tailscode_set_animations_enabled(1) }
        let flag = ShimmerFlag()
        let entry = AgentsSidebarEntry(memory: flag.memory) {}
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 320, 200)
        gtk_window_set_child(ptr(window), entry.widget)
        gtk_window_present(ptr(window))
        defer { gtk_window_destroy(ptr(window)) }
        pump(0.4)

        try note(
            !entry.orb.isTurning && !entry.glow.isTurning && entry.isHintShown,
            "an idle card runs no clock and carries the shortcut")
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 1, working: 2), running: 4, rows: []))
        pump(0.3)
        try note(
            entry.orb.isTurning && entry.glow.isTurning && !entry.isHintShown,
            "a busy card turns its orb and its glow and gives the tail to the counts")
        try note(
            entry.chips.texts == ["2", "1"] && entry.spokenName == "Agents, 2 working, 1 needs you",
            "two chips with digits, and the name a reader hears: \(entry.chips.texts) \(entry.spokenName)")
        try note(entry.chips.pops == 2, "both counts popped when they appeared: \(entry.chips.pops)")
        try note(entry.glow.sweeps == 1 && flag.value, "the first thing to say plays the sweep once and remembers it")
        pump(0.4)
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 1, working: 3), running: 5, rows: []))
        try note(
            entry.chips.pops == 3 && entry.chips.isPopping,
            "a changed count pops its chip alone: \(entry.chips.pops)")
        pump(0.5)
        try note(!entry.chips.isPopping, "and the pop is over inside a quarter of a second")
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 0, working: 3), running: 5, rows: []))
        try note(
            entry.chips.texts == ["3"] && !entry.chips.isShown(.needs),
            "a chip at zero is hidden: \(entry.chips.texts)")
        entry.apply(.quiet)
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 1, working: 3), running: 5, rows: []))
        try note(entry.glow.sweeps == 1, "the sweep is once ever, not once per busy spell")

        tailscode_set_animations_enabled(0)
        pump(0.2)
        try note(
            !entry.orb.isTurning && !entry.glow.isTurning,
            "a desk that asks for less movement stops the orb and the glow")
        let popsBefore = entry.chips.pops
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 2, working: 9), running: 12, rows: []))
        try note(
            entry.chips.pops == popsBefore && !entry.chips.isPopping,
            "and a count that changes does not pop")

        let still = ShimmerFlag()
        let calm = AgentsSidebarEntry(memory: still.memory) {}
        let calmWindow = gtk_window_new()!
        gtk_window_set_child(ptr(calmWindow), calm.widget)
        gtk_window_present(ptr(calmWindow))
        defer { gtk_window_destroy(ptr(calmWindow)) }
        pump(0.3)
        calm.apply(AgentsReading(chip: AgentsChip(needsYou: 1, working: 2), running: 3, rows: []))
        pump(0.2)
        try note(
            calm.glow.sweeps == 0 && !still.value && !calm.glow.isTurning && !calm.orb.isTurning,
            "reduced motion plays no sweep and spends nothing of its one chance")
        return claims
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
        guard let column = host.sidebarColumn, let entry = host.agentsEntry, let section = host.agentsNow,
            let pill = host.agentsPill
        else { throw SelfTestFailure("entry: the sidebar has no Agents card, rows or pill") }

        try note(
            gtk_widget_get_first_child(column) == entry.widget
                && gtk_widget_get_next_sibling(entry.widget) == section.widget,
            "the card is the top of the sidebar and the rows follow it")
        try note(
            gtk_widget_get_parent(pill.widget) == column,
            "the pill lives in the sidebar's foot")
        try note(
            gtk_widget_get_tooltip_text(entry.button).map { String(cString: $0) }
                == "What every agent is doing · Ctrl+Shift+A",
            "the tooltip names the shortcut")
        try note(!section.isShown, "the rows are collapsed while nothing runs")

        host.refreshAgentsEntry()
        pump(0.4)
        try note(
            entry.chips.texts == ["2", "1"] && entry.mood == .needs
                && entry.spokenName == "Agents, 2 working, 1 needs you",
            "demo mode shows the card alive: \(entry.chips.texts) \(entry.spokenName)")
        try note(
            section.isShown && section.shownButtons.map(\.titleText)
                == ["CI migration", "Fix reconnect test", "Landing page refresh"],
            "the rows list the demo, what needs you first: \(section.shownButtons.map(\.titleText))")
        try note(
            section.shownButtons.first.map { gtk_widget_has_css_class($0.widget, "agents-now-needs") != 0 } == true
                && section.shownButtons.dropFirst().allSatisfy { gtk_widget_has_css_class($0.widget, "agents-now-needs") == 0 },
            "and only that one is amber")
        try note(
            section.shownButtons.allSatisfy { !$0.wordsText.isEmpty }
                && section.shownButtons.dropFirst().first.map { !$0.elapsedText.isEmpty } == true,
            "each row has its words, and a working one its clock")
        try note(pill.shownText == Localized.text("%d needs you", 1) && pill.mood == .needs, "the pill is amber: \(pill.shownText)")
        try note(entry.glow.sweeps == 1, "the sidebar played its sweep when something first ran")

        tailscode_emit_clicked(entry.button)
        pump(0.6)
        try note(AgentsWindow.current != nil, "one press on the card opens the board")
        AgentsWindow.close()
        pump(0.4)
        try note(AgentsWindow.current == nil, "and the board closes again")

        let target = reading.rows[0].key
        if let first = section.shownButtons.first { tailscode_emit_clicked(first.widget) }
        pump(0.7)
        try note(
            AgentsWindow.current?.selectedKey == target,
            "a press on a row opens the board on that chat's peek: \(String(describing: AgentsWindow.current?.selectedKey))")
        AgentsWindow.close()
        pump(0.4)
        tailscode_emit_clicked(pill.widget)
        pump(0.6)
        try note(AgentsWindow.current != nil, "a press on the pill opens the board")
        AgentsWindow.close()
        pump(0.4)

        claims += try checkAgentsNarrow(host: host, pane: pane, window: window, expect: expect, pump: pump)
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
        guard let column = host.sidebarColumn, let entry = host.agentsEntry, let section = host.agentsNow else {
            throw SelfTestFailure("entry: no sidebar to narrow")
        }
        let long = String(repeating: "A chat title that goes on far past any sidebar ", count: 5)
        host.agentsNow?.apply(
            (0..<4).map {
                AgentsOnNowRow(
                    key: "k\($0)", title: long, words: long, since: Date().addingTimeInterval(-3725),
                    needsYou: $0 == 0)
            })
        entry.apply(AgentsReading(chip: AgentsChip(needsYou: 12, working: 345), running: 357, rows: []))
        gtk_window_set_default_size(ptr(window), Self.agentsNarrowWidth, 900)
        pump(0.6)
        let width = Double(gtk_widget_get_width(column))
        guard let card = Gtk.bounds(of: entry.button, in: column),
            let chips = Gtk.bounds(of: entry.chips.widget, in: column),
            let title = Gtk.bounds(of: entry.titleLabelWidget, in: column)
        else { throw SelfTestFailure("entry: the narrow card has no geometry") }
        try note(
            card.x >= 0 && card.x + card.width <= width + 1,
            "at \(Int(width)) wide the card stays inside the sidebar: \(card.x)+\(card.width)")
        try note(
            chips.x + chips.width <= card.x + card.width + 1 && chips.x >= title.x + title.width - 1,
            "the chips sit inside the card and clear of the word: chips \(chips.x)+\(chips.width), title \(title.x)+\(title.width)")
        try note(
            entry.chips.texts == ["345", "12"],
            "three digits keep all their digits: \(entry.chips.texts)")
        for button in section.shownButtons {
            guard let box = Gtk.bounds(of: button.widget, in: column),
                let name = Gtk.bounds(of: button.titleLabel, in: column),
                let clock = Gtk.bounds(of: button.elapsedLabel, in: column)
            else { throw SelfTestFailure("entry: a long row has no geometry") }
            try note(
                box.x + box.width <= width + 1 && name.x + name.width <= clock.x + 1
                    && gtk_label_get_lines(op(button.titleLabel)) <= 1,
                "a title two hundred characters long is one line inside the column: \(box.width)")
        }
        entry.apply(.quiet)
        entry.fit(sidebarWidth: 190)
        try note(!entry.isHintShown, "an idle card at the narrowest sidebar leaves the shortcut out whole")
        entry.fit(sidebarWidth: 320)
        try note(entry.isHintShown, "and shows it when it has the room")
        return claims
    }

    static let agentsNarrowWidth: Int32 = 200
}
