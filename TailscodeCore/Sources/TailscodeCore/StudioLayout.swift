import Foundation

/// The room the Studio is given and what it does with it, said as arithmetic so a desk that draws
/// the stage with GTK widgets and a desk that draws it with anything else cannot disagree about
/// when the shelf is a rail, when the chips fold, or how much of a pane the picture owns.
///
/// Every number is a design decision from the Studio write-up and none is a toolkit's: the shelf
/// is a rail from 900 points of width and a strip above the dock below it, and the chips fold into
/// one Settings control under 520 points of height — or when the room beside a rail is under 560
/// points wide, where they would wrap onto three lines — because a dock of three rows in a short
/// or narrow pane is a dock that has eaten the picture.
public struct StudioMetrics: Sendable, Equatable {
    public let railMinimumWidth: Double
    public let settingsFoldHeight: Double
    public let settingsFoldWidth: Double
    public let toolbarHeight: Double
    public let railWidth: Double
    public let tileSide: Double
    public let gutter: Double
    public let stageMargin: Double
    public let verbsBand: Double
    public let dockMinimumHeight: Double

    public init(
        railMinimumWidth: Double, settingsFoldHeight: Double, settingsFoldWidth: Double = 560,
        toolbarHeight: Double = 0, railWidth: Double, tileSide: Double,
        gutter: Double, stageMargin: Double, verbsBand: Double, dockMinimumHeight: Double
    ) {
        self.railMinimumWidth = railMinimumWidth
        self.settingsFoldHeight = settingsFoldHeight
        self.settingsFoldWidth = settingsFoldWidth
        self.toolbarHeight = toolbarHeight
        self.railWidth = railWidth
        self.tileSide = tileSide
        self.gutter = gutter
        self.stageMargin = stageMargin
        self.verbsBand = verbsBand
        self.dockMinimumHeight = dockMinimumHeight
    }

    /// A pane among panes: the same Studio, measured by the room it has, with a bar of its own
    /// above the stage for the machine pill.
    public static let pane = StudioMetrics(
        railMinimumWidth: 900, settingsFoldHeight: 520, settingsFoldWidth: 560, toolbarHeight: 40,
        railWidth: 112, tileSide: 88, gutter: 8, stageMargin: 24, verbsBand: 52,
        dockMinimumHeight: 96)

    /// The Studio in a window of its own, whose header carries the pill.
    public static let window = StudioMetrics(
        railMinimumWidth: 900, settingsFoldHeight: 520, settingsFoldWidth: 560, toolbarHeight: 0,
        railWidth: 112, tileSide: 88, gutter: 8, stageMargin: 24, verbsBand: 52,
        dockMinimumHeight: 96)

    /// The Studio inside the sheet, whose folds are measured against the sheet rather than the
    /// window: the shelf is a strip under 960 points of sheet width and the chips move into
    /// Settings under 760 points of sheet height, because the sheet's own toolbar has already spent
    /// 44 points of the room before the stage is given any.
    public static let sheet = StudioMetrics(
        railMinimumWidth: 960, settingsFoldHeight: 760, settingsFoldWidth: 560, toolbarHeight: 0,
        railWidth: 112, tileSide: 88, gutter: 8, stageMargin: 24, verbsBand: 52,
        dockMinimumHeight: 96)

    /// A strip is one row of tiles and the gutters above and below it.
    public var stripHeight: Double { tileSide + gutter * 2 }
}

public struct StudioSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum StudioShelfPlacement: Sendable, Equatable {
    case rail
    case strip
}

public enum StudioChipPlacement: Sendable, Equatable {
    case row
    case settings
}

/// Where the shelf sits and whether the chips are laid out, given the room.
public struct StudioArrangement: Sendable, Equatable {
    public let shelf: StudioShelfPlacement
    public let chips: StudioChipPlacement

    public init(shelf: StudioShelfPlacement, chips: StudioChipPlacement) {
        self.shelf = shelf
        self.chips = chips
    }

    public static func resolve(width: Double, height: Double, metrics: StudioMetrics = .pane)
        -> StudioArrangement
    {
        let rail = width >= metrics.railMinimumWidth
        let beside = width - (rail ? metrics.railWidth : 0)
        return StudioArrangement(
            shelf: rail ? .rail : .strip,
            chips: height < metrics.settingsFoldHeight || beside < metrics.settingsFoldWidth
                ? .settings : .row)
    }
}

