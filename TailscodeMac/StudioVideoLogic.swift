import Foundation
import TailscodeCore

/// A clip's length as a clip says it: minutes and two-digit seconds, the way a player does.
enum StudioClipTime {
    static func badge(seconds: Int) -> String {
        let whole = max(0, seconds)
        return "\(whole / 60):" + (whole % 60 < 10 ? "0" : "") + "\(whole % 60)"
    }
}

/// A name to offer a save panel or a drag for a clip: its words made into a filename, so a folder of
/// these reads as what they are, with the extension the machine wrote.
enum StudioClipName {
    static func fileName(for entry: ForgeEntry) -> String {
        let ext = entry.asset.map { ($0.filename as NSString).pathExtension } ?? ""
        let allowed = entry.recipe.prompt.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let squashed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        return "\(squashed.isEmpty ? "clip" : squashed).\(ext.isEmpty ? "mp4" : ext)"
    }
}

/// The Video lane's shelf: what this device has receipts for, newest first, the render in flight
/// leading as a tile that wears the sketch. A clip the renderer no longer has — and a render that
/// never produced one — keeps its tile, marked, because a shelf that dropped what it could not play
/// would lose the words and the settings that are still worth reusing.
enum StudioClipShelf {
    struct Job: Equatable, Sendable {
        let words: String
        let startedAt: Date?
    }

    static func merge(job: Job?, history: [ForgeEntry], missing: Set<String>) -> [StudioShelfItem] {
        var items: [StudioShelfItem] = []
        if let job {
            items.append(
                StudioShelfItem(
                    id: StudioShelfMerge.jobID, words: job.words, kind: .clip, isJob: true,
                    madeAt: job.startedAt))
        }
        var seen: Set<String> = []
        let newestFirst = history.enumerated().sorted {
            $0.element.finishedAt == $1.element.finishedAt
                ? $0.offset < $1.offset : $0.element.finishedAt > $1.element.finishedAt
        }.map(\.element)
        for entry in newestFirst {
            guard seen.insert(entry.id).inserted else { continue }
            items.append(
                StudioShelfItem(
                    id: entry.id, words: entry.recipe.prompt, kind: .clip, madeAt: entry.finishedAt,
                    badge: entry.isPlayable ? StudioClipTime.badge(seconds: entry.recipe.seconds) : nil,
                    isMissing: !entry.isPlayable || missing.contains(entry.id)))
        }
        return items
    }
}

/// What a clip on the stage can be played from, as far as anybody has found out.
enum StudioClipSource: Equatable, Sendable {
    case playable
    case unavailable(String)
}

/// What the Video stage is saying, decided once from the job and what is held so the stage, the
/// verbs, the dock and the shelf can never disagree about it. Every sentence is `ForgeJob`'s.
enum StudioVideoState: Equatable, Sendable {
    case empty
    case drafting
    case waiting(String)
    case working(String)
    case painting(String)
    case finishing(String)
    case done
    case failed(String, StudioRemedy)
    case stopped

    var isWorking: Bool {
        switch self {
        case .waiting, .working, .painting, .finishing: return true
        default: return false
        }
    }

    var showsClip: Bool { self == .done }

    /// The job's phase, read as the table of states the design names. A render out outranks any clip
    /// held on the stage; once it ends, the clip that was chosen — or the one the render made — is
    /// what the stage holds, and a clip that cannot be played says why in the failure tone.
    static func read(
        job: ForgeJob, clip: StudioClipSource?, hasStart: Bool, hasWords: Bool, remedy: StudioRemedy
    ) -> StudioVideoState {
        switch job.phase {
        case .submitting, .queued:
            return .waiting(job.subtitle)
        case .running(let fraction):
            if fraction >= 1 { return .finishing(job.subtitle) }
            if job.samplerSteps > 0 { return .painting(job.detail) }
            return .working(job.stageName ?? job.subtitle)
        case .failed(let reason):
            return .failed(reason, remedy)
        case .cancelled:
            return .stopped
        case .drafting, .done:
            switch clip {
            case .playable?: return .done
            case .unavailable(let sentence)?: return .failed(sentence, .reuse)
            case nil: return hasStart || hasWords ? .drafting : .empty
            }
        }
    }
}

