import Foundation

/// Where one part of the board is in its life. The renderer is a machine that may be asleep, the
/// render is minutes long, and the clips are already on disk — three different waits, so each
/// section says for itself what it is doing rather than sharing one spinner that would lie about
/// two of them.
public enum ForgePhase: Sendable, Equatable {
    case idle
    case checking
    case ready
    case failed(String)
}

/// A thing about the next render somebody can change. Splitting them into a named list rather than
/// letting each client lay out its own form is what keeps a phone, a Mac and a Linux desktop
/// offering the same seven decisions in the same order under the same words.
public enum ForgeField: String, Sendable, Equatable, CaseIterable {
    case endpoint
    case prompt
    case negative
    case size
    case seconds
    case fps
    case model
    case seed

    public var label: String {
        switch self {
        case .endpoint: return Localized.text("Renderer")
        case .prompt: return Localized.text("Prompt")
        case .negative: return Localized.text("Avoid")
        case .size: return Localized.text("Size")
        case .seconds: return Localized.text("Length")
        case .fps: return Localized.text("Smoothness")
        case .model: return Localized.text("Model")
        case .seed: return Localized.text("Seed")
        }
    }

    /// The renderer is not a value to type into the board — it is a machine to find, to check and
    /// to remember, which is a surface of its own (`ForgeSetup`). Pressing it opens that surface
    /// rather than a text field, which is the difference between setting something up and editing
    /// a string.
    public var opensSetup: Bool { self == .endpoint }

    /// Whether the board can change this by itself. Words are typed and an address is dictated, so
    /// those go back to the client as something to open; the rest are short lists the board walks,
    /// which is why pressing one of them is a step rather than an outcome.
    public var isCyclable: Bool {
        switch self {
        case .size, .seconds, .fps, .model, .seed: return true
        case .endpoint, .prompt, .negative: return false
        }
    }
}

/// What a row is, underneath what it says. Every client draws all five the same way — a title, a
/// line under it, sometimes a badge, sometimes a bar — and only needs the kind to know what
/// pressing it means.
public enum ForgeRowKind: Sendable, Equatable {
    case job
    case field(ForgeField)
    case clip(ForgeEntry)
    case expander(String)
    case note
}

/// What activating a row means to the client. Anything the board can do on its own — walking a
/// setting to its next value, expanding a section, restoring an old recipe into the draft — never
/// reaches here.
public enum ForgeAction: Sendable, Equatable {
    case render(ForgeRecipe)
    case cancel
    case play(ForgeAsset)
    /// A value the board cannot walk: the client opens its own field for it.
    case edit(ForgeField)
    /// There is no renderer yet, so there is nothing to render on. The client asks for an address.
    case configure
}

public struct ForgeRow: Sendable, Equatable, Identifiable {
    public let sectionID: String
    public let kind: ForgeRowKind
    public let title: String
    public let detail: String
    public let badge: String?
    /// A dimmer third line — what a setting means, or why a render stopped. A row carrying one is
    /// still an ordinary row.
    public let note: String?
    /// How far a render has got, when one is running. Nil on every other row, so a client draws a
    /// bar exactly where there is progress to show and nowhere else.
    public let fraction: Double?
    public let isPrimary: Bool
    let enabled: Bool

    init(
        sectionID: String, kind: ForgeRowKind, title: String, detail: String, badge: String? = nil,
        note: String? = nil, fraction: Double? = nil, isPrimary: Bool = false, enabled: Bool = true
    ) {
        self.sectionID = sectionID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.badge = badge
        self.note = note
        self.fraction = fraction
        self.isPrimary = isPrimary
        self.enabled = enabled
    }

    public var id: String { "\(sectionID)/\(anchor)" }

    /// A note is a line the board owed the reader, not something to press; a setting the render in
    /// flight has already consumed is not something to press either. The cursor skips both.
    public var isActivatable: Bool {
        if case .note = kind { return false }
        return enabled
    }

    public var entry: ForgeEntry? {
        if case .clip(let entry) = kind { return entry }
        return nil
    }

    private var anchor: String {
        switch kind {
        case .job: return "job"
        case .field(let field): return "field/\(field.rawValue)"
        case .clip(let entry): return "clip/\(entry.id)"
        case .expander(let id): return "more/\(id)"
        case .note: return "note/\(title)"
        }
    }
}