/// How the pane's height and width divide between the stage and everything that is not the stage,
/// and the rectangle a picture of a given shape lands in. The finished picture arrives into the
/// rectangle the sketch used because both are this one answer for the same aspect — decided before
/// the render starts and never recomputed from what arrived.
public struct StudioStageGeometry: Sendable, Equatable {
    public let stage: StudioSize
    public let picture: StudioSize?

    /// How much of the pane's height the stage owns, for the claim that it is the point.
    public func share(of pane: StudioSize) -> Double {
        guard pane.height > 0 else { return 0 }
        return stage.height / pane.height
    }

    /// - Parameters:
    ///   - pane: the room the whole Studio has.
    ///   - dockHeight: the brief dock as it stands, which the stage reserves rather than runs under.
    ///   - aspect: the picture's width over its height, or nil when there is no picture yet.
    public static func resolve(
        pane: StudioSize, dockHeight: Double, arrangement: StudioArrangement, aspect: Double?,
        metrics: StudioMetrics = .pane
    ) -> StudioStageGeometry {
        let across = pane.width - (arrangement.shelf == .rail ? metrics.railWidth : 0)
        let strip = arrangement.shelf == .strip ? metrics.stripHeight : 0
        let down = max(
            0, pane.height - metrics.toolbarHeight - max(dockHeight, metrics.dockMinimumHeight) - strip)
        let stage = StudioSize(width: max(0, across), height: down)
        guard let aspect, aspect > 0 else {
            return StudioStageGeometry(stage: stage, picture: nil)
        }
        let room = StudioSize(
            width: max(0, stage.width - metrics.stageMargin * 2),
            height: max(0, stage.height - metrics.stageMargin * 2 - metrics.verbsBand))
        return StudioStageGeometry(stage: stage, picture: fit(aspect: aspect, in: room))
    }

    /// The largest rectangle of this shape that fits inside the room.
    public static func fit(aspect: Double, in room: StudioSize) -> StudioSize {
        guard aspect > 0, room.width > 0, room.height > 0 else {
            return StudioSize(width: 0, height: 0)
        }
        let widthLimited = StudioSize(width: room.width, height: room.width / aspect)
        if widthLimited.height <= room.height { return widthLimited }
        return StudioSize(width: room.height * aspect, height: room.height)
    }
}

/// One tile on the shelf: the render in flight, a picture this device made, or one the machine
/// keeps — and where this device holds the bytes when it does.
public struct StudioShelfEntry: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case inFlight
        case session(ImageGenPicture)
        case machine(ImageGenLibraryItem, madeHere: ImageGenPicture?)
    }

    public let id: String
    public let source: Source

    public var isInFlight: Bool {
        if case .inFlight = source { return true }
        return false
    }

    /// The machine's own file, when it keeps one.
    public var item: ImageGenLibraryItem? {
        switch source {
        case .machine(let item, _): return item
        case .session(let picture): return picture.kept
        case .inFlight: return nil
        }
    }

    /// The local file this device already holds — the original bytes a drag out or a save reads.
    public var localPath: String? {
        switch source {
        case .session(let picture): return picture.path
        case .machine(_, let made): return made?.path
        case .inFlight: return nil
        }
    }
}

public enum StudioShelf {
    public static let inFlightID = "job"

    /// What this machine has made merged with what this session has, newest first.
    ///
    /// The picture just made is on the stage and on the shelf at the same time, so the two lists
    /// are one thing: a session picture whose file the machine has already listed is the machine's
    /// tile, wearing the session's local copy, in the place the machine ranks it; one the machine
    /// has not listed yet — the listing is refreshed after the render lands, and a machine that
    /// cannot list at all never will — is newer than anything the machine knows and leads. The job
    /// in flight leads everything, because that is where it will land.
    public static func merge(
        session: [ImageGenPicture], machine: [ImageGenLibraryItem], inFlight: Bool
    ) -> [StudioShelfEntry] {
        var entries: [StudioShelfEntry] = []
        if inFlight { entries.append(StudioShelfEntry(id: inFlightID, source: .inFlight)) }

        var madeHere: [String: ImageGenPicture] = [:]
        for picture in session {
            guard let remote = picture.remoteName else { continue }
            let item = ImageGenLibraryItem(filename: remote)
            if madeHere[item.id] == nil { madeHere[item.id] = picture }
        }
        var listed = Set<String>()
        for item in machine { listed.insert(item.id) }

        var seenSession = Set<String>()
        for picture in session where seenSession.insert(picture.path).inserted {
            if let remote = picture.remoteName,
                listed.contains(ImageGenLibraryItem(filename: remote).id)
            {
                continue
            }
            entries.append(StudioShelfEntry(id: "session:" + picture.path, source: .session(picture)))
        }

        var seenMachine = Set<String>()
        for item in machine where seenMachine.insert(item.id).inserted {
            entries.append(
                StudioShelfEntry(id: item.id, source: .machine(item, madeHere: madeHere[item.id])))
        }
        return entries
    }

