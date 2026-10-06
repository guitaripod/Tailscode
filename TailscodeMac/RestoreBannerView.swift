import AppKit
import TailscodeCore

/// The capsule a safe restore floats across the top of the pane area after a launch that did not
/// close normally: how many chats were brought back paused, and the two ways to wake them.
///
/// It is not a toast, because it has to wait for the person, and not a sheet, because the window
/// behind it is usable. It is one glass capsule in a glass container — the floating-control layer
/// the design contract gives glass to, like the overflow strip at the canvas's foot — holding its
/// sentence, the two buttons and a dismiss control, and the pane area shows around it. It sits at
/// the top so it never covers a pane's composer.
@MainActor
final class RestoreBannerView: NSView {
    var onResumeAll: (() -> Void)?
    var onResumeOneByOne: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let symbol = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var count = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        symbol.image = NSImage(
            systemSymbolName: "pause.circle", accessibilityDescription: nil)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.setContentHuggingPriority(.required, for: .horizontal)

        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let resumeAll = RowKit.ActionButton(title: Localized.text("Resume all")) {
            [weak self] in self?.onResumeAll?()
        }
        let oneByOne = RowKit.ActionButton(title: Localized.text("Resume one by one")) {
            [weak self] in self?.onResumeOneByOne?()
        }
        for button in [resumeAll, oneByOne] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let dismiss = RowKit.ActionButton(title: "") { [weak self] in self?.onDismiss?() }
        dismiss.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: Localized.text("Close"))
        dismiss.isBordered = false
        dismiss.toolTip = Localized.text("Close")
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [symbol, label, resumeAll, oneByOne, dismiss])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.setCustomSpacing(MacTheme.Spacing.s, after: resumeAll)
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        let capsule = MacTheme.glass(around: row, cornerRadius: MacTheme.Radius.card)
        let group = MacTheme.glassGroup()
        group.contentView = capsule
        addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: leadingAnchor),
            group.trailingAnchor.constraint(equalTo: trailingAnchor),
            group.topAnchor.constraint(equalTo: topAnchor),
            group.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            capsule.topAnchor.constraint(equalTo: group.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The sentence is Core's, so every desk says the same words for the same count.
    func setCount(_ count: Int) {
        self.count = count
        let text = RestorePlan(mode: .parked(bannerCount: count), unclean: true).bannerText ?? ""
        label.stringValue = text
        setAccessibilityLabel(text)
    }

    var text: String { label.stringValue }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    @objc private func themeChanged() {
        restyle()
    }

    private func restyle() {
        label.font = MacTheme.Ramp.font(.cardBody)
        label.textColor = MacTheme.Color.onGlass
        symbol.contentTintColor = MacTheme.Color.warning
    }
}
