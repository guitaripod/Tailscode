import AppKit
import TailscodeCore

/// The words of one sub-agent, or of the `+N` tile that counts the ones that did not fit, in a view
/// the size of its slot in the session's cell: its name, the one plain word for its state beside how
/// long it has been in it, what it is doing, and how far through its todo list it is. A press on it
/// opens its session's peek; a worker is never approvable and never a chat of its own.
@MainActor
final class WatchWorkerWordsView: WatchPassView {
    enum Face: Equatable {
        case worker(WallWorker)
        case more(count: Int, needsEyes: Bool)
    }

    struct Level {
        var title: Double
        var status: Double
        var words: Double
        var wordLines: Int
        var bar: Bool
    }

    static let levels = [
        Level(title: 1.9, status: 1.45, words: 1.55, wordLines: 2, bar: true),
        Level(title: 1.7, status: 1.35, words: 1.4, wordLines: 1, bar: true),
        Level(title: 1.6, status: 1.3, words: 0, wordLines: 0, bar: true),
        Level(title: 1.5, status: 0, words: 0, wordLines: 0, bar: false),
    ]

    let titleLabel = WatchLabel()
    let statusLabel = WatchLabel()
    let wordsLabel = WatchLabel(wrap: .words, lines: 2)
    let figureLabel = WatchLabel()
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var face: Face?
    private(set) var parentKey = ""
    private var worldFace: WatchFace
    private var progress: Double?
    private var laidOut = CGSize.zero

    init(face: WatchFace) {
        worldFace = face
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        for label in [titleLabel, statusLabel, wordsLabel, figureLabel] { addSubview(label) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ worker: WallWorker, parent: String, face next: WatchFace, now: Date) {
        worldFace = next
        parentKey = parent
        let before = face
        face = .worker(worker)
        progress = worker.progress
        let ink = next.palette.ink(for: worker.state)
        var status = worker.statusWord(at: now)
        if worker.state.ordinal == 0, let started = worker.startedAt {
            status += " · " + AgentsWords.elapsed(now.timeIntervalSince(started))
        }
        statusText = status
        titleText = worker.title
        wordsText = worker.words
        figureText = worker.progress == nil ? "" : "\(worker.todosDone)/\(worker.todosTotal)"
        tone = ink
        alphaValue = worker.state.isFinished ? CGFloat(1 - 0.45 * min(1, max(0, worker.fade))) : 1
        setAccessibilityLabel(
            [worker.title, status, worker.words, figureText].filter { !$0.isEmpty }.joined(separator: ", "))
        if before != face || bounds.size != laidOut { fit() } else { settle() }
    }

    func apply(more count: Int, needsEyes: Bool, parent: String, face next: WatchFace) {
        worldFace = next
        parentKey = parent
        let before = face
        face = .more(count: count, needsEyes: needsEyes)
        progress = nil
        titleText = "+\(count)"
        statusText = ""
        wordsText = needsEyes ? Localized.text("some need a look") : Localized.text("more sub-agents")
        figureText = ""
        tone = needsEyes ? next.palette.needs : next.palette.dim
        alphaValue = 1
        setAccessibilityLabel(titleText + " " + wordsText)
        if before != face || bounds.size != laidOut { fit() } else { settle() }
    }

    private var titleText = ""
    private var statusText = ""
    private var wordsText = ""
    private var figureText = ""
    private var tone = WallInk.white

    private var isSizing = false

    func resize(to size: CGSize) {
        isSizing = true
        setFrameSize(size)
        isSizing = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !isSizing, face != nil, newSize.width > 8, newSize.height > 8, newSize != laidOut { fit() }
    }

    private func settle() {
        let status = NSMutableAttributedString(
            string: statusText,
            attributes: [
                .font: statusLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: tone.lifted(0.18).watchColor(),
            ])
        statusLabel.show(status)
    }

    func fit() {
        guard face != nil, bounds.width > 8, bounds.height > 8 else { return }
        laidOut = bounds.size
        let last = Self.levels.count - 1
        for index in Self.levels.indices where place(Self.levels[index], truncating: index == last) {
            break
        }
        settle()
    }

    private func place(_ level: Level, truncating last: Bool) -> Bool {
        let type = worldFace.type
        let palette = worldFace.palette
        let unit = type.unit
        let size = bounds.size
        let metrics = WallTileMetrics.worker(
            WallRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), unit: unit)
        let isMore: Bool
        if case .more? = face { isMore = true } else { isMore = false }
        let x = isMore ? CGFloat(metrics.padding) : CGFloat(metrics.textLeading)
        let width = max(8, size.width - x - CGFloat(metrics.padding))
        let titleFont = type.prose(isMore ? level.title * 1.4 : level.title, weight: .semibold)
        let statusFont = type.prose(level.status, weight: .semibold)
        let wordsFont = type.prose(max(level.words, 1.3))
        let titleHeight = WatchText.lineHeight(titleFont) + 2
        let showsStatus = level.status > 0 && !statusText.isEmpty
        let statusHeight = showsStatus ? WatchText.lineHeight(statusFont) + 2 : 0
        wordsLabel.configure(wrap: .words, lines: max(1, level.wordLines))
        wordsLabel.show(wordsText, font: wordsFont, ink: palette.dim.watchColor())
        let wordsHeight = level.words > 0 && !wordsText.isEmpty ? wordsLabel.height(forWidth: width) : 0
        let barHeight = CGFloat(max(0.5 * unit, 3))
        let wantsBar = level.bar && progress != nil
        let stack = titleHeight + statusHeight + wordsHeight + (wantsBar ? barHeight + 4 : 0)
        let room = size.height - 2 * CGFloat(max(0.5 * unit, 4))
        if stack > room + 1, !last { return false }
        var y = max(CGFloat(max(0.5 * unit, 4)), (size.height - stack) / 2)
        let figureWidth = figureText.isEmpty ? 0 : WatchText.width(figureText, font: statusFont) + 6
        titleLabel.show(titleText, font: titleFont, ink: palette.text.watchColor())
        titleLabel.frame = CGRect(x: x, y: y, width: max(8, width - figureWidth), height: titleHeight).integral
        figureLabel.isHidden = figureText.isEmpty
        figureLabel.show(figureText, font: statusFont, ink: palette.dim.watchColor(), align: .right)
        figureLabel.frame = CGRect(x: x + width - figureWidth, y: y, width: figureWidth, height: titleHeight).integral
        y += titleHeight
        statusLabel.isHidden = !showsStatus
        statusLabel.frame = CGRect(x: x, y: y, width: width, height: statusHeight).integral
        statusLabel.font = statusFont
        y += statusHeight
        wordsLabel.isHidden = wordsHeight == 0
        wordsLabel.frame = CGRect(x: x, y: y, width: width, height: wordsHeight).integral
        y += wordsHeight
        track.isHidden = !wantsBar
        fill.isHidden = !wantsBar
        if wantsBar {
            let bar = CGRect(x: x, y: y + 4, width: width, height: barHeight)
            let ink = tone
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bar
            track.cornerRadius = barHeight / 2
            track.backgroundColor = palette.text.watchColor(alpha: 0.14).cgColor
            fill.frame = CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(progress ?? 0), height: bar.height)
            fill.cornerRadius = barHeight / 2
            fill.backgroundColor = ink.watchColor(alpha: 0.85).cgColor
            CATransaction.commit()
        }
        return true
    }
}
