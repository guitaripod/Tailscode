import TailscodeCore
import UIKit

/// What every item of the account reads: the model as it stands, where the cursor and the pointer
/// are, what the person unfolded, and the things an item can ask of the brain. It is one object
/// the account owns and every item holds, so an item draws from it and keeps nothing of its own.
@MainActor
final class BrainAccountEnv {
    var model: NeuralBrainModel
    var interaction: BrainInteraction
    var input: ChatInput = .touch
    var metrics: NeuralStageMetrics
    var cursor: String?
    var hovered: String?
    /// The open step's card unfolds under its row: there is no second column for it.
    var inlineCards = true
    var now = BrainDebug.now
    var lastActivity: Date?
    var justNow: Set<String> = []

    var chooseStep: (String, Bool) -> Void = { _, _ in }
    var hoverStep: (String?) -> Void = { _ in }
    var copyStep: (String) -> Void = { _ in }
    var replyStep: (String) -> Void = { _ in }
    var copyText: (String) -> Void = { _ in }
    var toggleText: (String) -> Void = { _ in }
    var toggleWork: (String) -> Void = { _ in }
    var moreRows: (String) -> Void = { _ in }
    var toggleOutput: (Bool) -> Void = { _ in }
    var openAgent: (String) -> Void = { _ in }
    var menu: (NeuralBrowse.MenuItem, String) -> Void = { _, _ in }
    var relationHover: ([String]?) -> Void = { _ in }
    var heightChanged: () -> Void = {}
    var goToAnswer: () -> Void = {}
    var jumpHandler: () -> Void = {}
    var askHandler: () -> Void = {}
    var scrolledHandler: () -> Void = {}
    var outputExpanded = false
    var viewportHeight: CGFloat = 0
    var answerText = ""

    init(model: NeuralBrainModel, interaction: BrainInteraction, metrics: NeuralStageMetrics) {
        self.model = model
        self.interaction = interaction
        self.metrics = metrics
    }

    var list: NeuralStepList { model.stepList }
    var isRunning: Bool { model.turn.outcome == .running }

    /// A work line is open when the person unfolded it, when the cursor is inside it, or when the
    /// running turn is writing into it and the account is following.
    func isOpen(_ id: String, work: BrainAccountItem.Work) -> Bool {
        if interaction.unfolded.contains(id) { return true }
        if let cursor, work.stepIDs.contains(cursor) { return true }
        return isLiveTip(work)
    }

    func isLiveTip(_ work: BrainAccountItem.Work) -> Bool {
        guard isRunning, list.isFollowing, model.pinnedStep == nil, let last = model.steps.last?.id
        else { return false }
        return work.stepIDs.last == last
    }
}

/// The measuring every item shares.
@MainActor
enum BrainText {
    static func height(_ text: NSAttributedString?, width: CGFloat, lines: Int = 0) -> CGFloat {
        guard let text, text.length > 0, width > 0 else { return 0 }
        let label = measurer
        label.numberOfLines = lines
        label.attributedText = text
        return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        let full = height(text, width: width)
        let one = height(text, width: width, lines: 1)
        return one > 0 ? Int((full / one).rounded()) : 0
    }

    private static let measurer: UILabel = {
        let label = UILabel()
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// A prose paragraph with the words between backticks set as code, in the info colour, and
    /// nothing else rewritten.
    static func prose(_ text: String, role: TypeRole = .answer, color: UIColor = Theme.Color.label)
        -> NSAttributedString
    {
        let out = NSMutableAttributedString()
        var code = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            if code {
                var attributes = Theme.Ramp.attributes(.toolDetail, color: Theme.Color.info)
                attributes[.backgroundColor] = Theme.Color.info.wash(0.1)
                out.append(NSAttributedString(string: run, attributes: attributes))
            } else {
                out.append(NSAttributedString(string: run, attributes: Theme.Ramp.attributes(role, color: color)))
            }
            run = ""
        }
        for character in text {
            if character == "`" {
                flush()
                code.toggle()
            } else {
                run.append(character)
            }
        }
        flush()
        return out
    }
}

