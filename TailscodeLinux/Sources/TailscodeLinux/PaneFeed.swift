import CodingAgentKit
import Foundation
import TailscodeCore

/// What a pane's row build needs besides the state, captured on the main loop whenever it changes
/// so the build never reads the pane from another thread.
struct PaneBuildContext: Sendable {
    var generation: UInt64 = 0
    var tail = 300
    var profileID = ""
    var sessionModel: String?
    var models: [ModelInfo] = []
}

/// One state with its rows and its context fill, built off the main loop for one conversation of
/// one pane, numbered by the conversation it was built for.
struct PaneBuilt: Sendable {
    let generation: UInt64
    let state: ConversationState
    let rows: [TranscriptRow]
    let fill: ContextFill?
}

/// The road a conversation state takes from the hub to a pane's widgets without a main-loop post
/// per state.
///
/// The hub's lease fires `pull` once per clean-to-dirty transition on its stream task; `pull`
/// takes the newest frame and offers it to a single-flight pump, which builds rows off the main
/// loop — latest input only, one build in flight — and posts the result into a latest-wins slot.
/// The window's drain reads that slot between frames. At every stage the depth is one: a state
/// overtaken before it was built is never built, one built and overtaken before it was applied is
/// never applied, and the newest — a turn's ending included — is always the last one delivered.
final class PaneFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: LiveLease?
    private var pump: SingleFlightPump<PaneBuildInput, PaneBuilt>?
    private var context = PaneBuildContext()
    private let built = LatestWins<PaneBuilt>()

    struct PaneBuildInput: Sendable {
        let state: ConversationState
        let context: PaneBuildContext
    }

    private static let tracing =
        ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"] != nil && !Soak.isOn

    /// Connects a lease to a fresh pump that builds with `builder` and wakes `drain` when a build
    /// lands. Whatever an earlier connection had built is dropped.
    func attach(lease: LiveLease, builder: TranscriptRowBuilder, drain: TileDrain) {
        let built = self.built
        let pump = SingleFlightPump<PaneBuildInput, PaneBuilt>(
            work: { input in Self.build(input, with: builder) },
            deliver: { [weak drain] result in
                if built.post(result) { drain?.wake() }
            })
        lock.lock()
        self.lease = lease
        self.pump?.cancel()
        self.pump = pump
        lock.unlock()
        _ = built.take()
    }

    /// Lets go of the lease and the pump; a build still running is never delivered.
    func detach() {
        lock.lock()
        let pump = self.pump
        self.pump = nil
        lease = nil
        lock.unlock()
        pump?.cancel()
        _ = built.take()
    }

    /// The lease's dirty signal: the newest frame, offered to the pump. O(1) on any thread.
    func pull() {
        lock.lock()
        let lease = self.lease
        let pump = self.pump
        let context = self.context
        lock.unlock()
        guard let pump, let frame = lease?.take() else { return }
        pump.offer(PaneBuildInput(state: frame.state, context: context))
    }

    /// Builds a state the pane already has again — a theme, a wider window of history — through
    /// the same pump, so a rebuild can never race the stream's own builds.
    func rebuild(_ state: ConversationState) {
        lock.lock()
        let pump = self.pump
        let context = self.context
        lock.unlock()
        pump?.offer(PaneBuildInput(state: state, context: context))
    }

    func update(_ change: (inout PaneBuildContext) -> Void) {
        lock.lock()
        change(&context)
        lock.unlock()
    }

    var hasBuilt: Bool { built.isDirty }

    func takeBuilt() -> PaneBuilt? { built.take() }

    private static func build(_ input: PaneBuildInput, with builder: TranscriptRowBuilder)
        -> PaneBuilt
    {
        let state = input.state
        let context = input.context
        let messages =
            state.messages.count > context.tail
            ? Array(state.messages.suffix(context.tail)) : state.messages
        let started = Date()
        let profileID = context.profileID
        let rows = builder.rows(
            for: messages, turnOpen: state.status == .running,
            modelName: { selection in
                ModelCatalogStore.cached(profileID).first { $0.selection == selection }?.name
            })
        if tracing {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            FileHandle.standardOutput.write(
                Data("BUILD \(messages.count) messages -> \(rows.count) rows in \(ms)ms\n".utf8))
        }
        let fill = ContextFill.read(
            messages: state.messages, sessionModel: context.sessionModel,
            catalog: context.models)
        return PaneBuilt(
            generation: context.generation, state: state, rows: rows, fill: fill)
    }
}
