import CodingAgentKit
import TailscodeCore
import UIKit

/// Where a task for an expert is written: the expert's pill, the words, and Send at the trailing
/// end, under the right thumb on an iPad held sideways.
@MainActor
final class ExpertComposerBar: UIView, UITextViewDelegate {
    var onSend: ((String) -> Void)?
    var onChange: (() -> Void)?

    let textView = UITextView()
    private let placeholder = UILabel()
    private let pill = UIButton(configuration: .gray())
    private let send = UIButton(type: .system)
    private let field = UIView()
    private var heightConstraint: NSLayoutConstraint!
    private var busy = false

    init(surface: UIColor = Theme.Color.secondaryBackground) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.backgroundColor = surface
        field.layer.borderWidth = 1 / max(UIScreen.main.scale, 1)
        field.layer.borderColor = Theme.Color.separator.cgColor
        field.layer.cornerRadius = 22
        field.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        var pillConfig = UIButton.Configuration.gray()
        pillConfig.cornerStyle = .capsule
        pillConfig.imagePadding = 6
        pillConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 10)
        pillConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = Theme.Ramp.font(.chip)
            return updated
        }
        pill.configuration = pillConfig
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        textView.font = Theme.Ramp.font(.composer)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = Theme.Color.label
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = Theme.Ramp.font(.composer)
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isAccessibilityElement = false

        var sendConfig = UIButton.Configuration.filled()
        sendConfig.cornerStyle = .capsule
        sendConfig.image = UIImage(
            systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        sendConfig.baseBackgroundColor = Theme.Color.accent
        sendConfig.baseForegroundColor = Theme.Color.onAccent
        send.configuration = sendConfig
        send.translatesAutoresizingMaskIntoConstraints = false
        send.accessibilityLabel = Localized.text("Send")
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)

        [pill, textView, placeholder, send].forEach(field.addSubview)
        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 7),
            pill.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -7),
            textView.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: Theme.Spacing.s),
            textView.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -Theme.Spacing.s),
            textView.topAnchor.constraint(equalTo: field.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 11),
            send.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6),
            send.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -6),
            send.widthAnchor.constraint(equalToConstant: 32),
            send.heightAnchor.constraint(equalToConstant: 32),
        ])
        sync()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: ExpertComposerBar, _) in
            bar.field.layer.borderColor = Theme.Color.separator.resolvedColor(with: bar.traitCollection).cgColor
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The expert the bar writes to, worn in its pill: the mark, the name, and the model.
    func show(_ row: ExpertRow, modelWord: String?) {
        pill.configuration?.image = ExpertStyle.mark(row, side: 22, traits: traitCollection)
        pill.configuration?.title = [row.expert.name, modelWord].compactMap { $0 }.joined(separator: " · ")
        placeholder.text = ExpertWords.newTaskFor(row.expert.name)
        textView.accessibilityLabel = ExpertWords.newTaskFor(row.expert.name)
    }

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            sync()
        }
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        sync()
    }

    func textViewDidChange(_ textView: UITextView) {
        sync()
        onChange?()
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !busy else { return }
        Theme.Haptics.tap()
        onSend?(words)
    }

    private func sync() {
        placeholder.isHidden = !text.isEmpty
        send.isEnabled = !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.configuration?.showsActivityIndicator = busy
        let width = max(textView.bounds.width, 120)
        let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximum: CGFloat = 180
        heightConstraint.constant = min(max(44, fitted), maximum)
        textView.isScrollEnabled = fitted > maximum
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sync()
    }
}
