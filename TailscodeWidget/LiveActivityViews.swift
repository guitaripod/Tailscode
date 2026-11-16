import SwiftUI
import TailscodeCore
import WidgetKit

extension ChatActivityAttributes.ContentState.Phase {
    /// The face an activity started by an older app process falls back to, spelled in the same
    /// vocabulary Core authors for these states.
    var fallback: LiveActivityFace {
        switch self {
        case .thinking: return LiveActivityFace(symbol: "brain", tone: .live)
        case .tool: return LiveActivityFace(symbol: "wrench.and.screwdriver", tone: .live)
        case .responding: return LiveActivityFace(symbol: "text.alignleft", tone: .live)
        case .approval: return LiveActivityFace(symbol: "hand.raised", tone: .attention)
        case .done: return LiveActivityFace(symbol: "checkmark.circle", tone: .live)
        case .error: return LiveActivityFace(symbol: "exclamationmark.triangle", tone: .danger)
        }
    }
}

extension ChatActivityAttributes.ContentState {
    /// Which thing the card is saying, when its sender named it — which every sender now does,
    /// the server included, so a push arriving while the phone slept reads in this phone's
    /// language rather than the server's.
    var reading: LiveActivityDetail? { detail.flatMap(LiveActivityDetail.init(rawValue:)) }

    /// The one short line a screen reader and the smallest presentations say.
    var line: String {
        guard let reading else { return statusText }
        return reading.line(
            tool: isSettled ? nil : lastTool, toolCount: toolCount, background: background ?? 0)
    }

    /// Stopped for the person — a live approval or a question the turn ended on. The island says
    /// so with the face rather than a clock, because a clock would read as work.
    var isWaitingOnYou: Bool { phase == .approval }
}

/// One card read once for every presentation that draws it: its face, its colours and its words.
/// Built from what the card shows rather than from the system's context so the in-app preview and
/// the Lock Screen draw the very same card.
struct CardModel {
    let state: ChatActivityAttributes.ContentState
    let title: String
    let server: String
    let inks: CardInks
    let look: LiveActivityLook
    let headline: String
    /// When the card was last seen to move, once it has been still long enough to say so.
    let quietSince: Date?
    /// A live card the platform called stale with no moment to count from: the old "waiting for
    /// updates" card a server from before the brief leaves.
    let unheard: Bool
    let seed: UInt64

    init(
        state: ChatActivityAttributes.ContentState, title: String, server: String, isStale: Bool,
        seedKey: String, inks: CardInks = .current
    ) {
        self.state = state
        self.title = state.title ?? title
        self.server = server
        self.inks = inks
        let live = !state.isSettled
        let moved = state.brief?.moved
        quietSince = live && isStale && !state.isWaitingOnYou ? moved : nil
        unheard = live && isStale && !state.isWaitingOnYou && moved == nil
        look = LiveActivityLook.read(
            detail: state.reading, settled: state.isSettled, background: state.background ?? 0,
            tool: state.lastTool, quietSince: quietSince, fallback: state.phase.fallback)
        headline = LiveActivityHeadline.line(
            detail: state.reading, statusText: state.statusText, brief: state.brief,
            tool: state.lastTool, toolCount: state.toolCount, background: state.background ?? 0,
            settled: state.isSettled)
        seed = Self.fnv(seedKey)
    }

    var ink: Color { unheard ? inks.dim : inks.ink(look) }
    var brief: LiveActivityBrief? { state.brief }
    var ultra: Bool { brief?.ultra == true }
    var isLive: Bool { !state.isSettled }

    /// Where the ground and the aura stand: moved on by every update a live card receives and held
    /// where the turn left it once it settles, so a settled card never moves.
    var phase: Double {
        let anchor = state.endedAt ?? brief?.moved ?? state.startedAt
        return anchor.timeIntervalSinceReferenceDate / 7
    }

