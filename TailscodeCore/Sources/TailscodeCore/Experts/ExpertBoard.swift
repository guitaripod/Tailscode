import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// One expert as a list shows it, with the machine that keeps it.
public struct ExpertRow: Sendable, Hashable, Identifiable {
    public let profileID: String
    public let machine: String
    public let expert: MachineExpert

    public init(profileID: String, machine: String, expert: MachineExpert) {
        self.profileID = profileID
        self.machine = machine
        self.expert = expert
    }

    public var id: String { "\(profileID)·\(expert.id)" }
    public var hue: ExpertHue { ExpertHue(expert.hue) }

    public func state(calendar: Calendar = .current, now: Date = Date()) -> ExpertLine {
        ExpertReading.state(expert, calendar: calendar, now: now)
    }
}

/// Every machine's experts as one shelf: machines in the order the person keeps them, each
/// machine's experts in the order they were made, so a row never moves because its state did.
public struct ExpertBoard: Sendable, Hashable {
    public struct Source: Sendable {
        public let profileID: String
        public let machine: String
        public let experts: [MachineExpert]

        public init(profileID: String, machine: String, experts: [MachineExpert]) {
            self.profileID = profileID
            self.machine = machine
            self.experts = experts
        }
    }

    public let rows: [ExpertRow]
    /// The machines that answered and keep experts, in order, so a client knows where a new
    /// expert can be made even before there is one.
    public let machines: [(profileID: String, machine: String)]
    /// Machines that keep experts but did not answer this time: offline, or out of reach. They
    /// are not machines that cannot keep experts.
    public let unanswered: [(profileID: String, machine: String)]

    public init(
        rows: [ExpertRow], machines: [(profileID: String, machine: String)] = [],
        unanswered: [(profileID: String, machine: String)] = []
    ) {
        self.rows = rows
        self.machines = machines
        self.unanswered = unanswered
    }

    public static let empty = ExpertBoard(rows: [])

    public var isEmpty: Bool { rows.isEmpty }
    /// Whether any machine keeps experts, answering now or not.
    public var keepsExperts: Bool { !machines.isEmpty || !unanswered.isEmpty }

    public static func make(
        _ sources: [Source], unanswered: [(profileID: String, machine: String)] = []
    ) -> ExpertBoard {
        let rows = sources.flatMap { source in
            source.experts.sorted { $0.createdAt < $1.createdAt }
                .map { ExpertRow(profileID: source.profileID, machine: source.machine, expert: $0) }
        }
        return ExpertBoard(rows: rows, machines: sources.map { ($0.profileID, $0.machine) }, unanswered: unanswered)
    }

    public func row(profileID: String, expertID: String) -> ExpertRow? {
        rows.first { $0.profileID == profileID && $0.expert.id == expertID }
    }

    /// The expert a conversation is a task of.
    public func expert(for session: AgentSession, profileID: String) -> ExpertRow? {
        guard let id = session.expertID else { return nil }
        return row(profileID: profileID, expertID: id)
    }

    /// Notes waiting for the person across every expert.
    public var pending: Int { rows.reduce(0) { $0 + $1.expert.pending } }

    /// The experts every machine that keeps them keeps, read together. A machine that does not
    /// answer is left out rather than shown empty.
    public static func load(_ servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)]) async
        -> ExpertBoard
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
                        guard let experts = try await keeping.machineExperts() else { return (index, .none) }
                        return (index, .kept(Source(profileID: server.profile.id, machine: server.profile.name, experts: experts)))
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

    public static func == (lhs: ExpertBoard, rhs: ExpertBoard) -> Bool {
        lhs.rows == rhs.rows && lhs.machines.map(\.profileID) == rhs.machines.map(\.profileID)
            && lhs.unanswered.map(\.profileID) == rhs.unanswered.map(\.profileID)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rows)
        hasher.combine(machines.map(\.profileID))
        hasher.combine(unanswered.map(\.profileID))
    }
}

/// An expert's colour, the same on three clients: a pair of sRGB values for dark and light.
public enum ExpertHue: String, Sendable, CaseIterable, Hashable {
    case blue, orange, green, purple, pink, teal, indigo, red, yellow, gray

    public init(_ raw: String) { self = ExpertHue(rawValue: raw) ?? .blue }

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

/// The machines a person could make an expert on, and the drafts that start one.
public enum ExpertMaking {
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

    /// The notes a draft offers ticked: every lasting one.
    public static func defaultTicks(_ draft: ExpertDraft) -> Set<String> {
        Set((draft.notes ?? []).filter { $0.lasting != false }.map(\.title))
    }
}
