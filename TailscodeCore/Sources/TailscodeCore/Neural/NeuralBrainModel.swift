import CodingAgentKit
import Foundation

/// What the conversation says about a brain besides the turn's own steps: what the machine is
/// doing now, how full the window is, whether a call is open, and who is answering. The turn that
/// is live carries the conversation's activity; an older turn carries none.
public struct NeuralBrainContext: Sendable, Equatable {
    public var activity: ActivityKind?
    public var fill: ContextFill?
    public var call: VoiceCallFace?
    /// A ready face, for a client that already holds the composer's dial. Nil reads the face from
    /// the turn's own model and effort.
    public var face: NeuralFace?
    public var providerID: String?
    /// The levels the answering model lists, which place an effort word the table has not met.
    public var effortOptions: [String]

    public init(
        activity: ActivityKind? = nil, fill: ContextFill? = nil, call: VoiceCallFace? = nil,
        face: NeuralFace? = nil, providerID: String? = nil, effortOptions: [String] = []
    ) {
        self.activity = activity
        self.fill = fill
        self.call = call
        self.face = face
        self.providerID = providerID
        self.effortOptions = effortOptions
    }

    /// From the facts the chat's status line already holds.
    public init(
        facts: StatusFacts, call: VoiceCallFace? = nil, face: NeuralFace? = nil,
        providerID: String? = nil, effortOptions: [String] = []
    ) {
        self.init(
            activity: facts.activity, fill: facts.context, call: call, face: face,
            providerID: providerID, effortOptions: effortOptions)
    }

    public static let none = NeuralBrainContext()
}

/// How often a client should draw a brain: never, at the activity tempo, or at the display's rate.
public enum NeuralTempo: Sendable, Equatable {
    case stopped
    case activity
    case display
}

/// The one line under an open brain: what the active step is, and where it stands in the turn.
public struct NeuralTicker: Sendable, Equatable {
    public let stepID: String
    public let zone: NeuralZone
    public let status: NeuralStatus
    /// The tool's name, or "Thinking" or "Said".
    public let title: String
    /// The argument or the words, on one line and shortened.
    public let detail: String
    /// The title and the detail as the line reads.
    public let text: String
    public let statusWord: String
    /// "step 6 of 29".
    public let counter: String
    /// One-based.
    public let number: Int
    public let total: Int
}

/// Everything a client needs to draw and answer one brain except pixels: the layout, the state the
/// head wears, which node is hovered or pinned and what that lights, which answer word is being
/// pointed at, and where a replay is. The clients keep one per open turn, call `update` with the
/// turn each time the transcript is rebuilt, and read what they draw.
///
/// `update` does its work only when the turn's steps changed in a way a layout reads (a step
/// arrived, changed status, tie key or arguments); a streamed word of a thought or an answer
/// costs a fingerprint pass over the steps and nothing else. Time is whatever monotonic clock the
/// client already draws from, in seconds, and the same one is passed to `startReplay`.
public struct NeuralBrainModel: Sendable {
    public enum Mode: Sendable, Equatable {
        case live
        case replaying(start: Double)
        case scrubbing(fraction: Double)
    }

    enum Role: Sendable, Equatable {
        case solo
        case leader(members: Int)
        case member
    }

    struct Replay: Sendable {
        let timeline: NeuralTimeline
        let fire: [TimeInterval]

        init(steps: [NeuralStep], ganglia: [NeuralLayout.Ganglion], indexByID: [String: Int]) {
            let made = NeuralTimeline.make(steps: steps)
            var fire = made.fireTimes
            for ganglion in ganglia {
                let indices = ganglion.members.compactMap { indexByID[$0] }
                guard let earliest = indices.map({ fire[$0] }).min() else { continue }
                for index in indices { fire[index] = earliest }
            }
            timeline = made
            self.fire = fire
        }
    }

    public private(set) var turn: NeuralTurn
    public private(set) var context: NeuralBrainContext
    public private(set) var layout: NeuralLayout
    public private(set) var state: NeuralState
    public private(set) var face: NeuralFace
    public private(set) var meters: NeuralMeters
    public private(set) var mode: Mode = .live
    /// Counts the changes a layout reads; a client keys what it memoises on it.
    public private(set) var revision: Int = 0
    public private(set) var hovered: String?
    public private(set) var pinned: String?
    public private(set) var hotSteps: [String] = []
    public private(set) var hotRoutes: [NeuralLayout.Route] = []
    public private(set) var provenanceToken: String?
    public private(set) var provenanceSteps: Set<String> = []
    public private(set) var provenanceZones: Set<NeuralZone>?
    /// The client's dive into a node is running; it asks for the display's rate while it does.
    public private(set) var isDiving = false