    var meta: String {
        var parts = [server]
        if let model = brief?.modelWord { parts.append(model) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What the card says under its line, by priority: the ask, the agent's last words once it
    /// has finished, or nothing.
    var askLead: String? { LiveActivityHeadline.askLead(state.reading) }
    var ask: String? { askLead == nil ? nil : brief?.ask }
    var said: String? { state.isSettled ? brief?.said : nil }
    var counts: String? { brief?.countsLine(toolCount: state.toolCount) }

    /// The right of the card's foot: how full the context is while the turn runs, and once it has
    /// ended whatever its line has not already said — a finished line counts the tools and the
    /// files, so only the lines they changed are left.
    var footNote: String? {
        if isLive { return contextLine ?? counts }
        if state.reading == .finished { return brief?.linesChanged }
        return counts
    }

    var contextLine: String? {
        guard let fill = brief?.fill, isLive else { return nil }
        return Localized.text("%lld%% context", Int((fill * 100).rounded()))
    }

    func steps(_ limit: Int) -> [LiveActivityStep] {
        LiveActivityHeadline.listed(
            brief: brief, detail: state.reading, settled: state.isSettled, limit: limit)
    }

    var accessibilitySummary: String {
        [title, look.word, headline].joined(separator: ", ")
    }

    /// A stable seed per conversation: Swift's own hash is salted per process, and the motes must
    /// sit in the same places on every redraw.
    private static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// The card on the Lock Screen, in the size the person chose, drawn the way a wall tile is.
struct LockScreenCard: View {
    let model: CardModel
    let size: LiveActivitySize
    /// Draws the wall's ground whatever the environment says: the app's own previews are not on a
    /// Lock Screen, and there is no container behind them to say so.
    var drawsGround = false

    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.isLuminanceReduced) private var reduced

    static let corner: CGFloat = 22
    static let margin: CGFloat = 14
    static let largeHeight: CGFloat = 160
    /// The vertical margin of the compact and large cards: the compact one is a single row, and
    /// the large one spends every point it can on the tile.
    static let largeMargin: CGFloat = 12

    var body: some View {
        content
            .padding(.horizontal, Self.margin)
            .padding(.vertical, size == .standard ? Self.margin : Self.largeMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if showsBackground || drawsGround {
                    CardGround(
                        inks: model.inks, ink: model.ink, phase: model.phase, seed: model.seed,
                        live: model.isLive)
                }
            }
            .overlay {
                if model.ultra { CardAura(turn: model.phase * 2, corner: Self.corner) }
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch size {
        case .compact: CompactCard(model: model)
        case .standard: StandardCard(model: model)
        case .large:
            ViewThatFits(in: .vertical) {
                ForEach(0..<LargeCard.levels, id: \.self) { level in
                    LargeCard(model: model, level: level)
                }
                StandardCard(model: model)
            }
            .frame(height: Self.largeHeight - Self.largeMargin * 2, alignment: .top)
            .mask { Self.foot }
        }
    }

    /// Cuts only what a level spills below the tile's foot: the orb's rainbow and glow reach past
    /// its frame into the margins, and a plain clip would shave them off the side and the top.
    private static var foot: some View {
        Rectangle()
            .padding(EdgeInsets(top: -largeMargin, leading: -margin, bottom: 0, trailing: -margin))
    }
}

/// One slim row: the orb, the conversation and its line, and the clock.
struct CompactCard: View {
    let model: CardModel

    var body: some View {
        HStack(spacing: 12) {
            CardOrb(model: model, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.inks.text)
                    .lineLimit(1)
                CardHeadline(model: model, font: .footnote.weight(.medium), lines: 1, tinted: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                CardClock(model: model, font: .footnote.weight(.semibold))
                CardWord(model: model)
                    .font(.caption2)
            }
        }
    }
}

/// The line in large type, who answers, and the turn's pulse.
struct StandardCard: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(model: model, orb: 36)
            CardHeadline(model: model, font: .title3.weight(.semibold), lines: 2, tinted: false)
            if let ask = model.ask {
                Text(ask)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(model.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            CardFoot(model: model)
        }
    }
}

/// The whole tile: the line, then what it waits on, how it ended, or its plan and latest steps,
/// over its pulse. `level` is how much it gives up to fit the platform's 160 points: none at 0,
/// then a step at a time, the plan, and the ask's and the last words' lines.
struct LargeCard: View {
    let model: CardModel
    let level: Int

    static let levels = 7

    private var steps: Int { max(0, 3 - level) }
    private var plan: Bool { level < 4 }
    private var askLines: Int { max(1, 4 - level) }
    private var saidLines: Int { level < 3 ? 3 : (level < 5 ? 2 : 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CardHeader(model: model, orb: 32)
            CardHeadline(model: model, font: .title3.weight(.semibold), lines: 2, tinted: false)
            VStack(alignment: .leading, spacing: 4) {
                if let lead = model.askLead, let ask = model.ask {
                    CardAsk(lead: lead, ask: ask, ink: model.ink, lines: askLines)
                } else if model.state.isSettled {
                    CardEnding(model: model, lines: saidLines)
                } else {
                    if plan, let board = model.brief?.plan {
                        CardPlan(plan: board, ink: model.ink, inks: model.inks)
                    }
                    CardSteps(steps: model.steps(steps), inks: model.inks, ink: model.ink)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            CardFoot(model: model, saysWords: false)
        }
    }
}

/// The orb, the conversation's name, the word for its state with the machine and the model, and
/// the clock.
struct CardHeader: View {
    let model: CardModel
    let orb: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CardOrb(model: model, size: orb)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.inks.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    CardWord(model: model)
                    if !model.meta.isEmpty {
                        Text("·").foregroundStyle(model.inks.dim)
                        Text(model.meta).foregroundStyle(model.inks.dim).lineLimit(1)
                    }
                }
                .font(.caption2)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                CardClock(model: model, font: .callout.weight(.semibold))
                if let endedAt = model.state.endedAt {
                    EndedAgo(endedAt: endedAt)
                        .font(.caption2)
                        .foregroundStyle(model.inks.dim)
                }
            }
        }
    }
}

