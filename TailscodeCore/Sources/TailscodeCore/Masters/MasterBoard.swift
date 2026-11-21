import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// One master as a list shows it, with the machine that keeps it.
public struct MasterRow: Sendable, Hashable, Identifiable {
    public let profileID: String
    public let machine: String
    public let master: MachineExpert

    public init(profileID: String, machine: String, master: MachineExpert) {
        self.profileID = profileID
        self.machine = machine
        self.master = master
    }

    public var id: String { "\(profileID)·\(master.id)" }
    public var hue: MasterHue { MasterHue(master.hue) }

    public func state(calendar: Calendar = .current, now: Date = Date()) -> MasterLine {
        MasterReading.state(master, calendar: calendar, now: now)
    }
}

/// Every machine's masters as one shelf: machines in the order the person keeps them, each
/// machine's masters in the order they were made, so a row never moves because its state did.
public struct MasterBoard: Sendable, Hashable {
    public struct Source: Sendable {
        public let profileID: String
        public let machine: String
        public let masters: [MachineExpert]

        public init(profileID: String, machine: String, masters: [MachineExpert]) {
            self.profileID = profileID
            self.machine = machine
            self.masters = masters
        }
    }

    public let rows: [MasterRow]
    /// The machines that answered and keep masters, in order, so a client knows where a new
    /// master can be made even before there is one.
    public let machines: [(profileID: String, machine: String)]
    /// Machines that keep masters but did not answer this time: offline, or out of reach. They
    /// are not machines that cannot keep masters.
    public let unanswered: [(profileID: String, machine: String)]

    public init(
        rows: [MasterRow], machines: [(profileID: String, machine: String)] = [],
        unanswered: [(profileID: String, machine: String)] = []
    ) {
        self.rows = rows
        self.machines = machines
        self.unanswered = unanswered
    }

    public static let empty = MasterBoard(rows: [])

    /// What a beta report says about masters: how many there are and what state they are in, by
    /// count, and never a name, a charter or a note the person wrote.
    public var betaReportLines: [String] {
        var lines = [
            "Machines keeping masters: \(machines.count)",
            "Masters: \(rows.count)",
            "Tasks running: \(rows.filter { $0.master.task != nil }.count)",
            "Notes waiting: \(rows.reduce(0) { $0 + $1.master.pending })",
            "Guards failing: \(rows.reduce(0) { $0 + $1.master.failingGuards.count })",
        ]
        if !unanswered.isEmpty { lines.append("Machines not answering: \(unanswered.count)") }
        return lines
    }

    public var isEmpty: Bool { rows.isEmpty }
    /// Whether any machine keeps masters, answering now or not.
    public var keepsExperts: Bool { !machines.isEmpty || !unanswered.isEmpty }

    public static func make(
        _ sources: [Source], unanswered: [(profileID: String, machine: String)] = []
    ) -> MasterBoard {
        let rows = sources.flatMap { source in
            source.masters.sorted { $0.createdAt < $1.createdAt }
                .map { MasterRow(profileID: source.profileID, machine: source.machine, master: $0) }
        }
        return MasterBoard(rows: rows, machines: sources.map { ($0.profileID, $0.machine) }, unanswered: unanswered)
    }

    public func row(profileID: String, expertID: String) -> MasterRow? {
        rows.first { $0.profileID == profileID && $0.master.id == expertID }
    }

    /// The master a conversation is a task of.
    public func master(for session: AgentSession, profileID: String) -> MasterRow? {
        guard let id = session.expertID else { return nil }
        return row(profileID: profileID, expertID: id)
    }

    /// Notes waiting for the person across every master.
    public var pending: Int { rows.reduce(0) { $0 + $1.master.pending } }

