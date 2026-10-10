import Foundation

/// One of the two passes the video graph samples in, drawn as one segment of the line along the
/// stage's edge.
public struct ForgePassSegment: Sendable, Equatable {
    public let name: String
    public let fraction: Double
    public let isCurrent: Bool

    public init(name: String, fraction: Double, isCurrent: Bool) {
        self.name = name
        self.fraction = fraction
        self.isCurrent = isCurrent
    }
}

extension ForgeJob {
    /// The render read pass by pass, for a line that is two segments rather than one bar.
    ///
    /// The graph samples twice — the first pass at half the asked-for size, the second after the
    /// latent upsampler doubled it back — and the sampler's own step counter restarts between them,
    /// which is exactly why a single bar over that counter would fill, empty and fill again. Each
    /// segment is therefore filled by the sampler's step *within its own pass*, a pass that is over
    /// is full, and a pass not yet begun is empty. Nil until the first pass has said a step: before
    /// that the machine is loading or reading, and a line sitting at zero would claim a start that
    /// has not happened.
    public var passSegments: [ForgePassSegment]? {
        guard case .running(let overall) = phase, overall < 1,
            let running = census?.running
        else { return nil }
        let first = Localized.text("First pass")
        let second = Localized.text("Second pass")
        let within = samplerSteps > 0
            ? min(1, max(0, Double(samplerStep) / Double(samplerSteps))) : 0
        switch running {
        case "pass1":
            guard samplerSteps > 0 else { return nil }
            return [
                ForgePassSegment(name: first, fraction: within, isCurrent: true),
                ForgePassSegment(name: second, fraction: 0, isCurrent: false),
            ]
        case "up", "start2", "sig2":
            return [
                ForgePassSegment(name: first, fraction: 1, isCurrent: false),
                ForgePassSegment(name: second, fraction: 0, isCurrent: false),
            ]
        case "pass2":
            return [
                ForgePassSegment(name: first, fraction: 1, isCurrent: false),
                ForgePassSegment(name: second, fraction: within, isCurrent: true),
            ]
        case "pixels", "audio", "video", "save":
            return [
                ForgePassSegment(name: first, fraction: 1, isCurrent: false),
                ForgePassSegment(name: second, fraction: 1, isCurrent: false),
            ]
        default:
            return nil
        }
    }
}

/// The machine, as the one pill in a studio's bar says it: whose it is, the single most useful fact
/// about it, and the tone that fact is worn in. A client decides how a pill is drawn and nothing
/// else — in particular it never writes the fact itself, so the phone, the desk and the Mac cannot
/// describe the same machine in three ways.
public struct StudioMachineReading: Sendable, Equatable {
    public let name: String
    public let fact: String
    public let tone: ActivityTone
    /// Whether the machine, as last seen, cannot paint at all. The pill goes to the failure tone
    /// for this and for nothing weaker.
    public let cannotPaint: Bool

    public init(name: String, fact: String, tone: ActivityTone, cannotPaint: Bool) {
        self.name = name
        self.fact = fact
        self.tone = tone
        self.cannotPaint = cannotPaint
    }

    /// What a screen reader is told the pill is.
    public var spoken: String { "\(name), \(fact)" }

    /// The image studio's machine, from what the door last learned about it, said in the short
    /// sentence the machine sheet leads with — the door's own line is a paragraph and a pill is one
    /// line. A machine nobody has looked at is said to be unchecked rather than described.
    public static func image(_ door: ImageGenDoor) -> StudioMachineReading? {
        guard let endpoint = door.endpoint else { return nil }
        let name = endpoint.shortName
        guard let sighting = door.currentSighting else {
            return StudioMachineReading(
                name: name, fact: ImageGenMachineWords.neverChecked, tone: .quiet,
                cannotPaint: false)
        }
        let ready = sighting.readyEngines
        let cannot = !sighting.reachable || ready.isEmpty
        let tone: ActivityTone
        if cannot {
            tone = .danger
        } else if sighting.ready {
            tone = .live
        } else {
            tone = .attention
        }
        let fact: String
        if !sighting.reachable {
            fact = Localized.text("Not answering")
        } else if ready.count == ImageGenEngine.allCases.count {
            fact = Localized.text("Ready")
        } else if ready.isEmpty {
            fact = Localized.text("No engine ready")
        } else {
            fact = Localized.text("%@ only", ready.map(\.label).joined(separator: ", "))
        }
        return StudioMachineReading(name: name, fact: fact, tone: tone, cannotPaint: cannot)
    }

    /// The video forge's machine, from the renderer row the board already writes.
    public static func forge(_ board: ForgeBoard) -> StudioMachineReading? {
        guard board.endpoint != nil,
            let row = board.rows.first(where: { $0.kind == .field(.endpoint) })
        else { return nil }
        let phase = board.sections.first(where: { $0.id == ForgeBoard.rendererID })?.phase
        let tone: ActivityTone
        switch phase {
        case .failed: tone = .danger
        case .ready: tone = .live
        case .checking, .idle, nil: tone = .quiet
        }
        var failed = false
        if case .failed = phase { failed = true }
        return StudioMachineReading(
            name: row.title, fact: row.detail, tone: tone, cannotPaint: failed)
    }
}

/// What a stage announces when its picture or clip lands.
public enum StudioStageWords {
    /// What a screen reader is told a finished picture is announced as, once, politely.
    public static func landed(words: String?) -> String {
        guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Localized.text("Picture ready")
        }
        return Localized.text("Picture ready: %@", words.ellipsized(to: 80))
    }

    /// The same for a clip.
    public static func clipLanded(words: String?) -> String {
        guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Localized.text("Clip ready")
        }
        return Localized.text("Clip ready: %@", words.ellipsized(to: 80))
    }
}