/// The verbs a stage offers for the clip it holds. Play and Pause lead because a clip is first
/// something to watch; Continue it is the primary one, because the next clip is what a person
/// wants after one that was nearly right. While a render is out the capsule keeps its room.
enum StudioVideoVerbs {
    static func offered(
        state: StudioVideoState, hasWords: Bool, playing: Bool, isHistory: Bool
    ) -> [StudioStageVerb] {
        guard state.showsClip else { return [] }
        var verbs: [StudioStageVerb] = [
            StudioStageVerb(
                id: "play", title: playing ? Localized.text("Pause") : Localized.text("Play"),
                hint: Localized.text("Play the clip, or pause it"), symbol: playing ? "pause.fill" : "play.fill"),
            StudioStageVerb(
                id: "save", title: ImageGenAction.save.title,
                hint: Localized.text("Write the clip somewhere of your own"),
                symbol: ImageGenAction.save.symbol),
            StudioStageVerb(
                id: "share", title: ImageGenAction.share.title,
                hint: Localized.text("Hand the clip to another app or person"),
                symbol: ImageGenAction.share.symbol),
            StudioStageVerb(
                id: "copy", title: ImageGenAction.copy.title,
                hint: Localized.text("Put the clip on the clipboard"), symbol: ImageGenAction.copy.symbol),
            StudioStageVerb(
                id: "open", title: ImageGenAction.open.title, hint: ImageGenAction.open.hint,
                symbol: ImageGenAction.open.symbol),
        ]
        if hasWords { verbs.append(StudioStageVerb(ImageGenAction.again)) }
        verbs.append(
            StudioStageVerb(
                id: "continue", title: ForgeWords.extendTitle, hint: ForgeWords.extendHint,
                symbol: "forward.end.fill"))
        if isHistory { verbs.append(StudioStageVerb(ImageGenAction.discard)) }
        return verbs
    }

    static let primaryID = "continue"
}

/// The decisions that apply to the next clip, in Core's order, worn as the dock's pills: size,
/// length and smoothness are walked from a list, sound and avoid are words, and the seed is the one
/// that rolls. Every value is the board's own reading, so a Mac cannot spell a frame rate
/// differently from a phone.
enum StudioVideoChips {
    static func read(board: ForgeBoard) -> [StudioChip] {
        var chips: [StudioChip] = []
        for field in [ForgeField.size, .seconds, .fps] {
            chips.append(
                StudioChip(
                    kind: .forge(field), label: field.label, value: board.value(of: field),
                    symbol: field.symbol, isOn: false, isWarning: false, isLabelled: true))
        }
        let heard = board.recipe.sound.trimmingCharacters(in: .whitespacesAndNewlines)
        chips.append(
            StudioChip(
                kind: .sound, label: ForgeField.sound.label,
                value: heard.isEmpty ? Localized.text("Auto") : heard.ellipsized(to: 18),
                symbol: ForgeField.sound.symbol, isOn: !heard.isEmpty, isWarning: false,
                isLabelled: true))
        let avoided = board.recipe.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        chips.append(
            StudioChip(
                kind: .avoid, label: ForgeField.negative.label,
                value: avoided.isEmpty ? "" : avoided.ellipsized(to: 18),
                symbol: ForgeField.negative.symbol, isOn: !avoided.isEmpty, isWarning: false,
                isLabelled: true))
        chips.append(
            StudioChip(
                kind: .forge(.seed), label: ForgeField.seed.label, value: board.value(of: .seed),
                symbol: ForgeField.seed.symbol, isOn: false, isWarning: false, isLabelled: true))
        return chips
    }

    /// The line at the dock's foot: what this clip should cost, in the machine's own measure, and the
    /// shape it is asked at. Until a clip on the same model has been timed it says only where the
    /// work happens.
    static func estimate(board: ForgeBoard) -> String {
        guard let seconds = board.clock.estimate(board.recipe) else { return ForgeBoard.notice }
        return Localized.text(
            "%@ at %@ · %@ s", ForgeClock.aboutLine(seconds), board.recipe.size.label,
            "\(board.recipe.seconds)")
    }
}