    /// The masters every machine that keeps them keeps, read together. A machine that does not
    /// answer is left out rather than shown empty.
    public static func load(_ servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)]) async
        -> MasterBoard
    {
        enum Answer: Sendable {
            case kept(Source)
            case silent(profileID: String, machine: String)
            case none
        }
        let answers = await withTaskGroup(of: (Int, Answer).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    guard let keeping = server.backend as? any MachineExperts else { return (index, .none) }
                    do {
                        guard let masters = try await keeping.machineExperts() else { return (index, .none) }
                        return (index, .kept(Source(profileID: server.profile.id, machine: server.profile.name, masters: masters)))
                    } catch {
                        guard server.backend.capabilities.supportsExperts else { return (index, .none) }
                        return (index, .silent(profileID: server.profile.id, machine: server.profile.name))
                    }
                }
            }
            var found: [(Int, Answer)] = []
            for await answer in group { found.append(answer) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var sources: [Source] = []
        var unanswered: [(profileID: String, machine: String)] = []
        for answer in answers {
            switch answer {
            case .kept(let source): sources.append(source)
            case .silent(let profileID, let machine): unanswered.append((profileID, machine))
            case .none: break
            }
        }
        return make(sources, unanswered: unanswered)
    }

    public static func == (lhs: MasterBoard, rhs: MasterBoard) -> Bool {
        lhs.rows == rhs.rows && lhs.machines.map(\.profileID) == rhs.machines.map(\.profileID)
            && lhs.unanswered.map(\.profileID) == rhs.unanswered.map(\.profileID)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rows)
        hasher.combine(machines.map(\.profileID))
        hasher.combine(unanswered.map(\.profileID))
    }
}

/// A master's colour, the same on three clients: a pair of sRGB values for dark and light.
public enum MasterHue: String, Sendable, CaseIterable, Hashable {
    case blue, orange, green, purple, pink, teal, indigo, red, yellow, gray

    public init(_ raw: String) { self = MasterHue(rawValue: raw) ?? .blue }

    /// 0xRRGGBB for a dark and a light appearance.
    public var rgb: (dark: UInt32, light: UInt32) {
        switch self {
        case .blue: return (0x5E9CFF, 0x2F74E8)
        case .orange: return (0xFF9F5A, 0xD9692A)
        case .green: return (0x30D158, 0x1FA840)
        case .purple: return (0xBF5AF2, 0x9A3FD6)
        case .pink: return (0xFF6BB5, 0xD6006F)
        case .teal: return (0x40C8E0, 0x0E8FA8)
        case .indigo: return (0x7D7AFF, 0x5452D6)
        case .red: return (0xFF6961, 0xD70015)
        case .yellow: return (0xFFD60A, 0xB38600)
        case .gray: return (0x8E8E93, 0x6E6E73)
        }
    }

    /// The glyph is drawn on the hue; yellow is light enough to want dark letters.
    public var wantsDarkGlyph: Bool { self == .yellow }

    /// The colour's name as a person says it, for a picker and for VoiceOver.
    public var name: String {
        switch self {
        case .blue: return Localized.text("Blue")
        case .orange: return Localized.text("Orange")
        case .green: return Localized.text("Green")
        case .purple: return Localized.text("Purple")
        case .pink: return Localized.text("Pink")
        case .teal: return Localized.text("Teal")
        case .indigo: return Localized.text("Indigo")
        case .red: return Localized.text("Red")
        case .yellow: return Localized.text("Yellow")
        case .gray: return Localized.text("Grey")
        }
    }
}

/// The machines a person could make a master on, and the drafts that start one.
public enum MasterMaking {
    /// A glyph the way the machine makes one: the first two letters or digits, the first upper case.
    public static func glyph(for name: String) -> String {
        let letters = name.filter { $0.isLetter || $0.isNumber }
        guard let first = letters.first else { return "Ex" }
        let second = letters.dropFirst().first.map { String($0).lowercased() } ?? ""
        return String(first).uppercased() + second
    }

    /// The draft as it will be sent: the notes the person left ticked, nothing else.
    public static func finalized(_ draft: ExpertDraft, keeping ticked: Set<String>) -> ExpertDraft {
        var final = draft
        final.notes = draft.notes?.filter { ticked.contains($0.title) }.map {
            var note = $0
            note.lasting = true
            return note
        }
        if final.glyph?.isEmpty ?? true { final.glyph = glyph(for: draft.name) }
        return final
    }

    /// The first words of a task handed a failing guard, the same on every client: which guard,
    /// on which machine, its command, the end of its last output, and what to do.
    public static func failureTask(_ item: ExpertGuard, machine: String) -> String {
        var text = Localized.text("The guard “%@” started failing on %@.", item.name, machine)
        text += "\n\n" + Localized.text("Its command: `%@`", item.command)
        if let output = item.last?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
            text += "\n\n" + Localized.text("Its last output:") + "\n\n```\n" + tail + "\n```"
        }
        text += "\n\n" + Localized.text("Find out why and fix it, then run the guard again.")
        return text
    }

    /// The notes a draft offers ticked: every lasting one.
    public static func defaultTicks(_ draft: ExpertDraft) -> Set<String> {
        Set((draft.notes ?? []).filter { $0.lasting != false }.map(\.title))
    }
}