public struct ForgeSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let phase: ForgePhase
    public let rows: [ForgeRow]
    /// How many rows are held back behind the expander — zero when the section shows everything it
    /// has. The expander row already says the number; this is for a client that wants to say it
    /// somewhere else too.
    public let hidden: Int
}

/// What a keystroke means to the board. The same keystream is typing a prompt, so the board claims
/// only what a text field cannot want: the arrows, Enter, Tab, Escape, and control chords somebody
/// pressed on purpose.
public enum ForgeCommand: Sendable, Equatable {
    case up
    case down
    case activate
    case expand
    case render
    case cancel
    case reroll
    case back
}

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
    public private(set) var history: [ForgeEntry]
    public private(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var sections: [ForgeSection] = []
    public private(set) var rows: [ForgeRow] = []

    private var reach = ForgePhase.idle
    /// Whether the store has been asked yet. A board nobody has handed a history to has no history
    /// section at all; one handed an empty list says the list is empty, which are different facts
    /// and read differently on a first run.
    private var kept = ForgePhase.idle
    /// Whether anybody has moved the cursor yet. Job snapshots land several times a second while a
    /// render runs, and until somebody has chosen where to look the cursor belongs at the top
    /// rather than pinned to wherever the last rebuild left it.
    private var moved = false

    public init(
        recipe: ForgeRecipe = ForgeRecipe(), endpoint: ForgeEndpoint? = nil,
        history: [ForgeEntry] = []
    ) {
        self.recipe = recipe
        self.endpoint = endpoint
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

    public mutating func point(at endpoint: ForgeEndpoint?) {
        self.endpoint = endpoint
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

    public mutating func describe(_ words: String) {
        revise(recipe.with(prompt: words))
    }

    public mutating func avoid(_ words: String) {
        revise(recipe.with(negative: words))
    }

    /// Changes what the next render is made from. A render already in flight keeps its own copy of
    /// the recipe it was started with, so editing the draft mid-render changes the next one rather
    /// than rewriting the one being watched.
    public mutating func revise(_ recipe: ForgeRecipe) {
        self.recipe = recipe
        if !job.isBusy { job.revise(recipe) }
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
            cycle(field)
            return nil
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

    /// What a setting currently says, in the words the row shows. One reader for all three clients
    /// so a Mac cannot spell a frame rate differently from a phone.
    public func value(of field: ForgeField) -> String {
        switch field {
        case .endpoint:
            return endpoint?.displayHost ?? Localized.text("Not set up yet")
        case .prompt:
            let trimmed = recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Localized.text("Describe the video") : trimmed
        case .negative:
            let trimmed = recipe.negative.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Localized.text("Nothing in particular") : trimmed
        case .size:
            return recipe.size.label
        case .seconds:
            return Localized.text("%@s", "\(recipe.seconds)")
        case .fps:
            return Localized.text("%@ fps", "\(recipe.fps)")
        case .model:
            return recipe.model.label
        case .seed:
            return "\(recipe.seed)"
        }
    }

    private mutating func cycle(_ field: ForgeField) {
        switch field {
        case .size:
            revise(recipe.with(size: Self.next(ForgeSize.options, after: recipe.size)))
        case .seconds:
            revise(recipe.with(seconds: Self.next(Self.secondsOptions, after: recipe.seconds)))
        case .fps:
            revise(recipe.with(fps: Self.next(ForgeRecipe.fpsOptions, after: recipe.fps)))
        case .model:
            revise(recipe.with(model: Self.next(ForgeModel.allCases, after: recipe.model)))
        case .seed:
            revise(recipe.with(seed: ForgeRecipe.freshSeed(avoiding: recipe.seed)))
        case .endpoint, .prompt, .negative:
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

    private func rendererSection() -> ForgeSection {
        let row = ForgeRow(
            sectionID: Self.rendererID, kind: .field(.endpoint), title: value(of: .endpoint),
            detail: rendererLine, badge: endpoint == nil ? nil : reachBadge)
        return ForgeSection(
            id: Self.rendererID, title: ForgeField.endpoint.label, detail: rendererCall,
            phase: reach, rows: [row], hidden: 0)
    }

    /// What the renderer section offers before there is a renderer. A section that says nothing
    /// where the whole feature is blocked is a dead end; this is the one line that names both ways
    /// out, and the row under it opens the surface that does either.
    private var rendererCall: String {
        endpoint == nil ? Localized.text("Find it on your tailnet, or type its address") : ""
    }

    private var rendererLine: String {
        switch reach {
        case .failed(let reason): return reason
        case .checking: return Localized.text("Checking…")
        case .ready: return Localized.text("Answering on %@", "\(endpoint?.port ?? ForgeEndpoint.defaultPort)")
        case .idle:
            return endpoint == nil
                ? Localized.text("Point this at the machine with the card")
                : Localized.text("Not checked yet")
        }
    }

    private var reachBadge: String? {
        switch reach {
        case .ready: return Localized.text("up")
        case .failed: return Localized.text("down")
        case .checking, .idle: return nil
        }
    }

    private func renderSection() -> ForgeSection {
        let row = ForgeRow(
            sectionID: Self.renderID, kind: .job, title: job.title, detail: job.subtitle,
            badge: job.badge, note: job.detail, fraction: job.fraction, isPrimary: true)
        return ForgeSection(
            id: Self.renderID, title: Localized.text("Render"), detail: renderCall, phase: renderPhase,
            rows: [row], hidden: 0)
    }

    /// What the button under the render says it would do, which is the same question `begin()`
    /// answers — said in words here so a client never has to guess a caption from a phase.
    public var renderCall: String {
        if job.isBusy { return Localized.text("Stop") }
        if job.asset != nil { return Localized.text("Play") }
        if endpoint == nil { return ForgeSetup.title }
        return Localized.text("Render")
    }

    private var renderPhase: ForgePhase {
        switch job.phase {
        case .drafting: return .idle
        case .submitting, .queued, .running: return .checking
        case .done: return .ready
        case .failed(let reason): return .failed(reason)
        case .cancelled: return .idle
        }
    }

    /// The settings, disabled while a render is in flight: the graph on the other machine was built
    /// from the recipe as it stood when it was posted, and a row that looks editable but changes
    /// nothing about what is on screen is worse than a row that says it is out of reach.
    private func settingsSection() -> ForgeSection {
        let fields: [ForgeField] = [.prompt, .negative, .size, .seconds, .fps, .model, .seed]
        let rows = fields.map { field in
            ForgeRow(
                sectionID: Self.settingsID, kind: .field(field), title: field.label,
                detail: value(of: field), note: hint(for: field), enabled: !job.isBusy)
        }
        return ForgeSection(
            id: Self.settingsID, title: Localized.text("Settings"), detail: recipe.summary,
            phase: .ready, rows: rows, hidden: 0)
    }

    private func hint(for field: ForgeField) -> String? {
        switch field {
        case .model: return recipe.model.detail
        case .seconds: return Localized.text("%@ frames", "\(recipe.length)")
        case .seed: return Localized.text("The same seed and prompt make the same clip")
        case .endpoint, .prompt, .negative, .size, .fps: return nil
        }
    }

    private func historySection() -> ForgeSection? {
        guard kept != .idle || !history.isEmpty else { return nil }
        let built = history.map { entry in
            ForgeRow(
                sectionID: Self.historyID, kind: .clip(entry), title: entry.title,
                detail: entry.detail, badge: entry.badge)
        }
        return section(
            id: Self.historyID, title: Localized.text("Recent"),
            detail: Localized.text("%@ kept", "\(history.count)"), phase: kept, rows: built,
            empty: Localized.text("Nothing rendered yet"))
    }

    /// One section, compacted: the first few rows, then one row standing for the rest. A section
    /// that is waiting or that failed says so as its own row rather than as a missing section.
    private func section(
        id: String, title: String, detail: String, phase: ForgePhase, rows: [ForgeRow],
        empty: String, limit: Int = ForgeBoard.compactLimit
    ) -> ForgeSection {
        if rows.isEmpty {
            let line: String?
            switch phase {
            case .checking: line = Localized.text("Checking…")
            case .failed(let reason): line = reason
            case .ready: line = empty.isEmpty ? nil : empty
            case .idle: line = nil
            }
            guard let line else {
                return ForgeSection(
                    id: id, title: title, detail: detail, phase: phase, rows: [], hidden: 0)
            }
            return ForgeSection(
                id: id, title: title, detail: detail, phase: phase,
                rows: [ForgeRow(sectionID: id, kind: .note, title: line, detail: "")], hidden: 0)
        }
        let showsAll = expanded.contains(id) || rows.count <= limit
        let shown = showsAll ? rows : Array(rows.prefix(limit))
        let hidden = rows.count - shown.count
        var built = shown
        if hidden > 0 {
            built.append(
                ForgeRow(
                    sectionID: id, kind: .expander(id), title: Localized.text("%@ more", "\(hidden)"),
                    detail: Localized.text("tab shows them")))
        } else if showsAll, rows.count > limit {
            built.append(
                ForgeRow(
                    sectionID: id, kind: .expander(id), title: Localized.text("Fewer"),
                    detail: Localized.text("tab hides them again")))
        }
        if case .failed(let reason) = phase {
            built.append(ForgeRow(sectionID: id, kind: .note, title: reason, detail: ""))
        }
        return ForgeSection(
            id: id, title: title, detail: detail, phase: phase, rows: built, hidden: hidden)
    }
}

extension ForgeBoard {
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

/// The forge's rules, checked headlessly rather than in one client — the graph the box actually
/// ran, every frame the socket actually sends, the job's walk from a prompt to a file, and the
/// board that draws all of it. Both desktops run this from their own `--selftest`, so a ComfyUI
/// upgrade that renames a field or a refactor that loses the length invariant fails here rather
/// than as an empty progress bar on three platforms.
public enum ForgeBoardCheck {
    public static func run() -> [String] {
        var failures = ForgeSetupCheck.run()
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        struct Stranger: Error {}

        let recipe = ForgeRecipe(
            prompt: "a cat asleep on a warm roof", negative: "blurry", width: 1280, height: 704,
            seconds: 5, fps: 24, seed: 7)
        expect(recipe.length == 121, "five seconds at twenty-four frames is a hundred and twenty-one")
        expect(recipe.length == recipe.seconds * recipe.fps + 1, "the frame count is seconds times rate plus the keyframe")
        expect(
            recipe.stageOneWidth == 640 && recipe.stageOneHeight == 352,
            "the first pass samples at half the asked-for size")
        expect(ForgeRecipe(width: 1281, height: 703).width % ForgeRecipe.block == 0, "a frame size is rounded onto the latent grid")
        expect(ForgeRecipe(width: 1281, height: 703).height % ForgeRecipe.block == 0, "in both directions")
        expect(ForgeRecipe(seconds: 900).seconds == ForgeRecipe.secondsRange.upperBound, "a length nobody can render is clamped")
        expect(ForgeRecipe(fps: 7).fps == 24, "a frame rate the model does not know falls back")
        expect(!ForgeRecipe().isRenderable, "nothing is rendered from an empty prompt")
        expect(recipe.isRenderable, "and something is rendered from a described one")

        let graph = ForgeGraph(recipe: recipe)
        expect(graph.problems.isEmpty, "the verified graph has nothing wrong with it")
        expect(graph.nodes.count == 28, "the graph is the twenty-eight nodes the box ran")
        expect(graph.node("lat_v")?.inputs["length"] == .whole(121), "the latent carries the frame count")
        expect(graph.node("lat_v")?.inputs["width"] == .whole(640), "and the halved width")
        expect(graph.node("lat_a")?.inputs["frames_number"] == .whole(121), "the audio latent is the same length")
        expect(graph.node("noise1")?.inputs["noise_seed"] == .whole(7), "the seed drives the first pass")
        expect(
            graph.node("noise2")?.inputs["noise_seed"] == .whole(ForgeGraph.refinementSeed),
            "and the refinement pass is fixed, so a seed means one picture")
        expect(
            graph.node("unet")?.inputs["unet_name"] == .text(ForgeModel.distilled.fileName),
            "the chosen model is the one loaded")
        expect(
            graph.node("sig1")?.inputs["sigmas"] == .text(ForgeModel.distilled.stageOneSigmas),
            "and it brings its own schedule")
        expect(graph.node("save")?.inputs["filename_prefix"] == .text(ForgeGraph.prefix), "everything lands in one folder")
        expect(graph.node("split1")?.classType == "LTXVSeparateAVLatent", "the passes are split back into video and audio")
        expect(graph.node("av2")?.inputs["audio_latent"] == .link("split1", 1), "and the second slot is the audio")
        for node in graph.nodes {
            for link in node.links where graph.node(link.key) == nil {
                failures.append("\(node.key) takes \(link.field) from a node that is not there")
            }
        }
        expect(JSONSerialization.isValidJSONObject(graph.payload), "the graph is postable as it stands")
        expect(graph.payload.count == graph.nodes.count, "and every node reaches the wire")

        let broken = ForgeGraph(recipe: ForgeRecipe(prompt: "x", width: 1280, height: 704))
        expect(broken.problems.isEmpty, "a plain recipe is renderable")

        expect(
            ForgeEvent.read(#"{"type":"status","data":{"status":{"exec_info":{"queue_remaining":2}},"sid":"s"}}"#)
                == .status(queued: 2), "a status frame carries the queue")
        expect(
            ForgeEvent.read(#"{"type":"execution_start","data":{"prompt_id":"p","timestamp":1}}"#)
                == .started("p"), "a start names the job")
        expect(
            ForgeEvent.read(#"{"type":"execution_cached","data":{"nodes":["unet"],"prompt_id":"p"}}"#)
                == .cached("p", nodes: ["unet"]), "a cached frame lists what it skipped")
        expect(
            ForgeEvent.read(#"{"type":"executing","data":{"node":"pass1","display_node":"pass1","prompt_id":"p"}}"#)
                == .executing("p", node: "pass1"), "an executing frame names the node")
        expect(
            ForgeEvent.read(#"{"type":"executed","data":{"node":"save","display_node":"save","output":null,"prompt_id":"p"}}"#)
                == .executed("p", node: "save"), "an executed frame does too")
        expect(
            ForgeEvent.read(#"{"type":"progress","data":{"value":3,"max":8,"prompt_id":"p","node":"pass1"}}"#)
                == .sampling("p", node: "pass1", step: 3, steps: 8),
            "a progress frame is the sampler's step and never the whole render")
        expect(
            ForgeEvent.read(#"{"type":"execution_success","data":{"prompt_id":"p","timestamp":2}}"#)
                == .succeeded("p"), "a success frame is terminal")
        expect(
            ForgeEvent.read(#"{"type":"executing","data":{"node":null,"prompt_id":"p"}}"#)
                == .finished("p"),
            "an executing frame with no node is how a finished render announces itself")
        expect(ForgeEvent.read(#"{"type":"weather","data":{}}"#) == .ignored, "a frame nobody knows is dropped, not fatal")
        expect(ForgeEvent.read("not json at all") == .ignored, "and so is anything that is not a frame")
        expect(ForgeEvent.finished("p").isTerminal, "the null-node frame ends the listening")
        expect(!ForgeEvent.executing("p", node: "pass1").isTerminal, "an ordinary one does not")
        expect(ForgeEvent.status(queued: 0).promptID == nil, "a status frame is about no job in particular")

        let stateFrame = #"""
            {"type":"progress_state","data":{"prompt_id":"p","nodes":{
            "unet":{"value":1.0,"max":1.0,"state":"finished","node_id":"unet","display_node_id":"unet"},
            "clip":{"value":1.0,"max":1.0,"state":"finished","node_id":"clip","display_node_id":"clip"},
            "pass1":{"value":0.4,"max":1.0,"state":"running","node_id":"pass1","display_node_id":"pass1"},
            "save":{"value":0.0,"max":1.0,"state":"pending","node_id":"save","display_node_id":"save"}}}}
            """#
        guard case .progressed(let statePrompt, let census) = ForgeEvent.read(stateFrame) else {
            failures.append("a progress_state frame is a census")
            return failures
        }
        expect(statePrompt == "p", "the census names its job")
        expect(census.total == 4 && census.finished == 2, "the census counts every node, finished and not")
        expect(census.fraction == 0.5, "and the honest fraction is finished over total")
        expect(census.running == "pass1", "it also says what is working")
        expect(ForgeCensus(finished: 0, total: 0, running: nil).fraction == 0, "a census of nothing is not a division by zero")

        let failure = ForgeEvent.read(
            #"{"type":"execution_error","data":{"prompt_id":"p","node_type":"UNETLoader","exception_message":"no such file"}}"#)
        expect(failure == .failed("p", reason: Localized.text("%@ failed: %@", "UNETLoader", "no such file")),
            "an error frame carries the server's own words")
        expect(
            ForgeEvent.read(#"{"type":"execution_error","data":{"prompt_id":"p"}}"#)
                == .failed("p", reason: Localized.text("The render failed and said nothing about why")),
            "and says so plainly when it carries none")

        var job = ForgeJob(recipe: recipe)
        expect(job.phase == .drafting, "a job starts as a draft")
        expect(job.subtitle == Localized.text("Ready to render"), "a described draft says it is ready")
        expect(ForgeJob().subtitle == Localized.text("Describe the video"), "an empty one asks for words")
        job.submitting()
        expect(job.subtitle == Localized.text("Waking the renderer…"), "the twelve-second wake is explained while it happens")
        job.accepted(promptID: "p", queued: 2)
        expect(job.phase == .queued(2), "an accepted job knows how many are ahead")
        expect(job.subtitle == Localized.text("%@ ahead in the queue", "2"), "and says so")
        job.saw(.status(queued: 3))
        expect(job.phase == .queued(2), "the queue frame counts this job too")
        job.saw(.started("p"))
        expect(job.fraction == 0, "a started job is running at nothing")
        job.saw(.progressed("p", census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
        expect(job.fraction == 0.25, "the bar is the node census")
        expect(job.stageName == Localized.text("First pass"), "and the node is said as a phrase")
        job.saw(.sampling("p", node: "pass1", step: 3, steps: 8))
        expect(job.fraction == 0.25, "a sampler step does not move the overall bar")
        expect(job.detail.contains(Localized.text("step %@ of %@", "3", "8")), "it is said in words instead")
        job.saw(.progressed("p", census: ForgeCensus(finished: 3, total: 28, running: "pass2")))
        expect(job.fraction == 0.25, "a census that counts fewer nodes does not walk the bar backwards")
        job.saw(.failed("other", reason: "somebody else's render"))
        expect(job.isBusy, "a frame about another job is not this job")
        job.saw(.finished("p"))
        expect(job.isCollecting, "the last frame leaves the job full but not finished")
        expect(job.subtitle == Localized.text("Saving the file…"), "which is a state with its own words")
        let asset = ForgeAsset(filename: "forge_00001.mp4", subfolder: "video", type: "output")
        job.delivered(asset)
        expect(job.asset == asset, "the file is the outcome")
        expect(job.badge == Localized.text("ready"), "and the row says so in a word")
        expect(job.isFinished && !job.isBusy, "a delivered job is over")

        var stopped = ForgeJob(recipe: recipe)
        stopped.submitting()
        stopped.accepted(promptID: "p")
        stopped.saw(.interrupted("p"))
        expect(stopped.phase == .cancelled, "an interrupt stops the job")
        expect(stopped.subtitle == Localized.text("Stopped"), "and says only that")

        var burnt = ForgeJob(recipe: recipe)
        burnt.submitting()
        burnt.accepted(promptID: "p")
        burnt.saw(.failed("p", reason: "out of memory"))
        expect(burnt.phase == .failed("out of memory"), "a failure is terminal")
        expect(burnt.subtitle == "out of memory", "and the reason is the line the reader gets")
        expect(burnt.badge == Localized.text("failed"), "with a word in the corner")

        guard case .endpoint(let arch) = ForgeEndpoint.read("arch") else {
            failures.append("a bare machine name is an endpoint")
            return failures
        }
        expect(arch.port == ForgeEndpoint.defaultPort, "and the port it answers on is supplied")
        expect(ForgeEndpoint.read("http://arch:9000") == .endpoint(ForgeEndpoint(host: "arch", port: 9000)), "a typed port is kept")
        expect(ForgeEndpoint.read("0.0.0.0:8188") == .bindAll, "the address a server binds to is not one to reach")
        expect(ForgeEndpoint.read("") == .empty, "nothing typed is not an error")
        expect(ForgeEndpoint.complaint(.bindAll) != nil, "and every refusal has a sentence")
        expect(ForgeEndpoint.complaint(.endpoint(arch)) == nil, "while a good address has none")
        expect(
            arch.socketURL(clientID: "abc")?.absoluteString == "ws://arch:8188/ws?clientId=abc",
            "the socket carries the same client id the submission will")
        expect(
            asset.url(on: arch)?.absoluteString
                == "http://arch:8188/view?filename=forge_00001.mp4&subfolder=video&type=output",
            "and a finished clip is fetched by the three fields the server gave back")
        expect(asset.isVideo, "an mp4 is a video")

        expect(ForgeFailure.unreachable("arch").description == Localized.text("%@ did not answer", "arch"), "an unreachable box names itself")
        expect(ForgeFailure.rejected("arch", "no such model").description == "no such model", "a refusal is the server's own words")
        expect(ForgeFailure.noOutput("arch").description == Localized.text("%@ finished but saved no video", "arch"), "a render that saved nothing says so")
        expect(
            ForgeFailure.missingFile("arch").description
                == Localized.text("%@ no longer has that clip", "arch"),
            "a kept clip whose file was cleaned up is gone rather than unreachable")
        expect(ForgeFailure.unconfigured.host.isEmpty, "a forge with no machine names none")
        expect(
            ForgeClient.reason(Stranger(), host: "arch") == ForgeFailure.unreachable("arch").description,
            "a foreign error never reaches a screen as itself")

        var board = ForgeBoard()
        expect(
            board.sections.map(\.id) == [ForgeBoard.rendererID, ForgeBoard.renderID, ForgeBoard.settingsID],
            "a fresh board is the renderer, the render and the settings")
        expect(board.begin() == .configure, "with nothing to render on, the board asks for a machine")
        expect(board.renderCall == ForgeSetup.title, "and says that is what the button does")
        expect(
            board.sections.first?.detail == Localized.text("Find it on your tailnet, or type its address"),
            "a forge with no renderer names both ways to get one rather than sitting blank")
        if let index = board.rows.firstIndex(where: { $0.kind == .field(.endpoint) }) {
            board.focus(index)
            expect(
                board.activate() == .configure,
                "and pressing the renderer row opens the setup rather than a text field")
        } else {
            failures.append("the renderer is a row")
        }
        expect(ForgeField.endpoint.opensSetup, "which is the one field that is a surface")
        expect(
            ForgeField.allCases.filter(\.opensSetup) == [.endpoint],
            "and the only one")
        board.point(at: arch)
        expect(board.begin() == .edit(.prompt), "with a machine but no words, it asks for words")
        board.describe("a cat asleep on a warm roof")
        expect(board.canRender, "with both, it can render")
        let asked = board.begin()
        expect(asked == .render(board.recipe), "and pressing it renders exactly what is on the board")
        expect(board.renderCall == Localized.text("Render"), "which is what the button says")
        board.reached(.timedOut)
        expect(
            board.rows.first?.detail == ForgeEndpoint.sentence(for: .timedOut, host: "arch"),
            "a machine that did not answer says so on its own row")
        board.reached(.listening)
        expect(board.rows.first?.badge == Localized.text("up"), "and one that did wears a word")
        expect(board.sections.first?.detail.isEmpty == true, "a renderer that exists needs no invitation")

        if let index = board.rows.firstIndex(where: { $0.kind == .field(.size) }) {
            board.focus(index)
            let before = board.recipe.size
            expect(board.activate() == nil, "walking a setting is a step, not an outcome")
            expect(board.recipe.size != before, "and the setting actually moved")
            expect(board.recipe.width % ForgeRecipe.block == 0, "onto a size the model can take")
        } else {
            failures.append("the frame size is a row")
        }
        if let index = board.rows.firstIndex(where: { $0.kind == .field(.prompt) }) {
            board.focus(index)
            expect(board.activate() == .edit(.prompt), "words are the client's field to open")
        } else {
            failures.append("the prompt is a row")
        }
        let seedBefore = board.recipe.seed
        _ = board.handle(.reroll)
        expect(board.recipe.seed != seedBefore, "a re-roll never hands back the seed that was there")

        var running = ForgeJob(recipe: board.recipe)
        running.submitting()
        running.accepted(promptID: "p")
        running.saw(.progressed("p", census: ForgeCensus(finished: 14, total: 28, running: "pass2")))
        board.saw(running)
        expect(!board.canRender, "a board with a render in flight starts no second one")
        expect(board.rows.first(where: { $0.kind == .field(.size) })?.isActivatable == false,
            "and the settings the render already consumed are out of reach")
        expect(board.rows.first(where: { $0.kind == .job })?.fraction == 0.5, "the render row carries the bar")
        expect(board.begin() == .cancel, "pressing the render row stops it")
        expect(board.handle(.cancel).action == .cancel, "and so does the chord")
        expect(board.renderCall == Localized.text("Stop"), "which is what the button says")
        running.delivered(asset)
        board.saw(running)
        expect(board.begin() == .play(asset), "a finished render plays")
        expect(board.renderCall == Localized.text("Play"), "and says so")
        expect(board.handle(.cancel).handled == false, "there is nothing left to stop")

        board.filled(history: [])
        expect(
            board.rows.contains { $0.kind == .note && $0.title == Localized.text("Nothing rendered yet") },
            "an empty history says it is empty rather than vanishing")
        if let note = board.rows.firstIndex(where: { $0.kind == .note }) {
            board.focus(note)
            expect(board.cursor != note, "and the cursor does not stop on it")
        }

        let clips = (0..<7).map { index in
            ForgeEntry(
                id: "job\(index)", recipe: recipe.with(seed: index),
                asset: ForgeAsset(filename: "clip\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        board.filled(history: clips)
        let kept = board.sections.first { $0.id == ForgeBoard.historyID }
        expect(kept?.rows.count == ForgeBoard.compactLimit + 1, "a long history is compacted")
        expect(kept?.hidden == 3, "and says how many it is holding")
        expect(kept?.rows.last?.kind == .expander(ForgeBoard.historyID), "behind one row")
        if let index = board.rows.firstIndex(where: { $0.kind == .expander(ForgeBoard.historyID) }) {
            board.focus(index)
            expect(board.activate() == nil, "expanding is a step")
            expect(
                board.sections.first { $0.id == ForgeBoard.historyID }?.rows.count == 8,
                "and the rest come out")
            expect(board.back(), "escape closes what was opened")
            expect(
                board.sections.first { $0.id == ForgeBoard.historyID }?.hidden == 3,
                "and the history is compact again")
        } else {
            failures.append("the expander is a row")
        }
        if let index = board.rows.firstIndex(where: { $0.entry?.id == "job2" }) {
            board.focus(index)
            expect(board.activate() == .play(ForgeAsset(filename: "clip2.mp4", subfolder: "video")),
                "a kept clip plays")
        } else {
            failures.append("a kept clip is a row")
        }
        board.reuse(clips[3])
        expect(board.recipe.seed == 3, "and its settings come back to the draft")

        var burntBoard = ForgeBoard(endpoint: arch)
        burntBoard.describe("a cat")
        burntBoard.saw(burnt)
        expect(
            burntBoard.rows.contains { $0.kind == .job && $0.detail == "out of memory" },
            "a render that failed says why on the board rather than going quiet")

        let clip = ForgeEntry(id: "j", recipe: recipe, asset: nil, failure: "out of memory")
        expect(clip.badge == Localized.text("failed"), "a clip that never arrived says so")
        expect(clip.detail == "out of memory", "and keeps the reason")
        expect(!clip.isPlayable, "and cannot be played")
        expect(ForgeEntry(job: ForgeJob(recipe: recipe)) == nil, "a draft is not history")

        let commands: [(UInt32, UInt32, ForgeCommand?)] = [
            (Keymap.up, 0, .up),
            (Keymap.down, 0, .down),
            (Keymap.enter, 0, .activate),
            (Keymap.tab, 0, .expand),
            (Keymap.escape, 0, .back),
            (UInt32(UnicodeScalar("g").value), Keymap.control, .render),
            (UInt32(UnicodeScalar("c").value), Keymap.control, .cancel),
            (UInt32(UnicodeScalar("r").value), Keymap.control, .reroll),
            (UInt32(UnicodeScalar("g").value), 0, nil),
            (UInt32(UnicodeScalar("5").value), 0, nil),
            (UInt32(UnicodeScalar("a").value), 0, nil),
        ]
        for (keyval, state, expected) in commands {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(ForgeBoard.command(for: chord) == expected, "key \(keyval)/\(state)")
        }
        return failures
    }
}
