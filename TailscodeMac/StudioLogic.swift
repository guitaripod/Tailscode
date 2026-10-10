import Foundation
import TailscodeCore

/// One tile on the shelf: a job in flight, a picture made this session, or one the machine kept.
/// The shelf is one list whichever lane it is in — pictures and clips differ only in the poster a
/// tile draws and the badge it wears — so a lane contributes these and the shell draws them.
struct StudioShelfItem: Equatable, Sendable, Identifiable {
    enum Kind: Sendable {
        case picture
        case clip
    }

    let id: String
    let words: String
    let kind: Kind
    let isJob: Bool
    let madeAt: Date?
    let bytes: Int?

    init(
        id: String, words: String, kind: Kind = .picture, isJob: Bool = false, madeAt: Date? = nil,
        bytes: Int? = nil
    ) {
        self.id = id
        self.words = words
        self.kind = kind
        self.isJob = isJob
        self.madeAt = madeAt
        self.bytes = bytes
    }
}

/// How the machine's folder and this session's own pictures become one shelf. A picture made here is
/// the newest thing in the machine's folder the moment it lands, so the two lists describe one set
/// of files: a session picture whose name the listing carries takes that tile's place, wearing the
/// words and seconds this Mac remembers, and one the listing has not caught up with yet leads, so
/// the picture just made is on the shelf before the machine has said so.
enum StudioShelfMerge {
    struct Job: Equatable, Sendable {
        let words: String
        let startedAt: Date?
    }

    /// The job in flight leads, then what this session made that the listing does not hold, then the
    /// machine's own order — newest first throughout — with every name appearing exactly once.
    static func merge(
        job: Job?, session: [ImageGenPicture], machine: [ImageGenLibraryItem],
        facts: (ImageGenLibraryItem) -> ImageGenLibraryFacts? = { _ in nil }
    ) -> [StudioShelfItem] {
        var items: [StudioShelfItem] = []
        if let job {
            items.append(
                StudioShelfItem(
                    id: jobID, words: job.words, isJob: true, madeAt: job.startedAt))
        }
        let listed = Set(machine.map(\.id))
        var seen: Set<String> = []
        var byName: [String: ImageGenPicture] = [:]
        for picture in session {
            if let name = picture.remoteName, listed.contains(name) {
                byName[name] = byName[name] ?? picture
                continue
            }
            let id = picture.remoteName ?? picture.path
            guard seen.insert(id).inserted else { continue }
            items.append(
                StudioShelfItem(
                    id: id, words: picture.prompt, madeAt: picture.madeAt,
                    bytes: FileManager.default.fileSize(atPath: picture.path)))
        }
        for entry in machine {
            guard seen.insert(entry.id).inserted else { continue }
            if let made = byName[entry.id] {
                items.append(
                    StudioShelfItem(
                        id: entry.id, words: made.prompt, madeAt: made.madeAt,
                        bytes: facts(entry)?.bytes))
                continue
            }
            let known = facts(entry)
            items.append(
                StudioShelfItem(
                    id: entry.id, words: known?.recipe?.prompt ?? "", madeAt: known?.modifiedAt,
                    bytes: known?.bytes))
        }
        return items
    }

    /// The tile that stands for the render in flight. It is never a real file's name, so it can never
    /// collide with one.
    static let jobID = "studio.job"

    /// The tile after or before `id` in reading order, wrapping nowhere — the arrow keys stop at the
    /// ends of the shelf rather than lapping it — and skipping the job, which is not a picture a
    /// person can put on stage. Nothing selected walks in from the newest end.
    static func neighbour(of id: String?, step: Int, in items: [StudioShelfItem]) -> String? {
        let pictures = items.filter { !$0.isJob }
        guard !pictures.isEmpty else { return nil }
        guard let id, let index = pictures.firstIndex(where: { $0.id == id }) else {
            return step >= 0 ? pictures.first?.id : pictures.last?.id
        }
        let next = index + (step >= 0 ? 1 : -1)
        guard pictures.indices.contains(next) else { return pictures[index].id }
        return pictures[next].id
    }
}

extension FileManager {
    fileprivate func fileSize(atPath path: String) -> Int? {
        (try? attributesOfItem(atPath: path))?[.size] as? Int
    }
}

