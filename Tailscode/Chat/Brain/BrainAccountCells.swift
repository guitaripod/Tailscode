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

@MainActor
final class BrainSaidView: UIView, BrainAccountContent {
    private let bar = UIView()
    private let dot = UIView()
    private let name = UILabel()
    private let clock = UILabel()
    private let justNow = UILabel()
    private let text = UILabel()
    private let more = BrainTextButton(title: " ", bordered: false) {}
    private let chip = BrainTextButton(title: " ", bordered: false) {}
    private let copy = BrainTextButton(title: " ", bordered: true) {}
    private let reply = BrainTextButton(title: " ", bordered: true) {}
    private var said: NeuralAccount.Said?
    private var env: BrainAccountEnv?
    private var itemID = ""
    private var expanded = false
    private var isCursor = false
    private var isHover = false
    private var clamped = false
    private var copied = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 4
        text.numberOfLines = 0
        for view in [bar, dot, name, clock, justNow, text, more, chip, copy, reply] { addSubview(view) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static let left: CGFloat = 16
    private static let right: CGFloat = 12

    func configure(item: BrainAccountItem, said new: NeuralAccount.Said, env newEnv: BrainAccountEnv) {
        said = new
        env = newEnv
        itemID = item.id
        expanded = newEnv.interaction.expandedText.contains(item.id)
        isCursor = newEnv.cursor == new.stepID
        isHover = newEnv.hovered == new.stepID
        copied = false
        bar.backgroundColor = Theme.Color.accent
        dot.backgroundColor = Theme.Color.modelFamily(new.family)
        name.attributedText = NSAttributedString(
            string: new.speaker.uppercased(),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.label))
        clock.attributedText = NSAttributedString(
            string: new.clock ?? "",
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
        let fresh = newEnv.justNow.contains(item.id)
        justNow.attributedText = fresh
            ? NSAttributedString(
                string: Localized.text("just now").uppercased(),
                attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.accent)) : nil
        text.attributedText = BrainText.prose(new.text)
        let chipTitle = "#\(new.number)"
        configureButton(chip, title: chipTitle, bordered: false) { [weak self] in
            guard let self, let said = self.said else { return }
            self.env?.chooseStep(said.stepID, false)
        }
        chip.accessibilityLabel = Localized.text("Step %@", chipTitle)
        configureButton(copy, title: NeuralReading.copyLabel, bordered: true) { [weak self] in
            guard let self, let said = self.said else { return }
            self.env?.copyStep(said.stepID)
            self.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated {
                    self?.copied = false
                    self?.setNeedsLayout()
                }
            }
        }
        configureButton(reply, title: NeuralReading.replyLabel, bordered: true) { [weak self] in
            guard let self, let said = self.said else { return }
            self.env?.replyStep(said.stepID)
        }
        backgroundColor = isCursor ? Theme.Color.accent.wash(0.07) : (isHover ? Theme.Color.accent.wash(0.04) : .clear)
        layer.cornerRadius = 8
        layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        accessibilityElements = [self]
        isAccessibilityElement = true
        accessibilityLabel = Localized.text("%1$@, %2$@, %3$@", new.speaker, new.clock ?? "", new.text)
        accessibilityTraits = isCursor ? [.button, .selected] : .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NeuralReading.copyLabel) { [weak self] _ in
                guard let self, let said = self.said else { return false }
                self.env?.copyStep(said.stepID)
                return true
            },
            UIAccessibilityCustomAction(name: NeuralReading.replyLabel) { [weak self] _ in
                guard let self, let said = self.said else { return false }
                self.env?.replyStep(said.stepID)
                return true
            },
        ]
        setNeedsLayout()
    }

    private func configureButton(
        _ button: BrainTextButton, title: String, bordered: Bool, action: @escaping () -> Void
    ) {
        button.configure(title: title, bordered: bordered, action: action)
    }

    @objc private func tapped() {
        guard let said, let env else { return }
        Theme.Haptics.selection()
        env.chooseStep(said.stepID, false)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard let said, let env else { return }
        switch gesture.state {
        case .began, .changed: env.hoverStep(said.stepID)
        default: env.hoverStep(nil)
        }
    }

    private var textWidth: CGFloat { 0 }

    private struct Placement {
        var height: CGFloat
        var header: CGFloat
        var textWidth: CGFloat
        var textHeight: CGFloat
        var showsMore: Bool
        var actions: CGFloat
    }

    private func placement(width: CGFloat) -> Placement {
        guard let said, env != nil else { return Placement(height: 0, header: 0, textWidth: 0, textHeight: 0, showsMore: false, actions: 0) }
        let measure = min(
            max(120, width - Self.left - Self.right - 3), CGFloat(NeuralStageMetrics.proseMeasure))
        let attributed = text.attributedText ?? NSAttributedString()
        let full = BrainText.height(attributed, width: measure)
        let lines = BrainText.lineCount(attributed, width: measure)
        let limit = NeuralAccount.saidCollapsedLines
        let canClamp = lines > limit
        let shown = canClamp && !expanded ? BrainText.height(attributed, width: measure, lines: limit) : full
        let header: CGFloat = said.showsSpeaker ? 20 : 0
        let actions: CGFloat = (isCursor || isHover) ? 34 : 0
        let moreHeight: CGFloat = canClamp ? 24 : 0
        return Placement(
            height: 4 + header + shown + moreHeight + actions + 4, header: header, textWidth: measure,
            textHeight: shown, showsMore: canClamp, actions: actions)
    }

    func height(forWidth width: CGFloat) -> CGFloat { placement(width: width).height }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard said != nil else { return }
        let place = placement(width: bounds.width)
        bar.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        var y: CGFloat = 4
        let left = Self.left + 3
        let chipSize = chip.intrinsicContentSize
        if place.header > 0 {
            dot.isHidden = false
            dot.frame = CGRect(x: left, y: y + 6, width: 8, height: 8)
            let nameSize = name.attributedText?.size() ?? .zero
            name.frame = CGRect(x: left + 16, y: y + (20 - nameSize.height) / 2, width: ceil(nameSize.width) + 1, height: ceil(nameSize.height))
            let clockSize = clock.attributedText?.size() ?? .zero
            clock.frame = CGRect(x: name.frame.maxX + 8, y: y + (20 - clockSize.height) / 2, width: ceil(clockSize.width) + 1, height: ceil(clockSize.height))
            let justSize = justNow.attributedText?.size() ?? .zero
            justNow.frame = CGRect(x: clock.frame.maxX + 8, y: y + (20 - justSize.height) / 2, width: ceil(justSize.width) + 1, height: ceil(justSize.height))
            chip.frame = CGRect(x: bounds.width - Self.right - chipSize.width, y: y + (20 - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
            y += 20
        } else {
            dot.isHidden = true
            name.frame = .zero
            clock.frame = .zero
            justNow.frame = .zero
            chip.frame = CGRect(x: bounds.width - Self.right - chipSize.width, y: y, width: chipSize.width, height: chipSize.height)
        }
        text.numberOfLines = place.showsMore && !expanded ? NeuralAccount.saidCollapsedLines : 0
        text.frame = CGRect(x: left, y: y, width: place.textWidth, height: place.textHeight)
        y += place.textHeight
        if place.showsMore {
            more.configure(
                title: expanded ? Localized.text("Hide") : NeuralReading.showAllLabel, bordered: false
            ) { [weak self] in
                guard let self else { return }
                self.env?.toggleText(self.itemID)
            }
            let size = more.intrinsicContentSize
            more.isHidden = false
            more.frame = CGRect(x: left, y: y + 2, width: size.width, height: 22)
            y += 24
        } else {
            more.isHidden = true
        }
        let showActions = place.actions > 0
        copy.isHidden = !showActions
        reply.isHidden = !showActions
        if showActions {
            copy.configure(
                title: copied ? Localized.text("Copied") : NeuralReading.copyLabel, bordered: true
            ) { [weak self] in
                guard let self, let said = self.said else { return }
                self.env?.copyStep(said.stepID)
                self.copied = true
                self.setNeedsLayout()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.copied = false
                        self?.setNeedsLayout()
                    }
                }
            }
            let copySize = copy.intrinsicContentSize
            let replySize = reply.intrinsicContentSize
            copy.frame = CGRect(x: left, y: y + 4, width: copySize.width, height: 28)
            reply.frame = CGRect(x: copy.frame.maxX + 8, y: y + 4, width: replySize.width, height: 28)
        }
    }
}

