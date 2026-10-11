import AppKit
import TailscodeCore

/// A pane that holds a conversation and spends nothing on it: no stream, no clock. It says whose
/// conversation it is, what the chat list last heard about it, and the last words a glance read
/// from it, dimmed and dated so they are never mistaken for live ones — and offers to resume.
///
/// Everything on it comes from what the window already has: the face from the listing the chat
/// list polls, the words from a glance kept in memory for ten minutes. A needs-you or a finish
/// reaches it through the listing and the turn-wait machinery, never through a stream of its own.
@MainActor
final class ParkedFaceView: NSView {
    var onResume: (() -> Void)?

    private let badge = ActivityBadgeView(pointSize: 14)
    private let titleLabel = NSTextField(labelWithString: "")
    private let densityLabel = NSTextField(labelWithString: "")
    private let tailLabel = NSTextField(wrappingLabelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var resume = RowKit.ActionButton(title: Localized.text("Resume")) {
        [weak self] in self?.onResume?()
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        build()
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.canvas.cgColor
    }

    private func build() {
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        densityLabel.stringValue = Localized.text("Paused")
        tailLabel.maximumNumberOfLines = 3
        tailLabel.lineBreakMode = .byWordWrapping
        tailLabel.cell?.truncatesLastVisibleLine = true
        tailLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        let heading = NSStackView(views: [badge, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = MacTheme.Spacing.s
        let column = NSStackView(views: [heading, densityLabel, detailLabel, tailLabel, ageLabel, resume])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MacTheme.Spacing.s
        column.setCustomSpacing(MacTheme.Spacing.m, after: ageLabel)
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            column.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: MacTheme.Spacing.l),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            tailLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, constant: -24),
        ])
    }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        titleLabel.font = MacTheme.Ramp.font(.cardTitle)
        titleLabel.textColor = MacTheme.Color.label
        densityLabel.font = MacTheme.Ramp.font(.pill)
        densityLabel.textColor = MacTheme.Color.secondaryLabel
        detailLabel.font = MacTheme.Ramp.font(.panelDetail)
        detailLabel.textColor = MacTheme.Color.secondaryLabel
        tailLabel.font = MacTheme.Ramp.font(.cardBody)
        tailLabel.textColor = MacTheme.Color.secondaryLabel
        tailLabel.alphaValue = 0.7
        ageLabel.font = MacTheme.Ramp.font(.rowStamp)
        ageLabel.textColor = MacTheme.Color.tertiaryLabel
        needsDisplay = true
    }

    /// Draws the paused face. `detail` is why it is paused when that is not the person's own
    /// choice — a safe restore after a launch that did not close normally.
    func render(
        title: String, activity: ActivityKind?, lastWords: String?, readAt: Date?,
        detail: String?, index: Int, of count: Int
    ) {
        titleLabel.stringValue = title
        badge.activity = activity
        badge.isHidden = activity == nil
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        let words = lastWords?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tailLabel.stringValue = words
        tailLabel.isHidden = words.isEmpty
        if let readAt, !words.isEmpty {
            ageLabel.stringValue = SessionRowModel.age(of: readAt)
            ageLabel.isHidden = false
        } else {
            ageLabel.isHidden = true
        }
        var spoken = [
            Localized.text("Pane %@ of %@", "\(index)", "\(count)"), title, Localized.text("Paused"),
        ]
        if let activity { spoken.append(activity.spoken) }
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }

    override func accessibilityChildren() -> [Any]? { [resume] }
}
