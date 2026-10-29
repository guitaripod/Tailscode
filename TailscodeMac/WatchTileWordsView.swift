import AppKit
import CodingAgentKit
import TailscodeCore

/// What every words view on the wall is set against: the wall's colours, the faces its unit gives and
/// the style the person chose.
struct WatchFace {
    var palette: WallPalette
    var type: WatchType
    var style: WallStyle
}

/// The words of one tile, in a view the size of the tile's own rectangle: the title and the one plain
/// word for its state, what it is doing in up to three lines, the whole command in monospace when
/// Core gives one, the last steps said in the past tense, the context share beside the heartbeat, and
/// for an ask its answers. Every frame is chosen from `WallTileMetrics` for the rectangle it is given,
/// so the words and the glyph the renderer draws agree on every window size, and nothing is laid out
/// with constraints: a tile that is placed again is measured again, once.
@MainActor
final class WatchTileWordsView: WatchPassView {
    enum Press: Equatable {
        case rest
        case holding
        case early
    }

    struct Level {
        var title: Double
        var status: Double
        var words: Double
        var detail: Double
        var steps: Double
        var button: Double
        var wordLines: Int
    }

    static let levels = [
        Level(title: 2.6, status: 1.8, words: 3.4, detail: 2.0, steps: 1.7, button: 2.0, wordLines: 3),
        Level(title: 2.3, status: 1.7, words: 2.8, detail: 1.8, steps: 1.6, button: 1.9, wordLines: 3),
        Level(title: 2.1, status: 1.6, words: 2.3, detail: 1.65, steps: 1.5, button: 1.8, wordLines: 3),
        Level(title: 1.9, status: 1.5, words: 1.9, detail: 1.5, steps: 1.4, button: 1.7, wordLines: 2),
        Level(title: 1.7, status: 1.4, words: 1.6, detail: 1.4, steps: 0, button: 1.5, wordLines: 2),
    ]

    struct Plan {
        var title = CGRect.zero
        var status = CGRect.zero
        var words = CGRect.zero
        var detail: CGRect?
        var detailLines = 0
        var steps: [CGRect] = []
        var context: CGRect?
        var hint: CGRect?
        var approve: CGRect?
        var deny: CGRect?
        var chat: CGRect?
        var truncated = false
    }

    let titleLabel = WatchLabel()
    let statusLabel = WatchLabel()
    let wordsLabel = WatchLabel(wrap: .words, lines: 3)
    let detailLabel = WatchLabel(wrap: .characters, lines: 99)
    let stepLabels = (0..<3).map { _ in WatchLabel() }
    let contextLabel = WatchLabel()
    let hintLabel = WatchLabel(wrap: .words, lines: 2)
    let approve = WatchPressView()
    let deny = WatchPressView()
    let chat = WatchPressView()
    private(set) var tile: WallTile?
    private(set) var face: WatchFace
    var isTruncated = false
    private(set) var level = 0
    private(set) var phase = AgentsActions.Phase.idle
    private var signature = ""
    var press = Press.rest {
        didSet { if press != oldValue { refreshAsk() } }
    }
    var onHoldBegan: ((WatchTileWordsView, NSEvent) -> Void)?
    var onHoldEnded: ((WatchTileWordsView, Bool) -> Void)?
    var onDeny: ((WatchTileWordsView) -> Void)?
    var onChat: ((WatchTileWordsView) -> Void)?