/// The line along the stage's foot: one segment per pass the graph samples in, each filled by its
/// own sampler's count, or a single bar from the job's fraction when the passes are not yet known.
/// Nothing until there is something true to draw — a bar sitting at zero claims a start that has
/// not happened.
enum StudioProgressLine {
    struct Segment: Equatable, Sendable {
        let name: String?
        let fraction: Double
    }

    static func segments(job: ForgeJob) -> [Segment] {
        guard job.isBusy else { return [] }
        if let passes = job.passSegments {
            return passes.map { Segment(name: $0.name, fraction: $0.fraction) }
        }
        if let fraction = job.fraction, fraction >= 0.005 {
            return [Segment(name: nil, fraction: fraction)]
        }
        return []
    }

    /// Where each segment's filled part ends inside a line of `width`, with `gap` between segments.
    static func filled(_ segments: [Segment], width: Double, gap: Double) -> [(origin: Double, length: Double, filled: Double)] {
        guard !segments.isEmpty, width > 0 else { return [] }
        let room = max(0, width - gap * Double(segments.count - 1))
        let each = room / Double(segments.count)
        return segments.enumerated().map { index, segment in
            let origin = Double(index) * (each + gap)
            return (origin, each, each * min(1, max(0, segment.fraction)))
        }
    }
}

/// What changed in the forge since the last look, so the stage redraws only that: a sketch is one
/// layer's contents, a step is one line and one bar, and a render that rebuilt the shelf for either
/// would spend itself on layout. The words a person is typing are in none of these — they are the
/// box's own.
struct StudioVideoReading: Equatable {
    struct Shape: Equatable {
        var phase: String
        var ahead: Int
        var stageName: String?
        var recipe: ForgeRecipe
        var endpoint: ForgeEndpoint?
        var machine: StudioMachineReading?
        var history: [String]
        var missing: Set<String>
        var asset: ForgeAsset?
    }

    var shape: Shape
    var fraction: Double?
    var step: Int
    var steps: Int
    var sketch: Bool

    init(board: ForgeBoard, missing: Set<String>) {
        let job = board.job
        let phase: String
        var ahead = 0
        switch job.phase {
        case .drafting: phase = "drafting"
        case .submitting: phase = "submitting"
        case .queued(let count):
            phase = "queued"
            ahead = count
        case .running: phase = "running"
        case .done: phase = "done"
        case .failed(let reason): phase = "failed:" + reason
        case .cancelled: phase = "cancelled"
        }
        shape = Shape(
            phase: phase, ahead: ahead, stageName: job.stageName,
            recipe: board.recipe.with(prompt: ""), endpoint: board.endpoint,
            machine: StudioMachineReading.forge(board), history: board.history.map(\.id),
            missing: missing, asset: job.asset)
        fraction = job.fraction
        step = job.samplerStep
        steps = job.samplerSteps
        sketch = job.sketch != nil
    }

    /// What a surface owes the change from `old` to this: nothing when only the words moved.
    func change(from old: StudioVideoReading, sketchMoved: Bool) -> StudioLaneChange? {
        if shape != old.shape { return .everything }
        if fraction != old.fraction || step != old.step || steps != old.steps { return .progress }
        if sketchMoved || sketch != old.sketch { return .sketch }
        return nil
    }
}

/// Where a clip's first frame comes from when a picture is put on the Start-from slot, and what the
/// board then does with the size: a picture on this Mac is read for its shape, one the machine
/// keeps carries the shape it was listed with, and the end of a clip takes that clip's own. The
/// rule itself is Core's (`ForgeBoard.start`); this names the Mac's three doors into it.
enum StudioStartFrom {
    /// The shape of a picture file, read from its header, so the clip's size can follow it before
    /// anything is decoded.
    static func pixels(ofFileAt path: String) -> (width: Int, height: Int)? {
        StudioDrop.pixelSize(ofFileAt: path)
    }
}