extension BrainSaidView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let said, let env else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: NeuralReading.copyLabel, image: UIImage(systemName: "doc.on.doc")) { _ in
                    env.copyStep(said.stepID)
                },
                UIAction(title: NeuralReading.replyLabel, image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                    env.replyStep(said.stepID)
                },
            ])
        }
    }
}

extension BrainTextButton {
    /// Sets a button made empty to its words and its action: a cell reuses its buttons.
    func configure(title: String, bordered: Bool, action: @escaping () -> Void) {
        replace(title: title, bordered: bordered, action: action)
    }
}

@MainActor
final class BrainThoughtView: UIView, BrainAccountContent {
    private let glyph = BrainShapeIcon()
    private let text = UILabel()
    private let toggle = BrainTextButton(title: " ", bordered: false) {}
    private let chip = BrainTextButton(title: " ", bordered: false) {}
    private var thought: NeuralAccount.Thought?
    private var env: BrainAccountEnv?
    private var itemID = ""
    private var expanded = false
    private var isCursor = false
    private var isHover = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        for view in [glyph, text, toggle, chip] { addSubview(view) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(item: BrainAccountItem, thought new: NeuralAccount.Thought, env newEnv: BrainAccountEnv) {
        thought = new
        env = newEnv
        itemID = item.id
        expanded = newEnv.interaction.expandedText.contains(item.id)
        isCursor = newEnv.cursor == new.stepID
        isHover = newEnv.hovered == new.stepID
        glyph.set(shape: .circle, color: BrainCanvas.zone(.think))
        text.numberOfLines = expanded ? 0 : 1
        text.lineBreakMode = .byTruncatingTail
        text.attributedText = NSAttributedString(
            string: expanded ? new.text : new.firstLine,
            attributes: Theme.Ramp.attributes(.thought, color: Theme.Color.secondaryLabel))
        chip.configure(title: "#\(new.number)", bordered: false) { [weak self] in
            guard let self, let thought = self.thought else { return }
            self.env?.chooseStep(thought.stepID, false)
        }
        backgroundColor = isCursor ? Theme.Color.accent.wash(0.07) : (isHover ? Theme.Color.accent.wash(0.04) : .clear)
        accessibilityLabel = Localized.text("Thought, %@", new.firstLine)
        accessibilityTraits = isCursor ? [.button, .selected] : .button
        setNeedsLayout()
    }

    @objc private func tapped() {
        guard let thought, let env else { return }
        Theme.Haptics.selection()
        env.chooseStep(thought.stepID, false)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard let thought, let env else { return }
        switch gesture.state {
        case .began, .changed: env.hoverStep(thought.stepID)
        default: env.hoverStep(nil)
        }
    }

    private var canUnfold: Bool {
        guard let thought else { return false }
        if thought.canUnfold { return true }
        let room = bounds.width - 19 - 8 - 18 - 10 - 90
        return (thought.firstLine as NSString).size(withAttributes: [.font: Theme.Ramp.font(.thought)]).width > room
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard thought != nil else { return 24 }
        guard expanded else { return 28 }
        let room = width - 19 - 8 - 18 - 10 - 90
        return max(28, BrainText.height(text.attributedText, width: room) + 10)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let chipSize = chip.intrinsicContentSize
        let showsToggle = canUnfold
        toggle.isHidden = !showsToggle
        glyph.frame = CGRect(x: 19, y: expanded ? 5 : (bounds.height - 18) / 2, width: 18, height: 18)
        chip.frame = CGRect(x: bounds.width - 12 - chipSize.width, y: expanded ? 4 : (bounds.height - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        var right = chip.frame.minX - 8
        if showsToggle {
            toggle.configure(
                title: expanded ? Localized.text("Hide") : Localized.text("Show"), bordered: false
            ) { [weak self] in
                guard let self else { return }
                self.env?.toggleText(self.itemID)
            }
            let size = toggle.intrinsicContentSize
            toggle.frame = CGRect(x: right - size.width, y: expanded ? 4 : (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = toggle.frame.minX - 8
        }
        let width = max(0, right - 44)
        let height = expanded ? BrainText.height(text.attributedText, width: width) : ceil(text.attributedText?.size().height ?? 18)
        text.frame = CGRect(x: 44, y: expanded ? 5 : (bounds.height - height) / 2, width: width, height: height)
    }
}

@MainActor
final class BrainAskedView: UIView, BrainAccountContent {
    private let label = UILabel()
    private let text = UILabel()
    private let more = BrainTextButton(title: " ", bordered: false) {}
    private var asked: NeuralAccount.Asked?
    private var env: BrainAccountEnv?
    private var expanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [label, text, more] { addSubview(view) }
        text.numberOfLines = 0
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(asked new: NeuralAccount.Asked, env newEnv: BrainAccountEnv) {
        asked = new
        env = newEnv
        expanded = newEnv.interaction.askedExpanded
        label.attributedText = NSAttributedString(
            string: Localized.text("ASKED"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        let words = expanded ? new.text : new.lines.joined(separator: "\n")
        text.attributedText = NSAttributedString(
            string: words, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
        accessibilityLabel = Localized.text("Asked, %@", new.text)
        setNeedsLayout()
    }

    private var measure: CGFloat { 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let asked else { return 0 }
        let inner = min(width - 32, CGFloat(NeuralStageMetrics.proseMeasure))
        let lines = expanded ? 0 : 2
        let textHeight = BrainText.height(text.attributedText, width: inner, lines: lines)
        return 6 + 16 + 4 + textHeight + (asked.hasMore ? 22 : 0) + 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let asked else { return }
        let inner = min(bounds.width - 32, CGFloat(NeuralStageMetrics.proseMeasure))
        let labelSize = label.attributedText?.size() ?? .zero
        label.frame = CGRect(x: 16, y: 6, width: ceil(labelSize.width) + 1, height: 16)
        text.numberOfLines = expanded ? 0 : 2
        let height = BrainText.height(text.attributedText, width: inner, lines: expanded ? 0 : 2)
        text.frame = CGRect(x: 16, y: 26, width: inner, height: height)
        more.isHidden = !asked.hasMore
        if asked.hasMore {
            more.configure(
                title: expanded ? Localized.text("Hide") : NeuralReading.showAllLabel, bordered: false
            ) { [weak self] in
                guard let self, let env = self.env else { return }
                env.interaction.askedExpanded.toggle()
                env.heightChanged()
            }
            let size = more.intrinsicContentSize
            more.frame = CGRect(x: 16, y: text.frame.maxY + 2, width: size.width, height: 20)
        }
    }
}

@MainActor
final class BrainPlanView: UIView, BrainAccountContent {
    private let card = UIView()
    private let chevron = UIImageView()
    private let label = UILabel()
    private let count = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var rows: [(mark: UIImageView, text: UILabel)] = []
    private var plan: NeuralAccount.Plan?
    private var env: BrainAccountEnv?
    private var open = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        track.layer.cornerRadius = 2
        fill.layer.cornerRadius = 2
        addSubview(card)
        for view in [chevron, label, count, track] { card.addSubview(view) }
        track.addSubview(fill)
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        chevron.contentMode = .center
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var isLiveCompact: Bool { env?.isRunning == true }

    func configure(plan new: NeuralAccount.Plan, env newEnv: BrainAccountEnv) {
        plan = new
        env = newEnv
        let finished = new.done == new.total
        open = newEnv.interaction.planExpanded ?? !finished
        card.backgroundColor = BrainCanvas.raised
        card.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        chevron.image = BrainCanvas.image(open ? "chevron.down" : "chevron.right", size: 9, weight: .bold)?
            .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        label.attributedText = NSAttributedString(
            string: Localized.text("PLAN"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        count.attributedText = NSAttributedString(
            string: new.label, attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.label))
        track.backgroundColor = Theme.Color.accent.wash(0.16)
        fill.backgroundColor = Theme.Color.accent
        for row in rows {
            row.mark.removeFromSuperview()
            row.text.removeFromSuperview()
        }
        rows = []
        if open {
            for item in new.items {
                let mark = UIImageView()
                mark.contentMode = .center
                let text = UILabel()
                text.numberOfLines = 1
                text.lineBreakMode = .byTruncatingTail
                switch item.state {
                case .done:
                    mark.image = BrainCanvas.image("checkmark", size: 10, weight: .bold)?
                        .withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
                case .inProgress:
                    mark.image = BrainCanvas.image("circle.fill", size: 8)?
                        .withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.activeForm ?? item.text,
                        attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
                case .pending:
                    mark.image = BrainCanvas.image("circle", size: 8)?
                        .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    text.attributedText = NSAttributedString(
                        string: item.text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label))
                }
                card.addSubview(mark)
                card.addSubview(text)
                rows.append((mark, text))
            }
        }
        accessibilityLabel = Localized.text("Plan, %@", new.label)
        setNeedsLayout()
    }

    @objc private func tapped() {
        guard let env else { return }
        Theme.Haptics.selection()
        env.interaction.planExpanded = !open
        env.heightChanged()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let plan else { return 0 }
        let body = open ? CGFloat(plan.items.count) * 24 + 8 : 0
        return 8 + 28 + body + 6
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let plan else { return }
        card.frame = CGRect(x: 16, y: 8, width: bounds.width - 32, height: bounds.height - 14)
        chevron.frame = CGRect(x: 10, y: 0, width: 14, height: 28)
        let labelSize = label.attributedText?.size() ?? .zero
        label.frame = CGRect(x: 28, y: (28 - labelSize.height) / 2, width: ceil(labelSize.width) + 1, height: ceil(labelSize.height))
        let countSize = count.attributedText?.size() ?? .zero
        count.frame = CGRect(x: label.frame.maxX + 10, y: (28 - countSize.height) / 2, width: ceil(countSize.width) + 1, height: ceil(countSize.height))
        let trackWidth = min(160, max(0, card.bounds.width - count.frame.maxX - 24))
        track.frame = CGRect(x: count.frame.maxX + 12, y: 12, width: trackWidth, height: 4)
        let share = plan.total == 0 ? 0 : CGFloat(plan.done) / CGFloat(plan.total)
        fill.frame = CGRect(x: 0, y: 0, width: trackWidth * share, height: 4)
        for (index, row) in rows.enumerated() {
            let y = 32 + CGFloat(index) * 24
            row.mark.frame = CGRect(x: 10, y: y, width: 14, height: 24)
            row.text.frame = CGRect(x: 32, y: y, width: card.bounds.width - 32 - 12, height: 24)
        }
    }
}

@MainActor
final class BrainWorkView: UIView, BrainAccountContent {
    private let line = UIControl()
    private let chevron = UIImageView()
    private var markViews: [UIView] = []
    private let words = UILabel()
    private let chip = BrainTextButton(title: " ", bordered: false) {}
    private let frameView = UIView()
    private var rowViews: [BrainStepRowView] = []
    private var cards: [(stepID: String, card: BrainStepCard)] = []
    private let moreButton = BrainTextButton(title: " ", bordered: false) {}
    private let moreNote = UILabel()
    private var item: BrainAccountItem?
    private var work: BrainAccountItem.Work?
    private var env: BrainAccountEnv?
    private var open = false
    private var shown: [String] = []
    private var cardAfter: [String: BrainAccountEnv.CardSpec] = [:]
    private var capped = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.layer.cornerRadius = 8
        line.layer.cornerCurve = .continuous
        line.layer.borderWidth = 1
        line.addTarget(self, action: #selector(lineTapped), for: .touchUpInside)
        chevron.contentMode = .center
        line.addSubview(chevron)
        words.lineBreakMode = .byTruncatingTail
        line.addSubview(words)
        line.addSubview(chip)
        addSubview(line)
        frameView.layer.borderWidth = 1
        frameView.layer.cornerRadius = 8
        frameView.layer.cornerCurve = .continuous
        frameView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        addSubview(frameView)
        frameView.addSubview(moreButton)
        moreNote.numberOfLines = 0
        frameView.addSubview(moreNote)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func lineTapped() {
        guard let item, let env else { return }
        Theme.Haptics.selection()
        env.toggleWork(item.id)
    }

    func configure(item newItem: BrainAccountItem, work newWork: BrainAccountItem.Work, env newEnv: BrainAccountEnv) {
        item = newItem
        work = newWork
        env = newEnv
        open = newEnv.isOpen(newItem.id, work: newWork)
        chevron.image = BrainCanvas.image(open ? "chevron.down" : "chevron.right", size: 9, weight: .bold)?
            .withTintColor(Theme.Color.secondaryLabel.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        line.backgroundColor = BrainCanvas.raised
        line.layer.borderColor = (open ? BrainCanvas.rule : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        line.layer.maskedCorners =
            open ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        frameView.backgroundColor = BrainCanvas.raised.wash(0.6)
        frameView.layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        buildLine(newWork)
        buildRows(newWork)
        accessibilityElements = [line] + rowViews
        line.isAccessibilityElement = true
        line.accessibilityLabel = words.attributedText?.string
        line.accessibilityTraits = .button
        line.accessibilityValue = open ? Localized.text("Expanded") : Localized.text("Collapsed")
        setNeedsLayout()
    }

    private func buildLine(_ work: BrainAccountItem.Work) {
        for view in markViews { view.removeFromSuperview() }
        markViews = []
        for cluster in work.clusters.prefix(4) {
            let icon = BrainShapeIcon()
            icon.set(shape: cluster.zone.shape, color: BrainCanvas.zone(cluster.zone))
            line.addSubview(icon)
            markViews.append(icon)
        }
        let out = NSMutableAttributedString()
        let (shown, more) = clauses(work)
        for (index, clause) in shown.enumerated() {
            if index > 0 {
                out.append(
                    NSAttributedString(
                        string: "  \u{00B7}  ",
                        attributes: Theme.Ramp.attributes(.control, color: Theme.Color.secondaryLabel)))
            }
            let ink: UIColor
            var symbol: String?
            switch clause.verdict {
            case .failed: (ink, symbol) = (Theme.Color.danger, "xmark")
            case .tryingAgain: (ink, symbol) = (Theme.Color.warning, "exclamationmark.triangle")
            default: (ink, symbol) = (Theme.Color.label, nil)
            }
            if let symbol, let image = BrainCanvas.image(symbol, size: 10) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(attachment: attachment))
                out.append(NSAttributedString(string: " "))
            }
            out.append(
                NSAttributedString(string: clause.text, attributes: Theme.Ramp.attributes(.control, color: ink)))
            if clause.verdict == .done, isCheck(clause), let image = BrainCanvas.image("checkmark", size: 10, weight: .bold) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(Theme.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(string: " "))
                out.append(NSAttributedString(attachment: attachment))
            }
        }
        for fixed in work.fixedWords.prefix(1) {
            out.append(
                NSAttributedString(
                    string: "   ", attributes: Theme.Ramp.attributes(.control, color: Theme.Color.warning)))
            if let image = BrainCanvas.image("arrow.trianglehead.2.clockwise.rotate.90", size: 10) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                out.append(NSAttributedString(attachment: attachment))
                out.append(NSAttributedString(string: " "))
            }
            out.append(
                NSAttributedString(
                    string: fixed, attributes: Theme.Ramp.attributes(.control, color: Theme.Color.warning)))
        }
        if more > 0 {
            out.append(
                NSAttributedString(
                    string: "  " + Localized.text("+%lld more", more),
                    attributes: Theme.Ramp.attributes(.control, color: Theme.Color.secondaryLabel)))
        }
        words.attributedText = out
        let range = work.numbers.first.map { first -> String in
            let last = work.numbers.last ?? first
            return first == last ? "#\(first)" : "#\(first)\u{2013}\(last)"
        } ?? ""
        let target = work.firstFailedStepID ?? work.stepIDs.first
        chip.configure(title: range, bordered: false) { [weak self] in
            guard let target else { return }
            self?.env?.chooseStep(target, false)
        }
        chip.accessibilityLabel = Localized.text("Steps %@", range)
    }

    /// At most four clauses and how many more there are.
    private func clauses(_ work: BrainAccountItem.Work) -> ([BrainAccountItem.Clause], Int) {
        let limit = 4
        guard work.clauses.count > limit else { return (work.clauses, 0) }
        return (Array(work.clauses.prefix(limit)), work.clauses.count - limit)
    }

    private func isCheck(_ clause: BrainAccountItem.Clause) -> Bool {
        guard let env, let id = clause.stepIDs.first, let step = env.model.step(id: id),
            let command = step.call?.call.input?["command"]?.stringValue
        else { return false }
        return NeuralHuman.classify(command).checkKind != nil
    }

    private static let initialRows = 40
    private static let rowStride = 40
    private static let rowMax = 400

    private func buildRows(_ work: BrainAccountItem.Work) {
        for view in rowViews { view.removeFromSuperview() }
        rowViews = []
        for entry in cards { entry.card.removeFromSuperview() }
        cards = []
        cardAfter = [:]
        shown = []
        guard open, let env, let itemID = item?.id else {
            frameView.isHidden = true
            return
        }
        frameView.isHidden = false
        let specs = env.cardSpecs(for: work)
        var cap = min(work.stepIDs.count, env.interaction.rowCaps[itemID] ?? Self.initialRows)
        for spec in specs {
            if let at = work.stepIDs.firstIndex(of: spec.stepID) { cap = max(cap, min(work.stepIDs.count, at + 1)) }
        }
        capped = cap
        shown = Array(work.stepIDs.prefix(cap))
        let list = env.list
        for (index, id) in shown.enumerated() {
            guard let row = list.row(id: id) else { continue }
            let view = BrainStepRowView()
            var context = BrainStepRowView.Context()
            context.previous = index > 0 ? list.row(id: shown[index - 1]) : nil
            context.next = index + 1 < shown.count ? list.row(id: shown[index + 1]) : nil
            context.isCursor = env.cursor == id
            context.isHovered = env.hovered == id && env.cursor != id
            context.query = list.filter.query
            context.input = env.input
            context.total = list.total
            view.configure(row: row, context: context)
            view.onClick = { [weak env] id, double in env?.chooseStep(id, double) }
            view.onHover = { [weak env] id in env?.hoverStep(id) }
            view.onMenu = { [weak env] item, id in env?.menu(item, id) }
            view.onCopy = { [weak env] id in env?.copyStep(id) }
            frameView.addSubview(view)
            rowViews.append(view)
        }
        for spec in specs where shown.contains(spec.stepID) {
            guard let card = env.makeCard(for: spec) else { continue }
            card.onLayoutChange = { [weak env] in env?.heightChanged() }
            frameView.addSubview(card)
            cards.append((spec.stepID, card))
            cardAfter[spec.stepID] = spec
        }
        let remaining = work.stepIDs.count - cap
        if remaining > 0 {
            moreButton.isHidden = cap >= Self.rowMax
            moreNote.isHidden = cap < Self.rowMax
            if cap >= Self.rowMax {
                moreNote.attributedText = NSAttributedString(
                    string: Localized.text("%lld more steps are in the list", remaining),
                    attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
            } else {
                let step = min(remaining, Self.rowStride)
                moreButton.configure(
                    title: step == 1 ? Localized.text("Show 1 more step") : Localized.text("Show %lld more steps", step),
                    bordered: false
                ) { [weak env] in
                    env?.moreRows(itemID)
                }
            }
        } else {
            moreButton.isHidden = true
            moreNote.isHidden = true
        }
    }

    private struct Placement {
        var line: CGFloat
        var rows: [CGRect]
        var cards: [CGRect]
        var more: CGFloat
        var frame: CGFloat
        var total: CGFloat
    }

    private func placement(width: CGFloat) -> Placement {
        let line: CGFloat = 36
        guard open, let env else {
            return Placement(line: line, rows: [], cards: [], more: 0, frame: 0, total: line)
        }
        let inner = width - 2
        var y: CGFloat = 4
        var rowFrames: [CGRect] = []
        var cardFrames: [CGRect] = []
        let list = env.list
        var cardIndex = 0
        for id in shown {
            let height = CGFloat(list.row(id: id)?.height(input: env.input) ?? 28)
            rowFrames.append(CGRect(x: 0, y: y, width: inner, height: height))
            y += height
            if cardIndex < cards.count, cards[cardIndex].stepID == id {
                let card = cards[cardIndex].card
                let cardWidth = inner - 36 - 12
                let fit = card.fittedHeight(width: cardWidth)
                cardFrames.append(CGRect(x: 36, y: y + 4, width: cardWidth, height: fit))
                y += fit + 12
                cardIndex += 1
            }
        }
        var more: CGFloat = 0
        if !moreButton.isHidden || !moreNote.isHidden {
            more = 30
            y += more
        }
        y += 4
        return Placement(line: line, rows: rowFrames, cards: cardFrames, more: more, frame: y, total: line + y)
    }

    static func fit(_ view: UIView, width: CGFloat) -> CGFloat {
        view.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return ceil(
            view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard work != nil else { return 36 }
        return placement(width: width).total
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let place = placement(width: bounds.width)
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: place.line)
        chevron.frame = CGRect(x: 6, y: 0, width: 14, height: place.line)
        var x: CGFloat = 24
        for view in markViews {
            view.frame = CGRect(x: x, y: (place.line - 18) / 2, width: 18, height: 18)
            x += 20
        }
        let chipSize = chip.intrinsicContentSize
        chip.frame = CGRect(x: bounds.width - 10 - chipSize.width, y: (place.line - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        let textSize = words.attributedText?.size() ?? .zero
        words.frame = CGRect(x: x + 6, y: (place.line - ceil(textSize.height)) / 2, width: max(0, chip.frame.minX - x - 14), height: ceil(textSize.height))
        guard open else { return }
        frameView.frame = CGRect(x: 0, y: place.line, width: bounds.width, height: place.frame)
        for (view, frame) in zip(rowViews, place.rows) { view.frame = frame }
        for (entry, frame) in zip(cards, place.cards) { entry.card.frame = frame }
        if place.more > 0 {
            let y = (place.rows.last?.maxY ?? 4) + (place.cards.last.map { $0.maxY + 8 - (place.rows.last?.maxY ?? 0) } ?? 0)
            let base = max(y, (place.cards.last?.maxY ?? 0) + 8)
            let size = moreButton.intrinsicContentSize
            moreButton.frame = CGRect(x: 14, y: base + 4, width: size.width, height: 22)
            moreNote.frame = CGRect(x: 14, y: base + 4, width: bounds.width - 28, height: 22)
        }
    }
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

@MainActor
final class BrainResultView: UIView, BrainAccountContent {
    private let card = UIView()
    private var result: NeuralAccount.Result?
    private var env: BrainAccountEnv?
    private var groups: [UIView] = []
    private var answerButton: UIControl?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        addSubview(card)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text.uppercased(),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        return label
    }

    func configure(result new: NeuralAccount.Result, env newEnv: BrainAccountEnv) {
        result = new
        env = newEnv
        card.backgroundColor = BrainCanvas.raised
        card.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        for view in groups { view.removeFromSuperview() }
        groups = []
        let title = UILabel()
        title.attributedText = NSAttributedString(
            string: Localized.text("RESULT"),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.label))
        let head = BrainResultGroup(title: title)
        groups.append(head)
        if !new.changes.isEmpty {
            let group = BrainResultGroup(title: label(NeuralReading.changedLabel))
            let maxChange = max(1, new.changes.map { $0.added + $0.removed }.max() ?? 1)
            for change in new.changes.prefix(8) {
                group.add(changeRow(change, maxChange: maxChange))
            }
            if new.changes.count > 8 {
                group.add(note(Localized.text("%lld more files", new.changes.count - 8)))
            }
            groups.append(group)
        } else if let words = new.changedWords {
            let group = BrainResultGroup(title: nil)
            group.add(note(words))
            groups.append(group)
        }
        if !new.checks.isEmpty {
            let group = BrainResultGroup(title: label(Localized.text("Checks")))
            for check in new.checks { group.add(checkRow(check)) }
            groups.append(group)
        }
        if !new.unfixed.isEmpty {
            let group = BrainResultGroup(title: label(Localized.text("Still failing")))
            for item in new.unfixed.prefix(6) { group.add(unfixedRow(item)) }
            groups.append(group)
        }
        if new.answer != nil || new.answerWords != nil {
            let group = BrainResultGroup(title: label(NeuralReading.thenItAnswered))
            if let answer = new.answer {
                let text = UILabel()
                text.numberOfLines = 0
                text.attributedText = NSAttributedString(
                    string: answer, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label))
                group.add(text)
                group.onTap = { [weak self] in self?.env?.goToAnswer() }
            } else if let words = new.answerWords {
                group.add(note(words))
            }
            groups.append(group)
        }
        for (index, view) in groups.enumerated() {
            (view as? BrainResultGroup)?.ruled = index > 0
            card.addSubview(view)
        }
        accessibilityElements = groups
        setNeedsLayout()
    }

    private func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
        return label
    }

    private func changeRow(_ change: NeuralAccount.Change, maxChange: Int) -> UIView {
        BrainChangeRow(change: change, maxChange: maxChange) { [weak self] in
            self?.env?.chooseStep(change.stepID, false)
        }
    }

    private func checkRow(_ check: NeuralAccount.Check) -> UIView {
        BrainCheckRow(check: check) { [weak self] in
            self?.env?.chooseStep(check.stepID, false)
        }
    }

    private func unfixedRow(_ item: NeuralAccount.Unfixed) -> UIView {
        BrainUnfixedRow(item: item) { [weak self] in self?.env?.chooseStep(item.stepID, false) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 32 - 24
        let total = groups.reduce(CGFloat(0)) { sum, view in
            sum + ((view as? BrainResultGroup)?.height(forWidth: inner) ?? 0)
        }
        return 12 + total + 12 + 16
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = CGRect(x: 16, y: 12, width: bounds.width - 32, height: bounds.height - 12 - 16)
        let inner = card.bounds.width - 24
        var y: CGFloat = 12
        for view in groups {
            guard let group = view as? BrainResultGroup else { continue }
            let height = group.height(forWidth: inner)
            group.frame = CGRect(x: 12, y: y, width: inner, height: height)
            y += height
        }
    }
}

/// One group of the result block, ruled off from the one above it.
@MainActor
final class BrainResultGroup: UIView {
    var ruled = false { didSet { setNeedsLayout() } }
    var onTap: (() -> Void)?
    private let title: UIView?
    private var rows: [UIView] = []
    private let rule = UIView()

    init(title newTitle: UIView?) {
        title = newTitle
        super.init(frame: .zero)
        if let title { addSubview(title) }
        rule.backgroundColor = Theme.Color.separator
        addSubview(rule)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func add(_ view: UIView) {
        rows.append(view)
        addSubview(view)
    }

    private var topPad: CGFloat { ruled ? 10 : 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        var y = topPad + 2
        if let title { y += ceil(title.intrinsicContentSize.height > 0 ? title.intrinsicContentSize.height : 16) + 6 }
        for row in rows { y += rowHeight(row, width: width) + 6 }
        return y + (ruled ? 6 : 0)
    }

    private func rowHeight(_ row: UIView, width: CGFloat) -> CGFloat {
        if let label = row as? UILabel {
            return BrainText.height(label.attributedText, width: width)
        }
        return row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rule.isHidden = !ruled
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
        var y = topPad + 2
        if let title {
            let size = title.intrinsicContentSize
            let height = ceil(size.height > 0 ? size.height : 16)
            title.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 6
        }
        for row in rows {
            let height = rowHeight(row, width: bounds.width)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 6
        }
    }
}

@MainActor
final class BrainChangeRow: UIControl {
    private let path = UILabel()
    private let bar = BrainChangeBar()
    private let tally = UILabel()
    private let numbers = UILabel()

    init(change: NeuralAccount.Change, maxChange: Int, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString(
            string: change.shortDirectory,
            attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.secondaryLabel))
        text.append(
            NSAttributedString(
                string: change.fileName, attributes: Theme.Ramp.attributes(.toolName, color: Theme.Color.label)))
        path.attributedText = text
        path.lineBreakMode = .byTruncatingMiddle
        bar.set(added: change.added, removed: change.removed, maxChange: maxChange)
        let tallyText = NSMutableAttributedString(
            string: "+\(change.added)", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.accent))
        tallyText.append(
            NSAttributedString(
                string: " \u{2212}\(change.removed)", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.danger)))
        tally.attributedText = tallyText
        numbers.attributedText = NSAttributedString(
            string: change.numbers.map { "#\($0)" }.joined(separator: ", "),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        numbers.lineBreakMode = .byTruncatingHead
        for view in [path, bar, tally, numbers] { addSubview(view) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", change.fileName, change.tally ?? "")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 28) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let numberSize = numbers.attributedText?.size() ?? .zero
        let numberWidth = min(ceil(numberSize.width) + 1, bounds.width * 0.22)
        numbers.frame = CGRect(x: bounds.width - numberWidth, y: (bounds.height - numberSize.height) / 2, width: numberWidth, height: ceil(numberSize.height))
        let tallySize = tally.attributedText?.size() ?? .zero
        tally.frame = CGRect(x: numbers.frame.minX - 8 - ceil(tallySize.width) - 1, y: (bounds.height - tallySize.height) / 2, width: ceil(tallySize.width) + 1, height: ceil(tallySize.height))
        bar.frame = CGRect(x: tally.frame.minX - 8 - 64, y: (bounds.height - 6) / 2, width: 64, height: 6)
        let pathSize = path.attributedText?.size() ?? .zero
        path.frame = CGRect(x: 0, y: (bounds.height - pathSize.height) / 2, width: max(0, bar.frame.minX - 10), height: ceil(pathSize.height))
    }
}

/// A file's lines added and removed as a short bar: accent for what was added, danger for what
/// went, scaled to the busiest file.
@MainActor
final class BrainChangeBar: UIView {
    private let added = UIView()
    private let removed = UIView()
    private var share = (added: CGFloat(0), removed: CGFloat(0))

    override init(frame: CGRect) {
        super.init(frame: frame)
        added.backgroundColor = Theme.Color.accent
        removed.backgroundColor = Theme.Color.danger
        layer.cornerRadius = 3
        layer.masksToBounds = true
        backgroundColor = Theme.Color.separator
        addSubview(added)
        addSubview(removed)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(added a: Int, removed r: Int, maxChange: Int) {
        let total = CGFloat(max(1, maxChange))
        share = (CGFloat(a) / total, CGFloat(r) / total)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        added.frame = CGRect(x: 0, y: 0, width: bounds.width * share.added, height: bounds.height)
        removed.frame = CGRect(x: added.frame.maxX, y: 0, width: bounds.width * share.removed, height: bounds.height)
    }
}

@MainActor
final class BrainCheckRow: UIControl {
    private let icon = UIImageView()
    private let name = UILabel()
    private let command = UILabel()
    private let verdict = UILabel()
    private let numbers = UILabel()

    init(check: NeuralAccount.Check, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let tone: UIColor
        let symbol: String
        switch check.verdict {
        case .fixed: (tone, symbol) = (Theme.Color.warning, "arrow.trianglehead.2.clockwise.rotate.90")
        case .failed, .tryingAgain: (tone, symbol) = (Theme.Color.danger, "xmark")
        case .running: (tone, symbol) = (Theme.Color.accent, "circle.dotted")
        default: (tone, symbol) = (Theme.Color.accent, "checkmark")
        }
        icon.image = BrainCanvas.image(symbol, size: 11, weight: .bold)?
            .withTintColor(tone.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        icon.contentMode = .center
        name.attributedText = NSAttributedString(
            string: check.label, attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        command.attributedText = NSAttributedString(
            string: check.command, attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel))
        command.lineBreakMode = .byTruncatingTail
        verdict.attributedText = NSAttributedString(
            string: check.verdictWords, attributes: Theme.Ramp.attributes(.rowMeta, color: tone))
        numbers.attributedText = NSAttributedString(
            string: check.numbers.map { "#\($0)" }.joined(separator: ", "),
            attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel, alignment: .right))
        numbers.lineBreakMode = .byTruncatingHead
        for view in [icon, name, command, verdict, numbers] { addSubview(view) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", check.label, check.verdictWords)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 28) }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: 0, width: 18, height: bounds.height)
        let nameSize = name.attributedText?.size() ?? .zero
        name.frame = CGRect(x: 24, y: (bounds.height - nameSize.height) / 2, width: ceil(nameSize.width) + 1, height: ceil(nameSize.height))
        let numberSize = numbers.attributedText?.size() ?? .zero
        let numberWidth = min(ceil(numberSize.width) + 1, bounds.width * 0.2)
        numbers.frame = CGRect(x: bounds.width - numberWidth, y: (bounds.height - numberSize.height) / 2, width: numberWidth, height: ceil(numberSize.height))
        let verdictSize = verdict.attributedText?.size() ?? .zero
        verdict.frame = CGRect(x: numbers.frame.minX - 8 - ceil(verdictSize.width) - 1, y: (bounds.height - verdictSize.height) / 2, width: ceil(verdictSize.width) + 1, height: ceil(verdictSize.height))
        let commandSize = command.attributedText?.size() ?? .zero
        let x = name.frame.maxX + 10
        command.frame = CGRect(x: x, y: (bounds.height - commandSize.height) / 2, width: max(0, verdict.frame.minX - 8 - x), height: ceil(commandSize.height))
    }
}

@MainActor
final class BrainUnfixedRow: UIControl {
    private let line = UILabel()

    init(item: NeuralAccount.Unfixed, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString(
            string: "#\(item.number) ", attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.danger))
        text.append(
            NSAttributedString(
                string: item.title + "  ", attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label)))
        text.append(
            NSAttributedString(
                string: item.firstLine, attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
        line.attributedText = text
        line.numberOfLines = 2
        addSubview(line)
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = Localized.text("%1$@, %2$@", item.title, item.firstLine)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(28, BrainText.height(line.attributedText, width: size.width, lines: 2)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
    }
}