/// What the stage is saying, decided once from the slot and the machine's own socket so the stage,
/// the verbs, the dock and the shelf can never disagree about it. Every sentence is Core's.
enum StudioStageState: Equatable {
    case empty
    case drafting
    case waiting(String)
    case painting(step: Int?, steps: Int?)
    case finishing(String)
    case done
    case failed(String, StudioRemedy)
    case stopped

    /// Whether a render is out, which is when the dock says Stop and the words hold still.
    var isWorking: Bool {
        switch self {
        case .waiting, .painting, .finishing: return true
        default: return false
        }
    }

    /// Whether a finished picture is what the stage holds, which is when its verbs are offered.
    var showsPicture: Bool { self == .done }

    /// The slot's phase, read as the table of states the design names.
    static func read(
        slot: ImageGenSlot, progress: ImageGenProgress?, hasPicture: Bool, hasWords: Bool,
        remedy: StudioRemedy
    ) -> StudioStageState {
        switch slot.phase {
        case .painting:
            guard let progress else {
                return .waiting(slot.waitingLine(since: nil))
            }
            switch progress.stage {
            case .painting:
                return .painting(step: progress.step, steps: progress.steps)
            case .decoding, .saving:
                return .finishing(progress.line)
            default:
                return .waiting(progress.line)
            }
        case .failed(_, let reason):
            if reason == ImageGenWords.stoppedNotice { return .stopped }
            return .failed(reason, remedy)
        case .asking, .composing:
            if hasPicture { return .done }
            return slot.reference != nil || hasWords ? .drafting : .empty
        }
    }
}

/// The one thing a failure offers, chosen from what is known about the machine rather than from the
/// words of the failure: a stopped machine is woken by asking it, a machine that lacks one engine
/// is offered the other, one with nothing to paint with is the machine sheet's business, and
/// anything else is simply asked again.
enum StudioRemedy: Equatable {
    case retry
    case wake
    case useEngine(ImageGenEngine)
    case machine

    static func choose(sighting: ImageGenSighting?, engine: ImageGenEngine) -> StudioRemedy {
        guard let sighting else { return .retry }
        guard sighting.reachable else { return .wake }
        guard !sighting.available(engine) else { return .retry }
        if let other = sighting.readyEngines.first(where: { $0 != engine }) {
            return .useEngine(other)
        }
        return .machine
    }

    var title: String {
        switch self {
        case .retry: return Localized.text("Try again")
        case .wake: return Localized.text("Check again")
        case .useEngine(let engine): return Localized.text("Paint with %@", engine.label)
        case .machine: return ImageGenMachineWords.change
        }
    }
}

/// When the Studio gives up a piece of itself so the picture can keep its room. The numbers are the
/// design's own: a window under 960 points folds the shelf into a strip above the dock, and one under
/// 760 points tall folds the chip row into a single Settings control.
enum StudioFolding {
    static let railBelowWidth: Double = 960
    static let chipsBelowHeight: Double = 760

    static func foldsShelf(width: Double) -> Bool { width < railBelowWidth }

    static func foldsChips(height: Double) -> Bool { height < chipsBelowHeight }
}

/// One control in the dock's second row.
struct StudioChip: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case field(ImageGenField)
        case cutout
        case avoid
        case seed
        case reference
    }

    let kind: Kind
    let label: String
    let value: String
    let symbol: String
    let isOn: Bool
    let isWarning: Bool

    var spoken: String { value.isEmpty ? label : "\(label), \(value)" }
}

