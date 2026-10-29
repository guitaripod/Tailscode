import TailscodeCore
import UIKit

/// The words of one session's tile, laid over the glass the renderer draws: the title and its state
/// beside the glyph, what it is doing, the whole command when it asks, the last steps fading with
/// age, the context beside the heartbeat, and the two buttons of an ask. Every rectangle starts from
/// `WallTileMetrics`, so the words sit where the glyph and the strip the renderer draws leave room.
@MainActor
final class WatchTileView: UIView {
    enum Pill: Equatable { case hold, deny, chat }

    let title = WatchLabel()
    let status = WatchLabel()
    let meta = WatchLabel()
    let words = WatchLabel()
    let detail = WatchLabel()
    let more = WatchLabel()
    let stepLabels = (0..<3).map { _ in WatchLabel() }
    let contextLabel = WatchLabel()
    let holdPill = WatchPillView()
    let denyPill = WatchPillView()
    let chatPill = WatchPillView()

    var onPeek: (() -> Void)?
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?
    var onChat: (() -> Void)?

    private(set) var tile: WallTile?
    private(set) var main = WallRect.zero
    private(set) var sentence = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        clipsToBounds = false
        let all: [UIView] = [title, status, meta, words, detail, more] + stepLabels + [contextLabel, holdPill, denyPill, chatPill]
        for view in all { addSubview(view) }
        for label in [words, detail, more] { label.numberOfLines = 0 }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isAsk: Bool { tile?.state.isNeedsYou == true && tile?.ask != nil }

    /// Which button of the tile a point in the wall's coordinates is on, if any.
    func pill(at point: CGPoint) -> Pill? {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let slack: CGFloat = 8
        for (kind, view) in [(Pill.hold, holdPill), (.deny, denyPill), (.chat, chatPill)] where !view.isHidden {
            if view.frame.insetBy(dx: -slack, dy: -slack).contains(local) { return kind }
        }
        return nil
    }

    func pillFrame(_ kind: Pill) -> CGRect? {
        let view: WatchPillView
        switch kind {
        case .hold: view = holdPill
        case .deny: view = denyPill
        case .chat: view = chatPill
        }
        guard !view.isHidden else { return nil }
        return view.frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    func tick(now: Date, context: WatchWordsContext, action: WatchAction?) {
        guard let tile else { return }
        setStatus(tile, now: now, context: context, action: action)
        updateSentence(tile, now: now, action: action)
    }

    func setStatus(
        _ tile: WallTile, now: Date, context: WatchWordsContext, action: WatchAction?, lines requested: Int? = nil
    ) {
        let palette = context.palette
        let tone = palette.ink(for: tile.state).lifted(0.18).color()
        let size = status.font.pointSize
        var words = tile.statusWord(at: now)
        var ink = tone
        if let action {
            switch action {
            case .hint:
                words = String(localized: "Hold to approve")
                ink = palette.needs.lifted(0.2).color()
            case .busy(.approve): words = String(localized: "Approving…")
            case .busy(.deny): words = String(localized: "Denying…")
            case .done(.approve):
                words = String(localized: "Approved")
                ink = palette.working.lifted(0.2).color()
            case .done(.deny): words = String(localized: "Denied")
            case .failed(let why):
                words = why
                ink = palette.failed.lifted(0.3).color()
            }
        }
        var lines = requested ?? status.numberOfLines
        if case .failed? = action { lines = max(2, lines) }
        status.set(words, font: WatchFont.text(size, .semibold), ink: ink, lines: lines)
    }

    private func updateSentence(_ tile: WallTile, now: Date, action: WatchAction?) {
        var parts = [tile.title, tile.statusWord(at: now), tile.words]
        if let detail = tile.detail, detail != tile.words { parts.append(detail) }
        parts.append(contentsOf: steps(of: tile).map(\.words))
        if let action, case .failed(let why) = action { parts.append(why) }
        sentence = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityLabel = sentence
        var actions: [UIAccessibilityCustomAction] = []
        if isAsk {
            if tile.ask?.isApproval == true {
                actions.append(UIAccessibilityCustomAction(name: String(localized: "Approve")) { [weak self] _ in
                    self?.onApprove?()
                    return true
                })
                actions.append(UIAccessibilityCustomAction(name: String(localized: "Deny")) { [weak self] _ in
                    self?.onDeny?()
                    return true
                })
            }
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Open chat")) { [weak self] _ in
                self?.onChat?()
                return true
            })
        }
        accessibilityCustomActions = actions
    }

    override func accessibilityActivate() -> Bool {
        onPeek?()
        return true
    }

    func steps(of tile: WallTile) -> [(mark: String, words: String, outcome: AgentOutcome)] {
        tile.steps.compactMap { step in
            let said = step.plain ?? step.words
            guard !said.isEmpty, said != tile.words else { return nil }
            let mark: String
            switch step.outcome {
            case .done: mark = "✓"
            case .failed: mark = "✕"
            case .stopped: mark = "■"
            case .running: mark = "•"
            }
            return (mark, said, step.outcome)
        }
    }

    func remember(_ tile: WallTile, main rect: WallRect) {
        self.tile = tile
        main = rect
    }
}