    var roles: [Role] = []
    var indexByID: [String: Int] = [:]
    var ganglionMembers: [String: [String]] = [:]
    var groupStarts: [Int] = []
    var hotSet: Set<String> = []
    var hotEdges: Set<NeuralLayout.Edge> = []
    var selectionClass: Set<String> = []
    var visibleNodeCount = 0
    var hasAnimatedNode = false
    var replay: Replay?

    private var fingerprints: [Int] = []
    private var waitingZone: NeuralZone?
    private var failureZone: NeuralZone?

    public init(turn: NeuralTurn, context: NeuralBrainContext = .none) {
        self.turn = turn
        self.context = context
        layout = NeuralLayout()
        state = .idle
        face = .unknown
        meters = .none
        _ = syncFingerprints()
        layout.sync(turn.steps)
        refreshStructure()
        face = Self.makeFace(for: turn, context: context)
        meters = NeuralMeters(fill: context.fill, call: context.call)
        refreshState()
    }

    /// Brings the model to the turn as the transcript now has it.
    public mutating func update(turn newTurn: NeuralTurn, context newContext: NeuralBrainContext) {
        let old = turn
        let oldContext = context
        turn = newTurn
        context = newContext
        let structural = syncFingerprints()
        if structural {
            layout.sync(newTurn.steps)
            revision += 1
            refreshStructure()
            if mode != .live { replay = makeReplay() } else { replay = nil }
            refreshProvenance()
        }
        let identityChanged =
            old.modelID != newTurn.modelID || old.effort != newTurn.effort
            || oldContext.face != newContext.face || oldContext.providerID != newContext.providerID
            || oldContext.effortOptions != newContext.effortOptions
        if identityChanged { face = Self.makeFace(for: newTurn, context: newContext) }
        if oldContext.fill != newContext.fill || oldContext.call != newContext.call {
            meters = NeuralMeters(fill: newContext.fill, call: newContext.call)
        }
        if !structural && old.outcome != newTurn.outcome { refreshAttention() }
        refreshState()
    }

    public var steps: [NeuralStep] { turn.steps }

    /// Whether this turn is a brain at all.
    public var isBrain: Bool { NeuralOpenPolicy.isBrain(turn: turn) }

    public func step(id: String) -> NeuralStep? { indexByID[id].map { turn.steps[$0] } }

    /// Where a step is drawn, in design space; a ganglion's members share its leader's point.
    public func point(of id: String) -> NeuralPoint? { layout.placements[id] }

    /// How many nodes are drawn: a ganglion is one.
    public var nodeCount: Int { visibleNodeCount }

    /// Past this many nodes the Apple clients draw them as instanced shapes instead of layers.
    public var useInstancedNodes: Bool { visibleNodeCount > NeuralNodes.instancingThreshold }


    /// The node the pointer rests on; a pinned node outranks it.
    public var selected: String? { pinned ?? hovered }

    public var hasSelection: Bool { selected != nil }

    public var selectedZone: NeuralZone? {
        selected.flatMap { indexByID[$0] }.map { turn.steps[$0].zone }
    }

    /// Hovers a node, or nothing for nil. A member of a ganglion hovers its leader, and an id the
    /// turn does not hold hovers nothing.
    public mutating func setHover(_ id: String?) {
        hovered = id.flatMap(representative)
        refreshSelection()
    }

    /// Pins a node, or lets go of it when it is the one pinned.
    public mutating func togglePin(_ id: String) {
        guard let node = representative(id) else { return }
        pinned = pinned == node ? nil : node
        refreshSelection()
    }

    public mutating func clearSelection() {
        hovered = nil
        pinned = nil
        refreshSelection()
    }

