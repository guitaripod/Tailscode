import Foundation

/// The video forge, as rows. A generation is one machine on the tailnet, one prompt, six settings
/// and a list of what came back, and every client shows the same four sections in the same order
/// with the same words — the renderer and whether it answered, the render in hand and how far it
/// has got, what the next one will be made from, and the clips already made.
///
/// Nothing here fetches or renders. The client hands in an endpoint, a reachability verdict, job
/// snapshots off `ForgeClient.render` and the history the store holds, and the board restates
/// itself around whatever has arrived. That is what lets one set of rules — which rows exist, what
/// pressing one does, what each state is called — be proved once headlessly instead of three times
/// against three toolkits.
public struct ForgeBoard: Sendable, Equatable {
    /// How many clips the history shows before it starts holding the rest behind one row. Four is
    /// what fits under the render without the history becoming the screen.
    public static let compactLimit = 4
    /// The lengths offered by pressing the row, rather than every number the model would take. A
    /// setting somebody walks with one key needs a short walk.
    public static let secondsOptions = [3, 5, 8, 10, 15]

    public static let rendererID = "renderer"
    public static let renderID = "render"
    public static let settingsID = "settings"
    public static let historyID = "history"

    public private(set) var recipe: ForgeRecipe
    public private(set) var job: ForgeJob
    public private(set) var endpoint: ForgeEndpoint?
    /// What this device calls the machine, when a scan or a typed name said so. The address stays
    /// on the endpoint; this is only the word the chip wears.
    public private(set) var rendererName: String?
    public private(set) var history: [ForgeEntry]
    public private(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var sections: [ForgeSection] = []
    public private(set) var rows: [ForgeRow] = []
    /// What renders have cost on this machine so far, for the line under the button.
    public private(set) var clock = ForgeClock()
    /// Whether the size was picked by hand in this board's life. A chosen size is kept by the
    /// helper and by a start picture; an inherited one follows either.
    public private(set) var sizeChosen = false
    /// What the doctor last found on the machine the board points at, nil until it has looked and
    /// again whenever the board is pointed somewhere else.
    public private(set) var readiness: MediaVerdict?

    var reach = ForgePhase.idle
    /// Whether the store has been asked yet. A board nobody has handed a history to has no history
    /// section at all; one handed an empty list says the list is empty, which are different facts
    /// and read differently on a first run.
    var kept = ForgePhase.idle
    /// Whether anybody has moved the cursor yet. Job snapshots land several times a second while a
    /// render runs, and until somebody has chosen where to look the cursor belongs at the top
    /// rather than pinned to wherever the last rebuild left it.
    private var moved = false

    public init(
        recipe: ForgeRecipe = ForgeRecipe(), endpoint: ForgeEndpoint? = nil,
        rendererName: String? = nil, history: [ForgeEntry] = []
    ) {
        self.recipe = recipe
        self.endpoint = endpoint
        self.rendererName = rendererName.flatMap { $0.isEmpty ? nil : $0 }
        self.history = history
        job = ForgeJob(recipe: recipe)
        rebuild()
    }

    public var focused: ForgeRow? {
        guard rows.indices.contains(cursor), rows[cursor].isActivatable else { return nil }
        return rows[cursor]
    }

    /// The name of the whole surface, said statically so a control that only wants the word does
    /// not have to build a board to read it.
    public static var heading: String { Localized.text("Video") }

    public var heading: String { Self.heading }

    public var prompt: String { Localized.text("Describe the video") }

    public var hint: String {
        Localized.text("↑↓ moves · enter opens · tab expands · ctrl+g renders · ctrl+c stops")
    }

    /// The line the board carries under everything: what a render actually costs, said before
    /// somebody spends four minutes of somebody else's card on it.
    public static var notice: String {
        Localized.text("Rendering happens on the machine with the card, not on this one")
    }

    public var notice: String { Self.notice }

    public var canRender: Bool { endpoint != nil && recipe.isRenderable && !job.isBusy }

    public var isBusy: Bool { job.isBusy }

    /// True while the renderer's address has been given but nothing has come back from it yet.
    public var isChecking: Bool { reach == .checking }

    public mutating func point(at endpoint: ForgeEndpoint?, named name: String? = nil) {
        if endpoint != self.endpoint { readiness = nil }
        self.endpoint = endpoint
        rendererName = name.flatMap { $0.isEmpty ? nil : $0 }
        reach = endpoint == nil ? .idle : .checking
        rebuild()
    }

    public mutating func checking() {
        guard endpoint != nil else { return }
        reach = .checking
        rebuild()
    }

    /// What the port said. `listening` is deliberately not "ready": the box is socket-activated, so
    /// the port answers while the process behind it is still loading weights, and the first render
    /// of the day pays for that either way.
    public mutating func reached(_ verdict: PortReachability.Verdict) {
        guard let endpoint else { return }
        switch verdict {
        case .listening:
            reach = .ready
        case .refused, .timedOut, .nameNotResolved:
            reach = .failed(ForgeEndpoint.sentence(for: verdict, host: endpoint.host))
        }
        rebuild()
    }

    /// What the doctor found on the machine, in place of the bare port question: whether ComfyUI
    /// answers, and if it does, whether the video lane has its nodes and its files. An answer about
    /// another machine than the one on the board is somebody else's and is dropped.
    public mutating func assessed(_ verdict: MediaVerdict) {
        guard let endpoint, verdict.endpoint == endpoint else { return }
        readiness = verdict
        switch verdict.comfy {
        case .answering:
            reach = .ready
        case .starting:
            reach = .checking
        case .refused, .loopbackOnly, .timedOut, .unresolved, .notComfy:
            let check = verdict.check("media.comfy")
            reach = .failed(check.map { MediaReading.comfyDetail($0, endpoint: endpoint) } ?? "")
        }
        rebuild()
    }

    /// Why the next render would not work, or nil when nothing known stands in its way.
    public var blocker: MediaBlocker? { readiness?.video ?? readiness?.cannotReach }

    public mutating func describe(_ words: String) {
        revise(recipe.with(prompt: words))
    }

    public mutating func avoid(_ words: String) {
        revise(recipe.with(negative: words))
    }

    public mutating func hear(_ words: String) {
        revise(recipe.with(sound: words))
    }

    /// Opens the next clip on a picture, or on nothing. A clip that continues another takes
    /// that clip's own shape, and a picture whose shape is known takes the nearest offered
    /// size, unless a size was chosen by hand — a photograph cropped to a frame it never had is
    /// not what anybody meant by starting from it.
    public mutating func start(from frame: ForgeFrame?, pictureWidth: Int? = nil, pictureHeight: Int? = nil) {
        var next = recipe.with(frame: frame)
        if !sizeChosen, let frame {
            switch frame {
            case .clipEnd:
                break
            case .file, .kept:
                if let pictureWidth, let pictureHeight {
                    next = next.with(size: ForgeSize.nearest(width: pictureWidth, height: pictureHeight))
                }
            }
        }
        revise(next)
    }

    /// Continues a clip already made: the next render opens where that one ended, in the same
    /// shape, from the same words — which the person edits into what happens next — and on a
    /// fresh seed, because the same seed would be asked to make the same clip again.
    public mutating func extend(_ entry: ForgeEntry) {
        guard canContinue(entry), let asset = entry.asset else { return }
        revise(
            entry.recipe.with(frame: .clipEnd(asset))
                .with(seed: ForgeRecipe.freshSeed(avoiding: entry.recipe.seed)))
        sizeChosen = false
    }

    /// Whether a kept clip can be continued from here. The next clip opens on the last frame of a
    /// file the renderer reads off its own disk, so the clip has to be on the machine renders go
    /// to: on another machine the same name is a different clip, or none.
    public func canContinue(_ entry: ForgeEntry) -> Bool {
        entry.isPlayable && entry.isOn(endpoint)
    }

    /// The kept clip the next render would open on the end of, when it is one this device still
    /// has a receipt for. What the stage says while a continuation is waiting to be written.
    public var continuing: ForgeEntry? {
        guard case .clipEnd(let asset)? = recipe.frame else { return nil }
        return history.first { $0.asset == asset }
    }

    /// The size a helper answered with: followed, but never counted as a choice by hand.
    public mutating func follow(size: ForgeSize) {
        guard !sizeChosen, size != recipe.size else { return }
        revise(recipe.with(size: size))
    }

    /// What renders have cost, read back from the store or learned from a finished one.
    public mutating func learned(_ clock: ForgeClock) {
        self.clock = clock
        if !job.isBusy { job.expect(clock.estimate(recipe)) }
        rebuild()
    }

    /// One finished render, measured. Answers the clock as it now stands so the caller can keep
    /// it.
    @discardableResult
    public mutating func learn(from job: ForgeJob) -> ForgeClock? {
        guard let seconds = job.worked else { return nil }
        clock.learn(job.recipe, seconds: seconds)
        return clock
    }

    /// What the next render should cost, for the line under the button. Nil until a clip on the
    /// same model has been measured.
    public var expectation: String? {
        guard !job.isBusy, let seconds = clock.estimate(recipe) else { return nil }
        return ForgeClock.aboutLine(seconds)
    }

    /// Changes what the next render is made from. A render already in flight keeps its own copy of
    /// the recipe it was started with, so editing the draft mid-render changes the next one rather
    /// than rewriting the one being watched.
    public mutating func revise(_ recipe: ForgeRecipe) {
        self.recipe = recipe
        if !job.isBusy {
            job.revise(recipe)
            job.expect(clock.estimate(recipe))
        }
        rebuild()
    }

    /// One snapshot off the client's render stream. The board keeps the whole job rather than a
    /// percentage, because every word on the render row — what it is doing, which pass, how long
    /// it took, why it stopped — is the job's to say.
    public mutating func saw(_ job: ForgeJob) {
        self.job = job
        rebuild()
    }

    public mutating func filled(history: [ForgeEntry]) {
        self.history = history
        kept = .ready
        rebuild()
    }

    /// Puts an old clip's settings back in the draft. The point of keeping a seed is that somebody
    /// can ask for the same thing again, or the same thing slightly different, without retyping it.
    public mutating func reuse(_ entry: ForgeEntry) {
        revise(entry.recipe)
        sizeChosen = false
    }

    public mutating func move(by delta: Int) {
        let stops = rows.indices.filter { rows[$0].isActivatable }
        guard !stops.isEmpty else { return }
        guard let place = stops.firstIndex(where: { $0 >= cursor }) ?? stops.indices.last else {
            return
        }
        let landing = max(0, min(stops.count - 1, place + delta))
        cursor = stops[landing]
        moved = true
    }

    public mutating func focus(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isActivatable else { return }
        cursor = index
        moved = true
    }

    public mutating func activate() -> ForgeAction? {
        guard let row = focused else { return nil }
        return activate(row)
    }

    public mutating func activate(_ row: ForgeRow) -> ForgeAction? {
        switch row.kind {
        case .job:
            return begin()
        case .field(let field):
            if field.opensSetup { return .configure }
            guard field.isCyclable else { return .edit(field) }
            return .choose(field)
        case .clip(let entry):
            guard let asset = entry.asset else {
                reuse(entry)
                return nil
            }
            return .play(asset)
        case .expander(let id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            rebuild()
            return nil
        case .note:
            return nil
        }
    }

    /// What pressing the render row means, which is a different thing in each of its four states:
    /// stop what is running, play what came back, ask for an address that was never given, or say
    /// which field is still empty — and only when none of those is true, render.
    public mutating func begin() -> ForgeAction? {
        if job.isBusy { return .cancel }
        if let asset = job.asset { return .play(asset) }
        guard endpoint != nil else { return .configure }
        if blocker != nil { return .checklist }
        guard recipe.isRenderable else { return .edit(.prompt) }
        return .render(recipe)
    }

    /// Steps back out of whatever the board opened: expanded sections first. Answers false when
    /// there was nothing to close, so Escape goes on to mean whatever else the app makes it mean.
    @discardableResult
    public mutating func back() -> Bool {
        guard !expanded.isEmpty else { return false }
        expanded.removeAll()
        rebuild()
        return true
    }

    public mutating func handle(_ command: ForgeCommand) -> (handled: Bool, action: ForgeAction?) {
        switch command {
        case .up:
            move(by: -1)
            return (true, nil)
        case .down:
            move(by: 1)
            return (true, nil)
        case .activate:
            return (true, activate())
        case .expand:
            guard let row = focused else { return (false, nil) }
            let id = row.sectionID
            guard sections.first(where: { $0.id == id })?.hidden ?? 0 > 0 || expanded.contains(id)
            else { return (true, nil) }
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            rebuild()
            return (true, nil)
        case .render:
            return (true, begin())
        case .cancel:
            guard job.isBusy else { return (false, nil) }
            return (true, .cancel)
        case .reroll:
            guard !job.isBusy else { return (true, nil) }
            cycle(.seed)
            return (true, nil)
        case .back:
            return (back(), nil)
        }
    }

    /// Keys the board claims. Every one of them is a chord a prompt box has no use for, because the
    /// same keystroke stream is writing the prompt: bare letters and digits stay in the field.
    public static func command(for chord: KeyChord) -> ForgeCommand? {
        if chord.control {
            guard let character = Keymap.scalar(chord.keyval) else { return nil }
            switch character {
            case "g": return .render
            case "c": return .cancel
            case "r": return .reroll
            case "n": return .down
            case "p": return .up
            default: return nil
            }
        }
        guard !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter: return .activate
        case Keymap.tab: return .expand
        case Keymap.escape: return .back
        default: return nil
        }
    }

    /// Applies one row from `choices(of:)`. An unknown id is ignored rather than crashing, because
    /// a menu rebuilt under a press can hand back a value the board no longer offers.
    public mutating func pick(_ field: ForgeField, id: String) {
        switch field {
        case .size:
            guard let size = ForgeSize.options.first(where: { $0.id == id }) else { return }
            revise(recipe.with(size: size))
            sizeChosen = true
        case .seconds:
            guard let seconds = Int(id) else { return }
            revise(recipe.with(seconds: seconds))
        case .fps:
            guard let fps = Int(id) else { return }
            revise(recipe.with(fps: fps))
        case .seed:
            guard id == "reroll" else { return }
            cycle(.seed)
        case .endpoint, .prompt, .negative, .sound, .frame:
            return
        }
    }

    private mutating func cycle(_ field: ForgeField) {
        switch field {
        case .size:
            revise(recipe.with(size: Self.next(ForgeSize.options, after: recipe.size)))
            sizeChosen = true
        case .seconds:
            revise(recipe.with(seconds: Self.next(Self.secondsOptions, after: recipe.seconds)))
        case .fps:
            revise(recipe.with(fps: Self.next(ForgeRecipe.fpsOptions, after: recipe.fps)))
        case .seed:
            revise(recipe.with(seed: ForgeRecipe.freshSeed(avoiding: recipe.seed)))
        case .endpoint, .prompt, .negative, .sound, .frame:
            return
        }
    }

    /// The next value in a short list, wrapping. A value that is not in the list at all lands on
    /// the first one rather than on nothing, because a setting restored from an older build must
    /// still be walkable.
    private static func next<T: Equatable>(_ list: [T], after value: T) -> T {
        guard let first = list.first else { return value }
        guard let index = list.firstIndex(of: value) else { return first }
        return list[(index + 1) % list.count]
    }

    private mutating func keepPlace(on identity: String?) {
        guard moved, let identity, let index = rows.firstIndex(where: { $0.id == identity }),
            rows[index].isActivatable
        else {
            cursor = rows.firstIndex { $0.isActivatable } ?? -1
            return
        }
        cursor = index
    }

    private mutating func rebuild() {
        let held = focused?.id
        sections = [rendererSection(), renderSection(), settingsSection(), historySection()]
            .compactMap { $0 }
            .filter { !$0.rows.isEmpty }
        rows = sections.flatMap(\.rows)
        keepPlace(on: held)
    }
}

extension ForgeBoard {
    /// A section's heading detail, minus the two the rest of every surface already says: the
    /// render's detail is the caption of the call button and the settings' summary is readable off
    /// the rows beneath it, so printing either in a heading makes a reader look for a difference
    /// that is not there. Two clients each carried this rule and the third missed it, which is why
    /// it lives here.
    public static func headerDetail(of section: ForgeSection) -> String? {
        guard section.id != renderID, section.id != settingsID else { return nil }
        return section.detail.isEmpty ? nil : section.detail
    }

    /// A row addressed by section and index, which is how a client that draws sections rather than
    /// one flat list reports a click.
    public mutating func focus(section id: String, offset: Int) {
        guard let section = sections.first(where: { $0.id == id }),
            section.rows.indices.contains(offset),
            let index = rows.firstIndex(where: { $0.id == section.rows[offset].id })
        else { return }
        focus(index)
    }
}