/// The wall's word for the card's state, in its ink; a turn waiting on the person and a card that
/// has heard nothing count how long beside it.
struct CardWord: View {
    let model: CardModel

    var body: some View {
        Group {
            if model.unheard {
                Text(String(localized: "Waiting for updates…"))
            } else if let since = model.quietSince ?? (model.state.isWaitingOnYou ? model.brief?.moved : nil) {
                HStack(spacing: 4) {
                    Text(model.look.word)
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .fixedSize()
                }
            } else {
                Text(model.look.word)
            }
        }
        .foregroundStyle(model.ink)
        .monospacedDigit()
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// The card's line. A new line pushes the old one up, the wall's step landing.
struct CardHeadline: View {
    let model: CardModel
    let font: Font
    let lines: Int
    let tinted: Bool

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(model.headline)
            .font(font)
            .foregroundStyle(tinted ? model.ink : model.inks.text)
            .lineLimit(lines)
            .minimumScaleFactor(0.8)
            .id(model.headline)
            .transition(.push(from: .bottom))
            .animation(CardMotion.spring(reduced), value: model.headline)
    }
}

/// The turn's clock: running while it works, stopped where it stopped once it ended.
struct CardClock: View {
    let model: CardModel
    let font: Font

    var body: some View {
        Group {
            if let endedAt = model.state.endedAt {
                FrozenClock(startedAt: model.state.startedAt, endedAt: endedAt)
                    .foregroundStyle(model.ink)
            } else {
                Text(timerInterval: model.state.startedAt...Date.distantFuture, countsDown: false)
                    .foregroundStyle(model.inks.text.opacity(0.85))
            }
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 64, alignment: .trailing)
    }
}

/// What a turn waits on, whole as far as the card has room: the command in the wall's monospaced
/// type under its small-capitals lead.
struct CardAsk: View {
    let lead: String
    let ask: String
    let ink: Color
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lead.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(ink)
            Text(ask)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(lines)
                .truncationMode(.middle)
        }
    }
}