    /// The node under a point of the design space, within a node's radius and `slop` of its
    /// centre; the nearest wins, a ganglion's member resolves to its leader, and a point no node
    /// reaches answers nil.
    public func hit(at point: NeuralPoint, slop: Double = 0) -> String? {
        let extra = max(0, slop)
        var best: (index: Int, distance: Double)?
        for (index, step) in turn.steps.enumerated() {
            let radius: Double
            switch roles[index] {
            case .member: continue
            case .solo: radius = NeuralDesign.nodeRadius
            case .leader: radius = NeuralDesign.nodeRadius * NeuralNodes.ganglionScale
            }
            guard let center = layout.placements[step.id] else { continue }
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = dx * dx + dy * dy
            let reach = radius + extra
            guard distance <= reach * reach else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let found = best else { return nil }
        let step = turn.steps[found.index]
        guard let center = layout.placements[step.id], isInsideHead(center, zone: step.zone) else {
            return nil
        }
        return step.id
    }

    /// The words of the selected node's card: a ganglion's own card for a ganglion.
    public var card: NeuralReading.Card? {
        guard let id = selected, let index = indexByID[id] else { return nil }
        if case .leader = roles[index], let members = ganglionMembers[id] {
            let steps = members.compactMap { indexByID[$0] }.map { turn.steps[$0] }
            return NeuralReading.ganglion(zone: turn.steps[index].zone, members: steps)
        }
        return NeuralReading.card(for: turn.steps[index], in: turn.steps)
    }

    /// The steps a node stands for: its ganglion's members, or itself.
    public func members(of id: String) -> [String] {
        guard let node = representative(id) else { return [] }
        return ganglionMembers[node] ?? [node]
    }


    /// Points at one literal word of the answer, or lets go of it for nil. The steps that carry
    /// the word light, and the zones they sit in; a word no step carries lights nothing.
    public mutating func setProvenance(token: String?) {
        provenanceToken = token.flatMap { $0.isEmpty ? nil : $0 }
        refreshProvenance()
    }

    /// Whether an answer word is lighting anything.
    public var isProvenanceActive: Bool { !provenanceSteps.isEmpty }

    /// The path-like words of an answer that at least one step carries literally, which are the
    /// only ones worth underlining.
    public func answerTokens(in text: String) -> [NeuralProvenance.Token] {
        NeuralProvenance.tokens(in: text).filter { token in
            turn.steps.contains { step in
                step.detail.contains(token.text)
                    || step.outputLines.contains { $0.contains(token.text) }
            }
        }
    }


    /// The replay's own length and the second each step fires at.
    public var timeline: NeuralTimeline { (replay ?? makeReplay()).timeline }

    public var isReplaying: Bool { mode != .live }

    /// Plays the turn from its first step, `now` being the client's clock at this moment.
    public mutating func startReplay(now: Double) {
        replay = makeReplay()
        mode = .replaying(start: now)
    }

    /// Ends a replay or a scrub and shows the turn as it stands.
    public mutating func stopReplay() {
        mode = .live
        replay = nil
    }

    /// Puts the playhead at a fraction of the replay.
    public mutating func scrub(to fraction: Double) {
        if replay == nil { replay = makeReplay() }
        mode = .scrubbing(fraction: min(max(fraction, 0), 1))
    }

    /// Lifts the finger from the scrubber: at the end the turn is shown as it stands, anywhere
    /// else the playhead stays.
    public mutating func endScrub() {
        if case .scrubbing(let fraction) = mode, fraction >= NeuralBrainModel.scrubEnd {
            stopReplay()
        }
    }

    /// The fraction of the replay that scrubbing counts as having reached its end.
    public static let scrubEnd = 0.995

    /// Where the playhead is, in replay seconds; nil when the turn is not being replayed.
    public func replayTime(now: Double) -> TimeInterval? {
        switch mode {
        case .live: return nil
        case .replaying(let start):
            return min(max(now - start, 0), timeline.duration)
        case .scrubbing(let fraction): return timeline.time(forFraction: fraction)
        }
    }

    /// Where the playhead is, from nothing to one; nil when the turn is not being replayed.
    public func replayFraction(now: Double) -> Double? {
        replayTime(now: now).map { timeline.fraction(forTime: $0) }
    }

    /// Whether a replay that is playing has reached its end and the client should stop it.
    public func replayDone(now: Double) -> Bool {
        guard case .replaying(let start) = mode else { return false }
        return now >= start + timeline.duration
    }


    public mutating func setDiving(_ diving: Bool) { isDiving = diving }


    /// The one line under an open brain while the turn is being written: the latest step. A replay
    /// that is playing needs `ticker(now:)`, because only the clock knows where its playhead is.
    public var ticker: NeuralTicker? { ticker(now: 0) }

    /// The ticker at `now`: while the turn is being written its latest step; during a replay the
    /// last step that has fired; nothing for a turn at rest.
    public func ticker(now: Double) -> NeuralTicker? {
        let index: Int?
        switch mode {
        case .live:
            index = turn.outcome == .running && !turn.steps.isEmpty ? turn.steps.count - 1 : nil
        case .replaying, .scrubbing:
            index = replayTime(now: now).flatMap { timeline.activeStep(at: $0) }
        }
        return index.map(makeTicker)
    }

    /// What a collapsed turn says beside its glyph.
    public func line(now: Date = Date()) -> NeuralReading.Line { NeuralReading.line(for: turn, now: now) }

    public var line: NeuralReading.Line { line(now: Date()) }

    /// The sentence a screen reader says for the whole turn.
    public func spoken(now: Date = Date()) -> String { NeuralReading.spoken(turn, now: now) }

    public var spoken: String { spoken(now: Date()) }

    /// The head as data for the 28 to 46 pt glyph: the eye wears the state's tone and the lit zone
    /// carries a ring.
    public var glyph: NeuralGlyph { glyph(dim: false) }

    /// `dim` is a glyph in a row that is not the turn being looked at.
    public func glyph(dim: Bool) -> NeuralGlyph {
        NeuralGlyph(
            steps: turn.steps, eyeTone: state.tone, activeZone: state.zone,
            live: turn.outcome == .running, dim: dim)
    }


    /// Every number a renderer reads for this instant: the state (the turn's own, or the replay's
    /// working state at the playhead), the face and meters, the zone of the selected node as the
    /// hover, and the zones an answer word points at.
    public func frame(time: Double, reduceMotion: Bool) -> NeuralFrame {
        NeuralFrame.at(
            time: time, state: shownState(now: time), face: face, meters: meters,
            reduceMotion: reduceMotion, hover: selectedZone, provenance: provenanceZones)
    }

    /// Whether anything on screen will change by itself: the frame, a node, a replay or a dive.
    /// A settled turn answers false and the client stops its tick.
    public var needsClock: Bool { needsClock(reduceMotion: false) }

    public func needsClock(reduceMotion: Bool) -> Bool {
        if isDiving { return true }
        if case .replaying = mode { return true }
        if shownState(now: 0).isAnimated(reduceMotion: reduceMotion) { return true }
        guard !reduceMotion else { return false }
        if let call = meters.call, call.motion.isAnimated { return true }
        return mode == .live && hasAnimatedNode
    }

    /// How often to draw: not at all at rest, at the activity tempo while something moves, at the
    /// display's rate for a dive or a scrub.
    public var tempo: NeuralTempo { tempo(reduceMotion: false) }

    public func tempo(reduceMotion: Bool) -> NeuralTempo {
        guard needsClock(reduceMotion: reduceMotion) else { return .stopped }
        if isDiving { return .display }
        if case .scrubbing = mode { return .display }
        return .activity
    }

    /// The state the head wears at `now`.
    public func shownState(now: Double) -> NeuralState {
        switch mode {
        case .live:
            return state
        case .replaying, .scrubbing:
            let time = replayTime(now: now) ?? 0
            let zone = timeline.activeStep(at: time).map { turn.steps[$0].zone } ?? .think
            return NeuralState.make(activity: Self.activity(replaying: zone))
        }
    }


    private func representative(_ id: String) -> String? {
        indexByID[id] == nil ? nil : layout.representative(of: id)
    }

    private func makeReplay() -> Replay {
        Replay(steps: turn.steps, ganglia: layout.ganglia, indexByID: indexByID)
    }

    private func isInsideHead(_ point: NeuralPoint, zone: NeuralZone) -> Bool {
        zone == .say
            ? NeuralDome.jawContains(point, margin: 0)
            : NeuralDome.contains(point, margin: NeuralDesign.nodeRadius)
    }

    private func makeTicker(_ index: Int) -> NeuralTicker {
        let step = turn.steps[index]
        let title = NeuralReading.title(of: step)
        let said = NeuralReading.isThought(step) || NeuralReading.isNote(step) ? step.text : step.detail
        let detail = Self.oneLine(said, limit: NeuralBrainModel.tickerLimit)
        return NeuralTicker(
            stepID: step.id, zone: step.zone, status: step.status, title: title, detail: detail,
            text: detail.isEmpty ? title : Localized.text("%1$@ %2$@", title, detail),
            statusWord: NeuralReading.statusWord(step.status),
            counter: Localized.text("step %1$lld of %2$lld", index + 1, turn.steps.count),
            number: index + 1, total: turn.steps.count)
    }

    /// The longest a ticker's detail runs before it is cut.
    public static let tickerLimit = 120

    private static func oneLine(_ text: String, limit: Int) -> String {
        var out = ""
        var pendingSpace = false
        var count = 0
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
            if count >= limit { break }
        }
        return String(out.prefix(limit))
    }