/// One cell of the account's list: it holds the item's own view and asks it how tall it is.
@MainActor
final class BrainItemCell: UICollectionViewCell {
    private(set) var content: (UIView & BrainAccountContent)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func install(_ view: UIView & BrainAccountContent) {
        content?.removeFromSuperview()
        content = view
        contentView.addSubview(view)
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = attributes.size.width
        attributes.size.height = content?.height(forWidth: width) ?? 44
        return attributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content?.prepareForReuse()
    }
}

@MainActor
protocol BrainAccountContent: AnyObject {
    func height(forWidth width: CGFloat) -> CGFloat
    func prepareForReuse()
}

extension BrainAccountContent {
    func prepareForReuse() {}
}

extension BrainAccountEnv {
    struct CardSpec {
        let stepID: String
        let preview: Bool
        let live: Bool
    }

    /// The steps of a work line whose card is open under them: the cursor's, the hovered one's as
    /// a preview, and the step a running turn is on while the account follows it.
    func cardSpecs(for work: BrainAccountItem.Work) -> [CardSpec] {
        guard inlineCards else { return [] }
        var out: [CardSpec] = []
        if let cursor, work.stepIDs.contains(cursor) {
            out.append(CardSpec(stepID: cursor, preview: false, live: isRunningStep(cursor)))
        }
        if let hovered, hovered != cursor, work.stepIDs.contains(hovered) {
            out.append(CardSpec(stepID: hovered, preview: true, live: false))
        }
        if out.isEmpty, isLiveTip(work), let last = work.stepIDs.last, isRunningStep(last) {
            out.append(CardSpec(stepID: last, preview: false, live: true))
        }
        let order = Dictionary(uniqueKeysWithValues: work.stepIDs.enumerated().map { ($1, $0) })
        return out.sorted { (order[$0.stepID] ?? 0) < (order[$1.stepID] ?? 0) }
    }

    func isRunningStep(_ id: String) -> Bool {
        guard let step = model.step(id: id) else { return false }
        return isRunning && step.status == .running
    }

    /// The card of a step, made for the width the account has: what the readout used to say about
    /// it, under its row. A step that is running gets the compact one, with the output tail and a
    /// caret, because the note above it already says why.
    func makeCard(for spec: CardSpec) -> BrainStepCard? {
        let lines = metrics.outputLinesShown
        let card = BrainStepCard()
        wire(card)
        if spec.live {
            let value = NeuralReadout.make(
                model: model, subject: .now, now: BrainDebug.now, tz: .current, clock: CACurrentMediaTime(),
                answer: nil, outputLines: lines)
            guard case .now(let now) = value.body, let running = now.step else { return nil }
            card.configure(
                step: running, model: model, style: .init(isPreview: false, isLive: true, bordered: true),
                outputExpanded: false, tail: now.tail)
            return card
        }
        let value = NeuralReadout.make(
            model: model, subject: .step(spec.stepID), now: BrainDebug.now, tz: .current,
            clock: CACurrentMediaTime(), answer: nil, outputLines: lines)
        guard case .step(let step) = value.body else { return nil }
        card.configure(
            step: step, model: model, style: .init(isPreview: spec.preview, isLive: false, bordered: true),
            outputExpanded: outputExpanded && !spec.preview)
        return card
    }

    func wire(_ card: BrainStepCard) {
        card.onCopy = { [weak self] text in self?.copyText(text) }
        card.onRelation = { [weak self] ids in
            if let first = ids.first { self?.chooseStep(first, false) }
        }
        card.onRelationHover = { [weak self] ids in self?.relationHover(ids) }
        card.onOpenAgent = { [weak self] id in self?.openAgent(id) }
        card.onToggleOutput = { [weak self] expanded in self?.toggleOutput(expanded) }
        card.readerViewport = { [weak self] in self?.viewportHeight ?? 0 }
        card.readerOffset = { [weak self] id in self?.interaction.readerOffsets[id] ?? .zero }
        card.onReaderScroll = { [weak self] id, offset in self?.interaction.readerOffsets[id] = offset }
    }
}