/// How the turn ended, past its line: what the agent said last, or the steps it ended on when it
/// said nothing.
struct CardEnding: View {
    let model: CardModel
    var lines = 2

    var body: some View {
        if let said = model.said {
            Text("\u{201C}\(said)\u{201D}")
                .font(.footnote)
                .foregroundStyle(model.inks.text.opacity(0.82))
                .lineLimit(lines)
        } else {
            CardSteps(steps: model.steps(max(lines - 1, 1)), inks: model.inks, ink: model.ink)
        }
    }
}

/// The agent's plan: how far through as a bar, and the item in hand.
struct CardPlan: View {
    let plan: LiveActivityPlan
    let ink: Color
    let inks: CardInks

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        HStack(spacing: 8) {
            Text(plan.headline)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(inks.text.opacity(0.9))
                .contentTransition(.numericText())
                .fixedSize()
            FiniteGeometry { size in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.18))
                    Capsule()
                        .fill(ink)
                        .frame(width: max(4, size.width * plan.fraction))
                }
            }
            .frame(width: 44, height: 4)
            .animation(CardMotion.spring(reduced), value: plan.fraction)
            if let current = plan.current {
                Text("▸ \(current)")
                    .font(.caption2)
                    .foregroundStyle(inks.text.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }
}

/// The latest steps under the line, newest first and fading with age, each with the wall's mark:
/// a check for one that came back, a cross for one that failed, a dot for one still out.
struct CardSteps: View {
    let steps: [LiveActivityStep]
    let inks: CardInks
    let ink: Color

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 5) {
                    Image(systemName: Self.symbol(step.state))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(step.state == .failed ? inks.failed : ink)
                        .frame(width: 10)
                    Text(step.words)
                        .font(.caption)
                        .foregroundStyle(inks.text)
                        .lineLimit(1)
                }
                .opacity(1 - Double(index) * 0.22)
                .transition(.push(from: .top))
            }
        }
        .animation(CardMotion.spring(reduced), value: steps.map(\.id))
    }

    static func symbol(_ state: LiveActivityStep.State) -> String {
        switch state {
        case .running: return "circle.fill"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .stopped: return "stop.fill"
        }
    }
}

/// The card's foot: the pulse on the left — or, on a card with no room above for them, the agent's
/// last words — and the counts or how full the context is on the right.
struct CardFoot: View {
    let model: CardModel
    var saysWords = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.isLive, !model.state.isWaitingOnYou, let beats = model.brief?.beats, !beats.isEmpty {
                CardBeat(beats: model.quietSince == nil ? beats : beats.map { _ in 0 }, ink: model.ink, height: 12)
            } else if saysWords, let said = model.said {
                Text("\u{201C}\(said)\u{201D}")
                    .font(.caption2)
                    .foregroundStyle(model.inks.text.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let right = model.footNote {
                Text(right)
                    .font(.caption2)
                    .foregroundStyle(model.inks.dim)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// How long ago the turn ended, in the reader's language and kept current by the system — the
/// line a card that has been waiting to be read owes whoever finally reads it.
struct EndedAgo: View {
    let endedAt: Date

    var body: some View {
        Text(
            .currentDate,
            format: .reference(to: endedAt, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)
        )
        .lineLimit(1)
    }
}

/// The turn's clock, stopped where the turn stopped.
struct FrozenClock: View {
    let startedAt: Date
    let endedAt: Date

    var body: some View {
        Text(
            timerInterval: startedAt...max(startedAt, endedAt),
            pauseTime: max(startedAt, endedAt),
            countsDown: false
        )
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }
}