    /// The activity a replay shows at a step in `zone`: the head working there, in the table's own
    /// words, so a replay reads like the live turn it was.
    private static func activity(replaying zone: NeuralZone) -> ActivityKind {
        switch zone {
        case .think: return .thinking
        case .say: return .writing
        case .sense: return .usingTool(name: "", kind: .fileRead)
        case .act: return .usingTool(name: "", kind: .fileEdit)
        case .shell: return .usingTool(name: "", kind: .shell)
        case .delegate: return .delegating(active: 1)
        }
    }

    private static func makeFace(for turn: NeuralTurn, context: NeuralBrainContext) -> NeuralFace {
        context.face
            ?? NeuralFace(
                model: turn.modelID, providerID: context.providerID, effort: turn.effort,
                options: context.effortOptions)
    }

    private static func fingerprint(of step: NeuralStep) -> Int {
        var hasher = Hasher()
        hasher.combine(step.id)
        hasher.combine(step.status)
        hasher.combine(step.zone)
        hasher.combine(step.group)
        hasher.combine(step.tieKey)
        hasher.combine(step.detail.utf8.count)
        hasher.combine(step.outputLines.count)
        hasher.combine(step.recovered)
        hasher.combine(step.isCard)
        return hasher.finalize()
    }

    /// Reads the steps against what was last seen, in place, and says whether anything a layout
    /// reads has changed.
    private mutating func syncFingerprints() -> Bool {
        let steps = turn.steps
        var changed = steps.count != fingerprints.count
        if fingerprints.count > steps.count {
            fingerprints.removeLast(fingerprints.count - steps.count)
        }
        for (index, step) in steps.enumerated() {
            let stamp = Self.fingerprint(of: step)
            if index < fingerprints.count {
                if fingerprints[index] != stamp {
                    fingerprints[index] = stamp
                    changed = true
                }
            } else {
                fingerprints.append(stamp)
            }
        }
        return changed
    }