    /// The entry the stage is showing: a kept picture by its file, a session picture by the
    /// machine's name for it when the machine lists it and by its local path when it does not.
    public static func selection(
        in entries: [StudioShelfEntry], keptID: String?, picturePath: String?
    ) -> String? {
        if let keptID, entries.contains(where: { $0.id == keptID }) { return keptID }
        guard let picturePath else { return nil }
        return entries.first(where: { $0.localPath == picturePath })?.id
    }

    /// The entry one step along, wrapping at neither end: arrow keys stop where the shelf does.
    public static func step(
        from current: String?, by delta: Int, in entries: [StudioShelfEntry]
    ) -> String? {
        let ids = entries.filter { !$0.isInFlight }.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}

/// Which tiles of a long shelf are worth holding a decoded thumbnail for: the ones in view and a
/// few either side, so a shelf of three hundred pictures keeps a few dozen in memory.
public enum StudioShelfWindow {
    public static func visible(
        offset: Double, viewport: Double, pitch: Double, count: Int, overscan: Int = 6
    ) -> Range<Int> {
        guard count > 0, pitch > 0 else { return 0..<0 }
        let first = Int((max(0, offset) / pitch).rounded(.down)) - overscan
        let last = Int(((max(0, offset) + max(0, viewport)) / pitch).rounded(.up)) + overscan
        let lower = min(max(first, 0), count)
        let upper = min(max(last, lower), count)
        return lower..<upper
    }
}

/// What one chip in the dock says: its label and its value, always both, so a chip is read the
/// same way by eye and by a screen reader and never clipped to half of itself.
public struct StudioChipReading: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case engine
        case aspect
        case size
        case detail
        case cutout
        case avoid
        case seed
        case reference
        case craft
        case length
        case smoothness
        case sound
    }

    public let id: Kind
    public let label: String
    public let value: String
    public let isOn: Bool
    public let isEnabled: Bool
    /// What is wrong with the value, said — the engine whose files the machine lacks.
    public let warning: String?

    public init(
        id: Kind, label: String, value: String, isOn: Bool = false, isEnabled: Bool = true,
        warning: String? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.warning = warning
    }

    public var accessibility: String {
        let spoken = value.isEmpty ? label : label.isEmpty ? value : "\(label), \(value)"
        guard let warning else { return spoken }
        return "\(spoken). \(warning)"
    }
}

