import AppKit
import MidgarCore
import TailscodeCore

/// Why a feature is in beta, as the popover's card: the title with the mark, the lead, what changed
/// when the person last looked at an older version, the paragraphs, what is solid and what is still
/// rough with a glyph per line, and the two actions. Every word is the catalog's; this arranges them
/// and draws a button that puts the report on the pasteboard. A view at the root says when the
/// pointer is on the card so it is not pulled away while it is read.
@MainActor
final class BetaCardViewController: NSViewController {
    private static let copiedFor: Duration = .milliseconds(1500)
    private static let width: CGFloat = 380

    var onHover: ((Bool) -> Void)?
    var onDone: (() -> Void)?

    private let feature: BetaFeature
    private let freshness: BetaFreshness
    private let reportLines: () -> [String]
    private let copyButton = RowKit.ActionButton(title: BetaWords.copyReport, action: {})
    private var copiedTicket = 0

    init(feature: BetaFeature, freshness: BetaFreshness, reportLines: @escaping () -> [String]) {
        self.feature = feature
        self.freshness = freshness
        self.reportLines = reportLines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var contentWidth: CGFloat { Self.width * MacTheme.UIScale.factor }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false
        build(into: column)
        let host = HoverView()
        host.onHover = { [weak self] inside in self?.onHover?(inside) }
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        view = host
    }

    private func build(into column: NSStackView) {
        let card = feature.card
        column.addArrangedSubview(heading(card))
        column.addArrangedSubview(body(card.lead, ink: MacTheme.Color.secondaryLabel))
        if freshness == .changed, !card.changes.isEmpty {
            column.addArrangedSubview(since(card.changes))
        }
        for paragraph in card.paragraphs {
            column.addArrangedSubview(body(paragraph, ink: MacTheme.Color.label))
        }
        if !card.works.isEmpty {
            column.addArrangedSubview(
                list(BetaWords.solid, lines: card.works, symbol: "checkmark.circle.fill", tone: .live))
        }
        if !card.rough.isEmpty {
            column.addArrangedSubview(
                list(BetaWords.rough, lines: card.rough, symbol: "circle.dotted", tone: .attention))
        }
        let actions = buttons()
        column.addArrangedSubview(actions)
        if let before = column.arrangedSubviews.dropLast().last {
            column.setCustomSpacing(MacTheme.Spacing.l, after: before)
        }
        actions.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
    }

    private func heading(_ card: BetaCard) -> NSView {
        let mark = BetaBadge(feature: feature, reportLines: { [] }, interactive: false)
        let title = NSTextField(wrappingLabelWithString: card.title)
        title.font = MacTheme.Ramp.font(.panelTitle)
        title.textColor = MacTheme.Color.label
        title.preferredMaxLayoutWidth = contentWidth - 2 * MacTheme.Spacing.l
        let stack = NSStackView(views: [mark, title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.s
        return stack
    }

    private func body(_ text: String, ink: NSColor, width: CGFloat? = nil) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.cardBody)
        label.textColor = ink
        label.preferredMaxLayoutWidth = width ?? contentWidth - 2 * MacTheme.Spacing.l
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.textColor = MacTheme.Color.label
        label.preferredMaxLayoutWidth = contentWidth - 2 * MacTheme.Spacing.l
        return label
    }

    private func since(_ changes: [BetaChange]) -> NSView {
        let stack = NSStackView(views: [sectionTitle(BetaWords.sinceYouLastLooked)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.xs
        for change in changes {
            stack.addArrangedSubview(body(change.line, ink: MacTheme.Color.label))
        }
        return stack
    }

    private func list(_ title: String, lines: [String], symbol: String, tone: ActivityTone) -> NSView {
        let stack = NSStackView(views: [sectionTitle(title)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.xs
        stack.setAccessibilityRole(.list)
        stack.setAccessibilityLabel(title)
        for line in lines {
            stack.addArrangedSubview(row(line, symbol: symbol, tone: tone))
        }
        return stack
    }

    private func row(_ line: String, symbol: String, tone: ActivityTone) -> NSView {
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        glyph.contentTintColor = tone.color
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let text = body(line, ink: MacTheme.Color.label, width: contentWidth - 2 * MacTheme.Spacing.l - 18 - MacTheme.Spacing.s)
        let stack = NSStackView(views: [glyph, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = MacTheme.Spacing.s
        return stack
    }

    private func buttons() -> NSView {
        copyButton.setAction { [weak self] in self?.copyReport() }
        copyButton.controlSize = .large
        let done = RowKit.ActionButton(title: BetaWords.gotIt) { [weak self] in self?.onDone?() }
        done.controlSize = .large
        done.bezelColor = MacTheme.Color.mark
        done.keyEquivalent = "\r"
        let stack = NSStackView(views: [copyButton, RowKit.spacer(), done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.s
        return stack
    }

    private func copyReport() {
        let report = BetaReport.compose(
            feature: feature, app: BetaEnvironment.appLine, system: BetaEnvironment.systemLine,
            lines: reportLines())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        MacHaptics.shared.play(.success)
        MidgarLog.info(
            "beta report copied feature=\(feature.rawValue) chars=\(report.count)", category: .ui)
        NSAccessibility.post(
            element: copyButton, notification: .announcementRequested,
            userInfo: [
                .announcement: BetaWords.reportCopied,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        copiedTicket += 1
        let ticket = copiedTicket
        copyButton.title = BetaWords.reportCopied
        Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFor)
            guard let self, self.copiedTicket == ticket else { return }
            self.copyButton.title = BetaWords.copyReport
        }
    }

    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }

        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