    private mutating func refreshStructure() {
        let steps = turn.steps
        indexByID = [:]
        indexByID.reserveCapacity(steps.count)
        groupStarts = []
        hasAnimatedNode = false
        for (index, step) in steps.enumerated() {
            indexByID[step.id] = index
            if index == 0 || steps[index - 1].group != step.group { groupStarts.append(index) }
            switch step.status {
            case .running, .waitingApproval, .waitingAnswer: hasAnimatedNode = true
            case .ok, .failed, .stopped, .stalled: break
            }
        }
        roles = Array(repeating: .solo, count: steps.count)
        ganglionMembers = [:]
        var hidden = 0
        for ganglion in layout.ganglia {
            ganglionMembers[ganglion.leader] = ganglion.members
            for (position, member) in ganglion.members.enumerated() {
                guard let index = indexByID[member] else { continue }
                if position == 0 {
                    roles[index] = .leader(members: ganglion.members.count)
                } else {
                    roles[index] = .member
                    hidden += 1
                }
            }
        }
        visibleNodeCount = steps.count - hidden
        refreshAttention()
        if let id = hovered, indexByID[id] == nil { hovered = nil }
        if let id = pinned, indexByID[id] == nil { pinned = nil }
        refreshSelection()
    }

    private mutating func refreshAttention() {
        let steps = turn.steps
        waitingZone = steps.first { step in
            switch step.status {
            case .waitingApproval, .waitingAnswer, .stalled: return true
            case .ok, .running, .failed, .stopped: return false
            }
        }?.zone
        failureZone =
            steps.last { $0.status == .failed && !$0.recovered }?.zone ?? steps.last?.zone
    }

    private mutating func refreshState() {
        let failing = turn.outcome == .failed || context.activity == .failed
        state = NeuralState.make(
            activity: context.activity, outcome: turn.outcome,
            waitingZone: waitingZone ?? (failing ? failureZone : nil))
    }

    private mutating func refreshSelection() {
        guard let id = selected, indexByID[id] != nil else {
            hotSteps = []
            hotRoutes = []
            hotSet = []
            hotEdges = []
            selectionClass = []
            return
        }
        hotSteps = layout.hotSet(for: id)
        hotRoutes = layout.hotRoutes(for: id)
        hotSet = Set(hotSteps)
        hotEdges = Set(hotRoutes.map(\.edge))
        selectionClass = Set(ganglionMembers[id] ?? [id])
    }

    private mutating func refreshProvenance() {
        guard let token = provenanceToken else {
            provenanceSteps = []
            provenanceZones = nil
            return
        }
        let ids = NeuralProvenance.steps(touching: token, in: turn.steps)
        provenanceSteps = Set(ids)
        provenanceZones = ids.isEmpty ? nil : Set(ids.compactMap { step(id: $0)?.zone })
    }
}