/// What the dock's chips say, from the slot: Core's decisions that apply to what is chosen, then the
/// switches that sit beside them. Nothing here names a thing Core does not — `applies`, `value` and
/// the field's own label and symbol decide — so the composer's pills and the Studio's can never
/// disagree about what a picture is made from.
enum StudioChips {
    static func read(slot: ImageGenSlot, engineBlocked: Bool) -> [StudioChip] {
        var chips: [StudioChip] = []
        for field in ImageGenField.allCases where slot.applies(field) {
            chips.append(
                StudioChip(
                    kind: .field(field), label: field.label, value: slot.value(of: field),
                    symbol: field.symbol, isOn: false,
                    isWarning: field == .engine && engineBlocked))
        }
        if slot.cutoutApplies {
            chips.append(
                StudioChip(
                    kind: .cutout, label: ImageGenWords.cutoutTitle, value: "",
                    symbol: slot.cutout ? "checkmark.circle.fill" : "circle.dashed", isOn: slot.cutout,
                    isWarning: false))
        }
        if slot.negativeApplies {
            let words = slot.negative.trimmingCharacters(in: .whitespacesAndNewlines)
            chips.append(
                StudioChip(
                    kind: .avoid, label: ImageGenWords.avoidTitle,
                    value: words.isEmpty ? "" : words.ellipsized(to: 18),
                    symbol: "nosign", isOn: !words.isEmpty, isWarning: false))
        }
        chips.append(
            StudioChip(
                kind: .seed, label: Localized.text("Seed"),
                value: slot.seed.chip,
                symbol: slot.seed.isHeld ? "lock.fill" : "dice", isOn: slot.seed.isHeld,
                isWarning: false))
        chips.append(
            StudioChip(
                kind: .reference, label: ImageGenWords.attachTitle,
                value: slot.references.isEmpty
                    ? "" : ImageGenWords.attachedCount(slot.references.count),
                symbol: "photo.badge.plus", isOn: !slot.references.isEmpty, isWarning: false))
        return chips
    }
}

/// The verbs a stage offers for what it holds. Core decides which exist (`ImageGenAction.offered`);
/// this decides only that a stage that holds no finished picture offers none — while painting the
/// capsule keeps its room invisibly rather than vanishing, so the stage never changes shape.
enum StudioVerbs {
    static func offered(state: StudioStageState, kept: Bool, hasWords: Bool) -> [ImageGenAction] {
        guard state.showsPicture else { return [] }
        return ImageGenAction.offered(kept: kept, hasWords: hasWords, sharing: true, tapOpens: false)
    }
}

/// The keys the Studio answers while it is in front, named once so the menu bar, the key monitor and
/// the checks in `--selftest` read the same table. ⌘ chords are shown in the menu; the monitor
/// routes both, because a window that is in front owns its own keys before the menu is asked.
enum StudioKey: CaseIterable, Sendable {
    case generate
    case stop
    case enhance
    case again
    case imageLane
    case videoLane
    case previousTile
    case nextTile
    case save
    case editThis
    case open
    case copy

    /// The Mac's key, as the character a key equivalent is spelled with and the modifiers it needs.
    var chord: (key: String, command: Bool, shift: Bool) {
        switch self {
        case .generate: return ("\r", true, false)
        case .stop: return ("\u{1B}", false, false)
        case .enhance: return ("e", true, false)
        case .again: return ("r", true, true)
        case .imageLane: return ("1", true, false)
        case .videoLane: return ("2", true, false)
        case .previousTile: return ("\u{F702}", false, false)
        case .nextTile: return ("\u{F703}", false, false)
        case .save: return ("s", true, false)
        case .editThis: return ("e", true, true)
        case .open: return (" ", false, false)
        case .copy: return ("c", true, false)
        }
    }
}

/// What the Studio's menu items say. The verbs are Core's own words; only the two shelf steps are the
/// Mac's.
enum StudioMenuWords {
    static func title(_ key: StudioKey) -> String {
        switch key {
        case .generate: return ImageGenWords.renderTitle(mode: .generate)
        case .stop: return ImageGenWords.stopTitle
        case .enhance: return ImageGenWords.enhanceTitle
        case .again: return ImageGenAction.again.title
        case .imageLane: return StudioLaneID.image.title
        case .videoLane: return StudioLaneID.video.title
        case .previousTile: return Localized.text("Previous Picture")
        case .nextTile: return Localized.text("Next Picture")
        case .save: return ImageGenAction.save.title
        case .editThis: return ImageGenAction.reference.phoneTitle
        case .open: return ImageGenAction.open.title
        case .copy: return ImageGenAction.copy.title
        }
    }

    /// The key a menu item cannot carry as an equivalent — it would take it from every text field —
    /// worn in its title instead.
    static func keyHint(_ key: StudioKey) -> String {
        switch key {
        case .stop: return "⎋"
        case .previousTile: return "←"
        case .nextTile: return "→"
        case .open: return Localized.text("Space")
        default: return ""
        }
    }
}