public enum StudioChips {
    /// Core's decisions in the order a picture is made from them, then the ones that are not
    /// values that walk — cutout, avoid, seed, the references — then the craft menu. A chip that
    /// would change nothing is disabled rather than removed, so the row never moves under the
    /// pointer.
    public static func image(for slot: ImageGenSlot, sighting: ImageGenSighting?)
        -> [StudioChipReading]
    {
        var chips: [StudioChipReading] = []
        for field in ImageGenField.allCases {
            let value: String
            switch field {
            case .engine: value = slot.engine.label
            case .aspect: value = slot.aspect.ratioLabel
            default: value = slot.value(of: field)
            }
            var warning: String?
            if field == .engine, let sighting, sighting.reachable, !sighting.available(slot.engine) {
                warning = ImageGenWords.engineUnavailable(
                    slot.engine, missing: sighting.missing(for: slot.engine).count)
            }
            chips.append(
                StudioChipReading(
                    id: kind(of: field), label: field.label, value: value,
                    isEnabled: slot.applies(field), warning: warning))
        }
        chips.append(
            StudioChipReading(
                id: .cutout, label: "", value: ImageGenWords.cutoutTitle,
                isOn: slot.cutout && slot.cutoutApplies, isEnabled: slot.cutoutApplies))
        let avoid = slot.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        chips.append(
            StudioChipReading(
                id: .avoid, label: ImageGenWords.avoidTitle,
                value: avoid.isEmpty ? "…" : avoid.ellipsized(to: 18), isOn: !avoid.isEmpty,
                isEnabled: slot.negativeApplies))
        chips.append(
            StudioChipReading(
                id: .seed, label: Localized.text("Seed"),
                value: slot.seed.held.map(ImageGenSeed.short) ?? Localized.text("rolls"),
                isOn: slot.seed.isHeld))
        let held = slot.references.count
        chips.append(
            StudioChipReading(
                id: .reference, label: "",
                value: held == 0
                    ? ImageGenWords.attachTitle
                    : held == 1 ? ImageGenWords.attachMoreTitle : ImageGenWords.attachedCount(held),
                isOn: held > 0, isEnabled: held < ImageGenSlot.referenceLimit))
        chips.append(StudioChipReading(id: .craft, label: "", value: ImageGenBrief.craftTitle))
        return chips
    }

    /// The forge's decisions as the same kind of chip: size, length, smoothness, what is heard,
    /// what to avoid and the seed. They are disabled — never removed — while a render is out,
    /// because the graph on the other machine was built from the recipe as it stood.
    public static func forge(for board: ForgeBoard) -> [StudioChipReading] {
        let locked = board.isBusy
        let avoid = board.recipe.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        let sound = board.recipe.sound.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            StudioChipReading(
                id: .size, label: ForgeField.size.label, value: board.value(of: .size),
                isEnabled: !locked),
            StudioChipReading(
                id: .length, label: ForgeField.seconds.label, value: board.value(of: .seconds),
                isEnabled: !locked),
            StudioChipReading(
                id: .smoothness, label: ForgeField.fps.label, value: board.value(of: .fps),
                isEnabled: !locked),
            StudioChipReading(
                id: .sound, label: ForgeField.sound.label,
                value: sound.isEmpty ? StudioWords.soundAuto : sound.ellipsized(to: 18),
                isOn: !sound.isEmpty, isEnabled: !locked),
            StudioChipReading(
                id: .avoid, label: ForgeField.negative.label,
                value: avoid.isEmpty ? "…" : avoid.ellipsized(to: 18), isOn: !avoid.isEmpty,
                isEnabled: !locked),
            StudioChipReading(
                id: .seed, label: ForgeField.seed.label, value: board.value(of: .seed),
                isEnabled: !locked),
        ]
    }

    private static func kind(of field: ImageGenField) -> StudioChipReading.Kind {
        switch field {
        case .engine: return .engine
        case .aspect: return .aspect
        case .size: return .size
        case .detail: return .detail
        }
    }
}

