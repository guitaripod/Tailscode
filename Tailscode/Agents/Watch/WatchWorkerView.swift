import TailscodeCore
import UIKit

/// The words of one sub-agent's small tile, or of the `+N` tile that counts the ones that did not fit:
/// its name first, then how it is doing and for how long, then what it is doing, as far as the tile is
/// tall. The name wins over the age in a narrow tile, and nothing is ever set below the text floor.
@MainActor
final class WatchWorkerView: UIView {
    let name = WatchLabel()
    let state = WatchLabel()
    let doing = WatchLabel()
    let progress = WatchLabel()

    private(set) var sentence = ""
    private(set) var rect = WallRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        for label in [name, state, doing, progress] { addSubview(label) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ worker: WallWorker, rect: WallRect, parentOpacity: CGFloat, context: WatchWordsContext) {
        self.rect = rect
        let palette = context.palette
        let layout = context.layout
        let metrics = WallTileMetrics.worker(rect, unit: layout.unit)
        let scale = context.scale
        alpha = parentOpacity * (worker.state.isFinished ? 1 - 0.45 * CGFloat(min(1, max(0, worker.fade))) : 1)
        let leading = CGFloat(metrics.textLeading - rect.x)
        let width = max(10, CGFloat(rect.maxX - metrics.padding - metrics.textLeading))
        let nameFont = WatchFont.text(scale.type(1.9, floor: 11), .semibold)
        let smallFont = WatchFont.text(scale.type(1.5, floor: 11))
        let height = CGFloat(rect.height)
        let pad = max(4, CGFloat(metrics.padding) * 0.6)
        name.set(worker.title, font: nameFont, ink: palette.text.color())
        let age = worker.startedAt.map { AgentsWords.elapsed(since: $0, now: context.now) } ?? ""
        let word = worker.statusWord(at: context.now)
        let aged = age.isEmpty ? word : word + " · " + age
        state.font = smallFont
        let line = state.widthFor(aged) <= width ? aged : word
        let ink = palette.ink(for: worker.state).lifted(0.2).color()
        state.set(line, font: smallFont, ink: ink)
        let twoLines = ceil(nameFont.lineHeight + smallFont.lineHeight) + 2 * pad * 0.5 <= height
        let threeLines = !worker.words.isEmpty && ceil(nameFont.lineHeight + 2 * smallFont.lineHeight) + pad <= height
        let block = ceil(nameFont.lineHeight) + (twoLines ? ceil(smallFont.lineHeight) : 0)
            + (threeLines ? ceil(smallFont.lineHeight) : 0)
        var y = max(0, (height - block) / 2)
        let progressWidth: CGFloat = worker.progress != nil && width > 90 ? 34 : 0
        name.frame = CGRect(x: leading, y: y, width: width - progressWidth, height: ceil(nameFont.lineHeight)).rounded()
        y += ceil(nameFont.lineHeight)
        if let share = worker.progress, progressWidth > 0 {
            progress.isHidden = false
            progress.set(
                "\(worker.todosDone)/\(worker.todosTotal)", font: smallFont, ink: palette.dim.color(0.5 + 0.5 * CGFloat(share)),
                lines: 1, alignment: .right)
            progress.frame = CGRect(x: leading + width - progressWidth, y: name.frame.minY, width: progressWidth, height: ceil(nameFont.lineHeight)).rounded()
        } else {
            progress.isHidden = true
        }
        state.isHidden = !twoLines
        if twoLines {
            state.frame = CGRect(x: leading, y: y, width: width, height: ceil(smallFont.lineHeight)).rounded()
            y += ceil(smallFont.lineHeight)
        }
        doing.isHidden = !threeLines
        if threeLines {
            doing.set(worker.words, font: smallFont, ink: palette.dim.color(0.85))
            doing.frame = CGRect(x: leading, y: y, width: width, height: ceil(smallFont.lineHeight)).rounded()
        }
        sentence = ([worker.title, word] + (worker.words.isEmpty ? [] : [worker.words])).joined(separator: ", ")
        accessibilityLabel = sentence
    }

    func apply(more hidden: Int, needsEyes: Bool, rect: WallRect, parentOpacity: CGFloat, context: WatchWordsContext) {
        self.rect = rect
        let palette = context.palette
        let metrics = WallTileMetrics.worker(rect, unit: context.layout.unit)
        let scale = context.scale
        alpha = parentOpacity
        let leading = CGFloat(metrics.glyphX - rect.x - metrics.glyphSize / 2)
        let width = max(10, CGFloat(rect.width) - 2 * leading)
        let bigFont = WatchFont.text(scale.type(2.1, floor: 13), .semibold)
        let smallFont = WatchFont.text(scale.type(1.5, floor: 11))
        let height = CGFloat(rect.height)
        name.set("+\(hidden)", font: bigFont, ink: (needsEyes ? palette.needs : palette.text).color())
        let wordsLine = needsEyes ? String(localized: "some need a look") : String(localized: "more agents")
        state.set(wordsLine, font: smallFont, ink: palette.dim.color(), lines: 1)
        let both = ceil(bigFont.lineHeight + smallFont.lineHeight) <= height - 4
        let block = ceil(bigFont.lineHeight) + (both ? ceil(smallFont.lineHeight) : 0)
        let y = max(0, (height - block) / 2)
        name.frame = CGRect(x: leading, y: y, width: width, height: ceil(bigFont.lineHeight)).rounded()
        state.isHidden = !both
        state.frame = CGRect(x: leading, y: name.frame.maxY, width: width, height: ceil(smallFont.lineHeight)).rounded()
        doing.isHidden = true
        progress.isHidden = true
        sentence = "+\(hidden) " + wordsLine
        accessibilityLabel = sentence
    }
}
