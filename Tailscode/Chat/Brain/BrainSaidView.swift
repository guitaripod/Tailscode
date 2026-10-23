import TailscodeCore
import UIKit

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
