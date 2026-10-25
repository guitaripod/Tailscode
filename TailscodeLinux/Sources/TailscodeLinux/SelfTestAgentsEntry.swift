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

extension String {
    var spaced: String {
        replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\n", with: " · ")
    }
}

extension SelfTest {
    static func agentsReading(
        working: Int = 0, needs: Int = 0, agents: Int = 0, background: Int = 0, waiting: String? = nil
    ) -> AgentsReading {
        AgentsReading(
            working: working, needsYou: needs, agents: agents, background: background, waiting: waiting)
    }

    static func listRow(
        _ id: String, active: Bool, agents: Int? = nil, work: BackgroundWork? = nil
    ) -> SessionRowModel {
        var session = AgentSession(
            id: id, agentType: .claudeCode, title: "Chat " + id, createdAt: Date(), updatedAt: Date(),
            isActive: active)
        session.activeAgents = agents
        session.backgroundWork = work
        let entry = SessionEntry(
            profileID: AgentDemo.homelab, profileName: "homelab", host: "homelab",
            backendType: .claudeCode, session: session)
        return SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false)
    }

    /// The sidebar's Agents card: what it says over Core's demo fiction and over the chat list, the
    /// orbit that counts the running sessions, where it sits in the real sidebar, that a press on
    /// it and on a row's agents chip reaches the board, that nothing overlaps or runs past a narrow
    /// column, and that the movement is arithmetic the desk can switch off.
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
            reading.working == 2 && reading.needsYou == 1 && reading.mood == .needs
                && reading.waiting == "CI migration",
            "the demo reads 2 working and 1 needing you, and is amber: \(reading)")
        try note(
            reading.agents == 3 && reading.background == 1 && reading.running == 4,
            "three sub-agents, one background task, four running: \(reading.agents) \(reading.background) \(reading.running)")
        try note(
            reading.sentence(withShortcut: true) == "CI migration needs you",
            "a card with something waiting names the first chat that waits: \(reading.sentence(withShortcut: true))")
        try note(
            reading.spoken == "Agents, 2 working, 1 needs you, 3 agents, 1 in the background",
            "and a reader hears every count once: \(reading.spoken)")
        let busy = agentsReading(working: 3, agents: 2, background: 1)
        try note(
            busy.sentence(withShortcut: true).spaced == "3 working · 2 agents · 1 in the background",
            "a working card counts sessions, agents and background work: \(busy.sentence(withShortcut: true))")
        try note(
            agentsReading(working: 1, agents: 1).sentence(withShortcut: true).spaced == "1 working · 1 agent",
            "and says one agent in the singular")
        try note(
            AgentsReading.quiet.sentence(withShortcut: true) == "all quiet · Ctrl+Shift+A"
                && AgentsReading.quiet.sentence(withShortcut: false) == "all quiet"
                && AgentsReading.quiet.spoken == "Agents",
            "a quiet card says so and names the shortcut only when there is room")
        let listed = AgentsReading(list: [
            listRow("a", active: true, agents: 2), listRow("b", active: true, agents: 1),
            listRow("c", active: false, work: BackgroundWork(tasks: 1, task: "build", since: now)),
            listRow("d", active: false),
        ])
        try note(
            listed == agentsReading(working: 2, agents: 3, background: 1),
            "the chat list gives the same facts while the board is shut: \(listed)")
        claims += try checkAgentsFaces(expect: expect)
        let keys = ShortcutSet.build(overrides: [:])
        func opensBoard(_ keyval: UInt32, _ state: UInt32) -> Bool {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state),
                case .run(.toggleAgents) = keys.resolve(
                    chord, context: .normal, pending: [], awaitingApproval: false)
            else { return false }
            return true
        }
        try note(
            opensBoard(0x41, KeyChord.controlMask | KeyChord.shiftMask) && !opensBoard(0x61, 0),
            "Ctrl+Shift+A opens the board and a bare a is no binding of it")

        guard gtk_init_check() != 0 else { return claims }
        MatrixTheme.install()
        claims += try checkAgentsStillness(expect: expect)
        claims += try checkAgentsMotion(expect: expect, pump: pump)
        claims += try checkAgentsSidebar(reading: reading, expect: expect, pump: pump)
        return claims
    }

    private static func checkAgentsFaces(expect: (Bool, String) throws -> Void) throws -> Int {
        var claims = 0
        func note(_ condition: Bool, _ label: String) throws {
            try expect(condition, "entry: " + label)
            claims += 1
        }
        let faces = ["idle", "working", "needs", "background", "many", "long"].map { MainWindow.agentsFace($0) }
        try note(faces.allSatisfy { $0 != nil } && MainWindow.agentsFace("nothing") == nil, "every face is named")
        try note(
            faces[0]?.mood == .idle && faces[1]?.mood == .working && faces[1]?.agents == 3
                && faces[2]?.mood == .needs && faces[3]?.mood == .idle && faces[3]?.running == 2,
            "idle, working, needs and background-only read as themselves")
        try note(
            AgentsOrbit.shown(faces[4]?.running ?? 0) == AgentsOrbit.cap
                && AgentsOrbit.overflows(faces[4]?.running ?? 0),
            "many has more running sessions than the orbit has lights")
        try note(
            AgentsOrbit.period(.needs) < AgentsOrbit.period(.working)
                && AgentsOrbit.period(.working) < AgentsOrbit.period(.idle),
            "the orbit turns fastest when something needs you")
        return claims
    }

    private static func orbPixels(
        _ mood: AgentsMood, time: Double, animated: Bool, running: Int = 0, drawn: UnsafeMutablePointer<Int>? = nil
    ) -> [UInt8] {
        let side: Int32 = 34
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side)!
        let cr = cairo_create(surface)!
        let count = AgentsMiniOrb.paint(
            cr, size: Double(side), mood: mood, time: time, animated: animated, running: running)
        drawn?.pointee = count
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
                orbPixels(mood, time: 0, animated: false, running: 3)
                    == orbPixels(mood, time: 0.95, animated: false, running: 3),
                "\(mood) with reduced motion is the same picture at any time, orbit included")
            try note(
                orbPixels(mood, time: 0, animated: true, running: 3)
                    != orbPixels(mood, time: 0.4, animated: true, running: 3),
                "\(mood) moves when the desk allows it")
        }
        try note(
            orbPixels(.idle, time: 0, animated: true) == orbPixels(.idle, time: 9, animated: true),
            "an idle bead with nothing running is still whatever the desk allows")
        try note(
            orbPixels(.idle, time: 0, animated: true, running: 2)
                != orbPixels(.idle, time: 9, animated: true, running: 2),
            "and a quiet card with background work drifts its lights")
        try note(
            AgentsSwell.at(.needs, time: 3, animated: false) == AgentsSwell.at(.needs, time: 9, animated: false),
            "the swell is a constant under reduced motion")
        var drawn = 0
        for (running, lights) in [(0, 0), (1, 1), (3, 3), (5, 5), (6, 5), (40, 5)] {
            _ = orbPixels(.working, time: 1, animated: true, running: running, drawn: &drawn)
            try note(drawn == lights, "\(running) running sessions draw \(lights) lights: \(drawn)")
        }
        try note(
            orbPixels(.working, time: 0, animated: false, running: 5)
                != orbPixels(.working, time: 0, animated: false, running: 6),
            "a sixth session adds the plus mark")
        try note(
            orbPixels(.working, time: 0, animated: false, running: 6)
                == orbPixels(.working, time: 0, animated: false, running: 60),
            "and nothing more after it")
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
        entry.fit(sidebarWidth: 320)
        pump(0.4)

        try note(
            !entry.orb.isTurning && !entry.glow.isTurning && entry.sentenceText == "all quiet · Ctrl+Shift+A",
            "an idle card runs no clock and carries the shortcut: \(entry.sentenceText)")
        let waiting = "CI migration"
        entry.apply(agentsReading(working: 2, needs: 1, agents: 2, background: 0, waiting: waiting))
        pump(0.3)
        try note(
            entry.orb.isTurning && entry.glow.isTurning && entry.sentenceText == "CI migration needs you",
            "a busy card turns its orb and its glow and names who waits: \(entry.sentenceText)")
        try note(
            entry.chips.texts == ["2", "1"] && entry.spokenName == "Agents, 2 working, 1 needs you, 2 agents",
            "two chips with digits, and the name a reader hears: \(entry.chips.texts) \(entry.spokenName)")
        try note(entry.chips.pops == 2, "both counts popped when they appeared: \(entry.chips.pops)")
        try note(entry.glow.sweeps == 1 && flag.value, "the first thing to say plays the sweep once and remembers it")
        pump(0.4)
        entry.apply(agentsReading(working: 3, needs: 1, agents: 2, background: 1, waiting: waiting))
        try note(
            entry.chips.texts == ["3", "1", "1"] && entry.chips.pops == 4 && entry.chips.isPopping,
            "a changed count and a new chip pop alone: \(entry.chips.texts) \(entry.chips.pops)")
        pump(0.5)
        try note(!entry.chips.isPopping, "and the pop is over inside a quarter of a second")
        entry.apply(agentsReading(working: 3, needs: 0, agents: 2, background: 1))
        try note(
            entry.chips.texts == ["3", "1"] && !entry.chips.isShown(.needs)
                && entry.sentenceText.spaced == "3 working · 2 agents · 1 in the background",
            "a chip at zero is hidden and the sentence counts: \(entry.chips.texts) \(entry.sentenceText)")
        entry.apply(agentsReading(background: 2))
        pump(0.2)
        try note(
            entry.mood == .idle && entry.orb.isTurning && !entry.glow.isTurning
                && entry.sentenceText.spaced == "2 in the background",
            "background work alone keeps the face quiet and drifts the lights: \(entry.sentenceText)")
        entry.apply(.quiet)
        entry.apply(agentsReading(working: 3, needs: 1, agents: 2, background: 1, waiting: waiting))
        try note(entry.glow.sweeps == 1, "the sweep is once ever, not once per busy spell")

        tailscode_set_animations_enabled(0)
        pump(0.2)
        try note(
            !entry.orb.isTurning && !entry.glow.isTurning,
            "a desk that asks for less movement stops the orb and the glow")
        let popsBefore = entry.chips.pops
        entry.apply(agentsReading(working: 9, needs: 2, agents: 4, background: 1, waiting: waiting))
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
        calm.apply(agentsReading(working: 2, needs: 1, waiting: waiting))
        pump(0.2)
        try note(
            calm.glow.sweeps == 0 && !still.value && !calm.glow.isTurning && !calm.orb.isTurning,
            "reduced motion plays no sweep and spends nothing of its one chance")
        return claims
    }
}