/// The machine pill: the one place the Studio says where the work happens and whether it can.
public struct StudioMachinePill: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case unknown
        case ready
        case working
        case quiet
        case danger
    }

    public let machine: String
    public let state: String?
    public let version: String?
    public let tone: Tone

    public init(machine: String, state: String?, version: String?, tone: Tone) {
        self.machine = machine
        self.state = state
        self.version = version
        self.tone = tone
    }

    /// Whether the dot breathes: only while a job runs. Everything settled holds perfectly still.
    public var breathes: Bool { tone == .working }

    public var line: String {
        [machine, state, version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What the machine says it can do right now, read from the last look at it and never guessed:
    /// a machine nobody has looked at has no state to wear, and one that did not answer is asleep
    /// rather than gone, because ComfyUI is socket-activated and stops itself when idle.
    public static func image(
        machine: String, sighting: ImageGenSighting?, engine: ImageGenEngine, painting: Bool
    ) -> StudioMachinePill {
        let version = sighting?.version.map { "\(ImageGenMachineWords.versionLabel) \($0)" }
        guard let sighting else {
            return StudioMachinePill(
                machine: machine, state: nil, version: nil, tone: painting ? .working : .unknown)
        }
        guard sighting.reachable else {
            return StudioMachinePill(
                machine: machine, state: Localized.text("asleep"), version: nil,
                tone: painting ? .working : .quiet)
        }
        if sighting.available(engine) {
            return StudioMachinePill(
                machine: machine, state: Localized.text("%@ ready", engine.label), version: version,
                tone: painting ? .working : .ready)
        }
        let ready = sighting.readyEngines
        let state: String
        if ready.isEmpty {
            state = Localized.text("No engine has all its files")
        } else {
            state = Localized.text(
                "%@ only — %@ files missing", ready.map(\.label).joined(separator: ", "),
                engine.label)
        }
        return StudioMachinePill(
            machine: machine, state: state, version: version, tone: painting ? .working : .danger)
    }
}

/// What a render should cost before it is pressed, from the renders this session already made on
/// the same engine at the same size — the median of the last few, said as "about". Nothing is
/// invented: with no render to learn from there is no estimate and the line is not drawn.
public enum StudioEstimate {
    public static func image(
        engine: ImageGenEngine, size: ImageGenSize, mode: ImageGenMode,
        pictures: [ImageGenPicture], machine: String
    ) -> String? {
        let seconds = pictures
            .filter { $0.engine == engine && $0.size == size && $0.mode == mode && $0.seconds > 0 }
            .prefix(3).map(\.seconds).sorted()
        guard !seconds.isEmpty else { return nil }
        let median = seconds[seconds.count / 2]
        return Localized.text("%@ on %@", ForgeClock.aboutLine(median), machine)
    }
}

/// A clip's progress, drawn as one segment per pass of the graph rather than as one bar that
/// crosses two samplers: the sampler counts to eight, resets and counts to four, so a single bar
/// over it would either jump or lie.
public enum StudioProgress {
    /// First pass, second pass — each as a fraction of itself. Nil when the machine is not saying
    /// which node is working, in which case the caller draws the one bar it has.
    public static func passes(running: String?, step: Int, steps: Int) -> [Double]? {
        guard let running else { return nil }
        let within = steps > 0 ? min(1, max(0, Double(step) / Double(steps))) : 0
        switch running {
        case "unet", "clip", "vae_v", "vae_a", "upscaler", "pos", "neg", "cond", "still", "reel",
            "frames", "last", "prep", "start1", "start2":
            return [0, 0]
        case "pass1": return [within, 0]
        case "up": return [1, 0]
        case "pass2": return [1, within]
        case "pixels", "audio", "video", "save": return [1, 1]
        default: return nil
        }
    }
}

/// The words the Studio adds to Core's: the few sentences that belong to the arrangement rather
/// than to a decision or a state, held here so every desk says them the same way.
public enum StudioWords {
    public static func heldFromShelf(machine: String) -> String {
        Localized.text("Held from %@'s shelf, dimmed", machine)
    }

    public static var dropTitle: String {
        Localized.text("Describe a picture, or drop one here to edit")
    }

    public static var dropBody: String { Localized.text("Or start from one of these") }

    public static var nothingSent: String {
        Localized.text("Nothing was sent. Your words are still in the box.")
    }

    public static var settingsTitle: String { Localized.text("Settings") }

    /// What the sound chip says before anything is asked for: the model decides.
    public static var soundAuto: String { Localized.text("Auto") }

    /// A clip's length as a clock, which is how a poster wears it: 0:05, 1:12.
    public static func duration(_ seconds: Int) -> String {
        let whole = max(0, seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    public static var dragOutHint: String { Localized.text("Drag out to save") }

    public static var startFromTitle: String { Localized.text("Start from") }

    public static var startFromHint: String {
        Localized.text("A picture to edit: choose a file, paste, or take one from the machine's shelf")
    }

    public static func shelfTileLabel(words: String, facts: String) -> String {
        facts.isEmpty ? words : "\(words). \(facts)"
    }
}

/// The Studio's own rules, checked headlessly from both desktops' `--selftest`.
public enum StudioLayoutCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let wide = StudioArrangement.resolve(width: 1180, height: 820)
        expect(wide.shelf == .rail && wide.chips == .row, "a roomy pane gets a rail and a row of chips")
        expect(
            StudioArrangement.resolve(width: 900, height: 700).shelf == .rail,
            "the rail starts at exactly 900 points")
        expect(
            StudioArrangement.resolve(width: 899, height: 700).shelf == .strip,
            "and one point less is a strip above the dock")
        expect(
            StudioArrangement.resolve(width: 1000, height: 520).chips == .row,
            "520 points tall still holds the chips")
        expect(
            StudioArrangement.resolve(width: 1000, height: 519).chips == .settings,
            "and one point less folds them into Settings")
        expect(
            StudioArrangement.resolve(width: 559, height: 700).chips == .settings
                && StudioArrangement.resolve(width: 560, height: 700).chips == .row,
            "a pane under 560 points wide folds them too, where they would wrap onto three lines")
        expect(
            StudioArrangement.resolve(width: 900, height: 700).chips == .row,
            "but the room beside a rail is what counts: 788 points holds them")

        let pane = StudioSize(width: 1180, height: 820)
        let geometry = StudioStageGeometry.resolve(
            pane: pane, dockHeight: 132, arrangement: wide, aspect: 1.5)
        expect(geometry.share(of: pane) >= 0.6, "the stage owns at least 60% of a normal pane")
        if let picture = geometry.picture {
            expect(
                abs(picture.width / picture.height - 1.5) < 0.001,
                "the picture keeps its shape inside the stage")
            expect(
                picture.height <= geometry.stage.height - 48 - 52,
                "and leaves the verbs and the margins their room")
        } else {
            failures.append("a picture shape lands in a rectangle")
        }
        let narrow = StudioArrangement.resolve(width: 600, height: 700)
        let strip = StudioStageGeometry.resolve(
            pane: StudioSize(width: 600, height: 700), dockHeight: 132, arrangement: narrow,
            aspect: nil)
        expect(strip.picture == nil, "no shape, no rectangle")
        expect(
            strip.stage.height == 700 - StudioMetrics.pane.toolbarHeight - 132 - StudioMetrics.pane.stripHeight,
            "a strip takes its height from the stage, and a rail its width")

        let one = ImageGenPicture(
            path: "/tmp/a.png", prompt: "a", engine: .quality, mode: .generate, aspect: .square,
            seconds: 41, seed: 1, remoteName: "ComfyUI_00001_.png")
        let two = ImageGenPicture(
            path: "/tmp/b.png", prompt: "b", engine: .quality, mode: .generate, aspect: .square,
            seconds: 41, seed: 2)
        let listed = [
            ImageGenLibraryItem(filename: "ComfyUI_00002_.png"),
            ImageGenLibraryItem(filename: "ComfyUI_00001_.png"),
            ImageGenLibraryItem(filename: "ComfyUI_00001_.png"),
        ]
        let merged = StudioShelf.merge(session: [two, one], machine: listed, inFlight: true)
        expect(
            merged.map(\.id) == [
                StudioShelf.inFlightID, "session:/tmp/b.png", "ComfyUI_00002_.png",
                "ComfyUI_00001_.png",
            ],
            "the job leads, an unlisted picture of this session next, the machine's own in its order, no tile twice")
        expect(
            merged.last?.localPath == "/tmp/a.png",
            "a session picture the machine lists is the machine's tile, keeping the local copy")
        expect(
            StudioShelf.selection(in: merged, keptID: nil, picturePath: "/tmp/a.png")
                == "ComfyUI_00001_.png",
            "the stage's picture selects the tile that is the same picture")
        expect(
            StudioShelf.step(from: "ComfyUI_00001_.png", by: 1, in: merged) == "ComfyUI_00001_.png",
            "the arrows stop at the end of the shelf")
        expect(
            StudioShelf.step(from: nil, by: 1, in: merged) == "session:/tmp/b.png",
            "and start at the newest picture, never at the job")
        expect(
            StudioShelf.merge(session: [two], machine: [], inFlight: false).map(\.id)
                == ["session:/tmp/b.png"],
            "a machine that cannot list still shows this session's own pictures")

        expect(
            StudioShelfWindow.visible(offset: 0, viewport: 300, pitch: 96, count: 300, overscan: 6)
                == 0..<10,
            "the top of a long shelf holds ten tiles' thumbnails")
        expect(
            StudioShelfWindow.visible(offset: 9_600, viewport: 300, pitch: 96, count: 300, overscan: 6)
                == 94..<110,
            "scrolled down it holds the tiles in view and a few either side")
        expect(
            StudioShelfWindow.visible(offset: 90_000, viewport: 300, pitch: 96, count: 12).isEmpty,
            "and a shelf scrolled past its end holds none")

        expect(StudioWords.duration(5) == "0:05", "a five second clip wears 0:05")
        expect(StudioWords.duration(72) == "1:12", "and a minute and twelve wears 1:12")
        expect(StudioWords.duration(-3) == "0:00", "a length is never negative")

        let forged = StudioChips.forge(for: ForgeBoard(recipe: ForgeRecipe(prompt: "a cat", seconds: 5)))
        expect(
            forged.map(\.id) == [.size, .length, .smoothness, .sound, .avoid, .seed],
            "the forge's chips are its own decisions in the order a clip is made from them")
        expect(
            forged.first(where: { $0.id == .length })?.accessibility == "Length, 5s",
            "every forge chip is read as its label and its value too")
        expect(
            forged.first(where: { $0.id == .sound })?.value == StudioWords.soundAuto,
            "a clip nobody described the sound of lets the model decide, and says so")

        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        let chips = StudioChips.image(for: slot, sighting: nil)
        expect(
            chips.prefix(4).map(\.id) == [.engine, .aspect, .size, .detail],
            "the chips begin with Core's own field list, in its order")
        expect(
            chips.allSatisfy { !$0.accessibility.isEmpty }
                && chips.first?.accessibility == "Engine, Quality",
            "every chip is read as its label and its value")
        slot.setEngine(.fast)
        expect(
            StudioChips.image(for: slot, sighting: nil).first(where: { $0.id == .detail })?.isEnabled
                == false,
            "a decision that changes nothing is disabled rather than removed")
        slot.setEngine(.quality)
        let halfDressed = ImageGenSighting(
            host: "arch:8188", reachable: true, missingModels: ["diffusion_models/qwen_image_2.1_int8_convrot.safetensors"])
        expect(
            StudioChips.image(for: slot, sighting: halfDressed).first?.warning != nil,
            "the engine chip wears the warning when the machine lacks its files")

        let well = ImageGenSighting(host: "arch:8188", reachable: true, version: "0.36")
        expect(
            StudioMachinePill.image(machine: "arch", sighting: well, engine: .quality, painting: false)
                .line == "arch · Quality ready · ComfyUI 0.36",
            "a well machine reads its name, its engine and its version")
        expect(
            StudioMachinePill.image(machine: "arch", sighting: well, engine: .quality, painting: true)
                .breathes,
            "the dot breathes while a job runs")
        expect(
            !StudioMachinePill.image(machine: "arch", sighting: well, engine: .quality, painting: false)
                .breathes,
            "and holds perfectly still the moment it settles")
        expect(
            StudioMachinePill.image(
                machine: "arch", sighting: halfDressed, engine: .quality, painting: false
            ).tone == .danger,
            "a machine that cannot paint the chosen engine wears the failure tone")
        expect(
            StudioMachinePill.image(
                machine: "arch", sighting: ImageGenSighting(host: "arch:8188", reachable: false),
                engine: .quality, painting: false
            ).tone == .quiet,
            "one that did not answer is asleep, not gone")
        expect(
            StudioMachinePill.image(machine: "arch", sighting: nil, engine: .quality, painting: false)
                .line == "arch",
            "a machine nobody has looked at is named and not described")

        expect(
            StudioEstimate.image(
                engine: .quality, size: .standard, mode: .generate, pictures: [], machine: "arch")
                == nil,
            "no render to learn from, no estimate")
        expect(
            StudioEstimate.image(
                engine: .quality, size: .standard, mode: .generate, pictures: [one, two],
                machine: "arch") == "about 41 s on arch",
            "the estimate is the median of what this engine did here")

        expect(
            StudioProgress.passes(running: "pass1", step: 4, steps: 8) == [0.5, 0],
            "the first pass fills the first segment")
        expect(
            StudioProgress.passes(running: "pass2", step: 3, steps: 4) == [1, 0.75],
            "the second fills the second, the first already whole")
        expect(
            StudioProgress.passes(running: "save", step: 0, steps: 0) == [1, 1],
            "writing the file is both passes done")
        expect(
            StudioProgress.passes(running: nil, step: 3, steps: 4) == nil,
            "and a machine that names no node leaves the one bar")
        return failures
    }
}
