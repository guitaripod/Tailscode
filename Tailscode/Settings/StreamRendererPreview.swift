import TailscodeCore
import UIKit

/// One hand writing one sentence, forever, so the choice can be made by watching rather than by
/// reading about it.
///
/// Nothing here is a mock-up of the transcript: it is the transcript's own pieces, wired to a
/// script instead of to a server. The same pacer smooths it, the same gate holds the renderer at a
/// half-open markdown token, the same markdown renderer produces the glyphs, and the same two
/// painters put them on screen. What a card shows is therefore what an answer will do, which is the
/// only reason showing it is worth anything.
@MainActor
final class StreamRendererPreview: UIView {
    private let choice: StreamRenderer
    private let bubble = UIView()
    private let textView = UITextView()
    private lazy var aurora = AuroraTextPainter(textView: textView, host: bubble)
    private var live = LiveCascade()
    private var arrival = AuroraArrival()
    private var height: NSLayoutConstraint!
    private var lastCycle = Double.greatestFiniteMagnitude
    private var pass = 0

    init(choice: StreamRenderer) {
        self.choice = choice
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = false

        bubble.backgroundColor = Theme.Color.assistantBubble
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = Theme.Ramp.font(.answer)
        textView.textColor = Theme.Color.label
        textView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(textView)

        height = heightAnchor.constraint(equalToConstant: measured())
        NSLayoutConstraint.activate([
            height,
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.bottomAnchor.constraint(greaterThanOrEqualTo: bottomAnchor),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            textView.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor, constant: Theme.Spacing.s),
            textView.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.s),
            textView.bottomAnchor.constraint(
                equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
        ])

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: StreamRendererPreview, _) in
            view.height.constant = view.measured()
            view.textView.font = Theme.Ramp.font(.answer)
            view.redraw()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        aurora.revalidate()
    }

    /// Tall enough for the whole sentence at the reader's own type size, so the card never changes
    /// height while it is being watched — the same rule the transcript keeps.
    private func measured() -> CGFloat {
        Theme.Ramp.font(.answer).lineHeight * 4 + Theme.Spacing.s * 2
    }

    /// Puts the hand down. A preview that kept a nib resting on a finished sentence while the
    /// screen was gone would be spending a display link on a picture nobody is looking at.
    func rest() {
        aurora.release()
        live = LiveCascade()
        arrival = AuroraArrival()
        lastCycle = .greatestFiniteMagnitude
        textView.attributedText = nil
    }

    /// The sentence whole, still, and fully lit — this hand's work for a reader who has asked not
    /// to watch it being made.
    ///
    /// Reduced motion drops the movement and nothing else, so the card may not empty itself: a
    /// preview with no words in it reads as a hand that writes nothing rather than as one whose
    /// reveal was switched off, and the choice would be made by reading the summary after all. It
    /// is the same answer the transcript gives under that setting — the cascade never takes the
    /// row, and every word is handed over at once — drawn here through the settled painter, with
    /// no wave and no alpha renderer over it.
    func settle() {
        aurora.release()
        live = LiveCascade()
        arrival = AuroraArrival()
        lastCycle = .greatestFiniteMagnitude
        textView.attributedText = TextBubbleCell.rendered(
            StreamRendererDemo.text, color: Theme.Color.label)
    }

    /// Draws the card again after something invalidated what is on it — a new type size, say.
    ///
    /// A hand that is writing is repainted by the next frame, so it is put down and picked up at
    /// the start of the sentence. A hand held still for a reader who asked for less movement has
    /// no frame coming, so it is handed the sentence again rather than left holding a blank card.
    private func redraw() {
        if UIAccessibility.isReduceMotionEnabled {
            settle()
        } else {
            rest()
        }
    }

    func advance(to time: CFTimeInterval, since began: CFTimeInterval) {
        let cycle = (time - began).truncatingRemainder(dividingBy: StreamRendererDemo.loop)
        if cycle < lastCycle {
            aurora.release()
            live = LiveCascade()
            arrival = AuroraArrival()
            pass += 1
        }
        lastCycle = cycle

        let full = StreamRendererDemo.text
        let arrived = StreamRendererDemo.arrived(at: cycle)
        let sealed = arrived >= full.count
        let row = "preview-\(pass)"
        let safe = live.renderable(
            row: row, String(full.prefix(arrived)), sealed: sealed, markdown: true, at: time)
        let rendered = TextBubbleCell.rendered(safe, color: Theme.Color.label)
        live.focus(row, length: rendered.length, sealed: sealed, at: time)
        live.advance(to: time)
        live.lands(live.revealed, at: time)
        arrival.advance(to: time, settled: live.isSettled)
        paint(rendered, at: time, row: row)
    }

    private func paint(_ rendered: NSAttributedString, at time: CFTimeInterval, row: String) {
        let edge = CascadeTint.edge(ultracode: false, phase: live.phase)
        let spark = CascadeTint.spark(for: edge, traits: traitCollection)
        var tail = CascadeTail(
            revealed: live.revealed, span: StreamCascade.span, phase: live.phase, edge: edge,
            spark: spark)
        if choice == .aurora, AuroraStreamView.isAvailable {
            tail.aurora = AuroraFrame(
                progress: live.progress, phase: live.phase, time: time, rate: live.rate, edge: edge,
                spark: spark, motion: true, arrival: arrival.level)
            if aurora.paint(rendered, cascade: tail, key: "\(row):\(rendered.length)") { return }
        }
        aurora.release()
        if textView.textStorage.length == rendered.length,
            textView.textStorage.string == rendered.string
        {
            tail.repaint(textView.textStorage, base: rendered, settled: Theme.Color.label)
        } else {
            textView.attributedText = tail.paint(rendered, settled: Theme.Color.label)
        }
    }
}