    init(face: WatchFace) {
        self.face = face
        super.init(frame: .zero)
        wantsLayer = true
        for label in [titleLabel, statusLabel, wordsLabel, detailLabel, contextLabel, hintLabel] + stepLabels {
            addSubview(label)
        }
        for button in [deny, approve, chat] { addSubview(button) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        for button in [deny, approve, chat] { button.isHidden = true }
        hintLabel.isHidden = true
        approve.onDown = { [weak self] event in
            guard let self else { return }
            self.onHoldBegan?(self, event)
        }
        approve.onUp = { [weak self] _, inside in
            guard let self else { return }
            self.onHoldEnded?(self, inside)
        }
        deny.onUp = { [weak self] _, inside in
            guard inside, let self else { return }
            self.onDeny?(self)
        }
        chat.onUp = { [weak self] _, inside in
            guard inside, let self else { return }
            self.onChat?(self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var key: String { tile?.id ?? "" }

    /// The mode its answers take: a hold and a deny for an approval the person may give from the
    /// wall, Open chat for a question, for an approval the style sends to the chat, and for a tile
    /// whose machine stopped answering nothing at all.
    enum Answers: Equatable {
        case none
        case holdAndDeny
        case openChat
    }

    var answers: Answers {
        guard let tile, tile.state.isNeedsYou, let ask = tile.ask, !isAway else { return .none }
        return ask.isApproval && face.style.approvals == .hold ? .holdAndDeny : .openChat
    }

    private var isAway: Bool {
        if case .away? = tile?.state { return true }
        return false
    }

    static func metaLine(_ tile: WallTile) -> String {
        var parts = [tile.machine]
        if let chip = tile.chip {
            parts.append(chip.effort.map { chip.name + " " + $0 } ?? chip.name)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func mark(_ outcome: AgentOutcome) -> String {
        switch outcome {
        case .running: return "•"
        case .done: return "✓"
        case .failed: return "✕"
        case .stopped: return "■"
        }
    }

    /// The steps a tile lists under its words: the last three, newest first, in the past tense, and
    /// never one the words above already say.
    static func stepLines(_ tile: WallTile) -> [(mark: String, words: String)] {
        tile.steps.map { ($0, $0.plain ?? $0.words) }
            .filter { $0.1 != tile.words && !$0.1.isEmpty }
            .prefix(3).map { (mark(for: $0.0), $0.1) }
    }

    private static func mark(for step: AgentStep) -> String { mark(step.outcome) }

    static func opacity(_ tile: WallTile) -> CGFloat {
        var opacity = 1.0
        if case .finished = tile.state { opacity *= 1 - 0.55 * min(1, max(0, tile.fade)) }
        if case .away = tile.state { opacity *= 0.7 }
        return CGFloat(opacity)
    }

    func spoken(now: Date) -> String {
        guard let tile else { return "" }
        var parts = [tile.title, tile.statusWord(at: now), tile.words]
        if let detail = tile.detail, detail != tile.words { parts.append(detail) }
        if let share = tile.contextShare {
            parts.append(Localized.text("%d%% of its context", Int((share * 100).rounded())))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func apply(_ next: WallTile, face nextFace: WatchFace, now: Date, phase nextPhase: AgentsActions.Phase) {
        let before = signature
        tile = next
        face = nextFace
        phase = nextPhase
        let steps = Self.stepLines(next).map { $0.mark + $0.words }.joined(separator: "|")
        signature = [
            next.title, next.words, next.detail ?? "", Self.metaLine(next), steps,
            "\(next.state.rank)", next.ask?.id ?? "", "\(nextFace.type.unit)",
            "\(nextFace.style.approvals)", "\(next.contextShare.map { Int($0 * 100) } ?? -1)",
            "\(next.beat?.isEmpty == false)", "\(nextPhase)",
        ].joined(separator: "\u{1}")
        alphaValue = Self.opacity(next)
        if signature != before || bounds.size != laidOutSize { fit() }
        refreshLive(now: now)
    }

    private var laidOutSize = CGSize.zero

    /// What changes every second without changing the shape: the state's word beside the title and
    /// the share of the context.
    func refreshLive(now: Date) {
        guard let tile else { return }
        let palette = face.palette
        let ink = palette.ink(for: tile.state).lifted(0.18).watchColor()
        let type = face.type
        let plan = Self.levels[min(level, Self.levels.count - 1)]
        let word = tile.statusWord(at: now)
        let meta = Self.metaLine(tile)
        let line = NSMutableAttributedString(
            string: word,
            attributes: [
                .font: type.prose(plan.status, weight: .semibold), .foregroundColor: ink,
            ])
        if !meta.isEmpty {
            line.append(
                NSAttributedString(
                    string: "  ·  " + meta,
                    attributes: [
                        .font: type.prose(plan.status), .foregroundColor: palette.dim.watchColor(),
                    ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        statusLabel.show(line)
        setAccessibilityLabel(spoken(now: now))
    }

    private var isSizing = false

    /// Gives the view the size its tile will have, measured once by the next `apply` with the words
    /// the tile holds now rather than once here with the words it held before.
    func resize(to size: CGSize) {
        isSizing = true
        setFrameSize(size)
        isSizing = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !isSizing, tile != nil, newSize.width > 8, newSize.height > 8 else { return }
        if newSize != laidOutSize { fit() }
    }

    func fit() {
        guard tile != nil, bounds.width > 8, bounds.height > 8 else { return }
        laidOutSize = bounds.size
        let last = Self.levels.count - 1
        for (index, _) in Self.levels.enumerated() {
            if let plan = plan(index, truncating: index == last) {
                level = index
                place(plan)
                return
            }
        }
    }
}
