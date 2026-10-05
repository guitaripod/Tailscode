import AppKit
import TailscodeCore

/// The strip a safe restore leaves across the top of the pane area after a launch that did not
/// close normally: how many chats were brought back paused, and the two ways to wake them.
///
/// It is not a toast, because it has to wait for the person, and not a sheet, because the window
/// behind it is usable. The strip is content — opaque, in the palette — and only its two buttons
/// float in a glass capsule, the floating-control layer the design contract gives glass to. It sits
/// at the top so it never covers a pane's composer.
@MainActor
final class RestoreBannerView: NSView {
    var onResumeAll: (() -> Void)?
    var onResumeOneByOne: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let symbol = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let rule = NSView()
    private(set) var count = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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
        let buttons = NSStackView(views: [resumeAll, oneByOne])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        buttons.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.xs,
            right: MacTheme.Spacing.s)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let capsule = MacTheme.glass(around: buttons, cornerRadius: 16)
        capsule.setContentHuggingPriority(.required, for: .horizontal)
        capsule.setContentCompressionResistancePriority(.required, for: .horizontal)

        let dismiss = RowKit.ActionButton(title: "") { [weak self] in self?.onDismiss?() }
        dismiss.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: Localized.text("Close"))
        dismiss.isBordered = false
        dismiss.toolTip = Localized.text("Close")
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [symbol, label, capsule, dismiss])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.l),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            row.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
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

    override var wantsUpdateLayer: Bool { true }

    /// Layer colours are `CGColor`s and keep the appearance they were made in, so they are made
    /// again whenever the appearance or the palette changes.
    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        rule.layer?.backgroundColor = MacTheme.Color.separator.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    @objc private func themeChanged() {
        restyle()
    }

    private func restyle() {
        label.font = MacTheme.Ramp.font(.cardBody)
        label.textColor = MacTheme.Color.label
        symbol.contentTintColor = MacTheme.Color.warning
        needsDisplay = true
        updateLayer()
    }
}
