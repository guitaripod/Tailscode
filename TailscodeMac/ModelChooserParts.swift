import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One chip in a strip — a machine's tab or a door — its name, a dot only when it has something
/// to say, and what it holds in the quieter register. The one in force wears the accent.
@MainActor
final class MachineChip: NSButton {
    private let onPress: () -> Void
    private let onInfo: ((NSView) -> Void)?

    init(
        title: String, count: Int, detail: String, dot: NSColor?, selected: Bool,
        onInfo: ((NSView) -> Void)? = nil,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.onInfo = onInfo
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        bezelStyle = .accessoryBarAction
        controlSize = .small
        state = selected ? .on : .off
        target = self
        action = #selector(pressed)
        toolTip = detail
        let ink = selected ? MacTheme.Color.accent : MacTheme.Color.label
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: selected ? MacTheme.Ramp.font(.panelLabel).bold : MacTheme.Ramp.font(.panelLabel),
                .foregroundColor: ink,
            ])
        if let dot {
            text.append(
                NSAttributedString(
                    string: " ●", attributes: [.font: MacTheme.Ramp.font(.gaugeCaption), .foregroundColor: dot]))
        }
        text.append(
            NSAttributedString(
                string: "  \(count)",
                attributes: [
                    .font: MacTheme.Ramp.font(.gaugeCaption),
                    .foregroundColor: MacTheme.Color.tertiaryLabel,
                ]))
        attributedTitle = text
        setAccessibilityLabel("\(title), \(detail)")
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress() }

    /// A right click asks what is behind the chip rather than choosing it.
    override func rightMouseDown(with event: NSEvent) {
        guard onInfo != nil else { return super.rightMouseDown(with: event) }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Localized.text("About %@…", title), action: #selector(info), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func info() { onInfo?(self) }
}

/// Chips in reading order, wrapped onto as many lines as the width asks for and placed by frame.
/// A stack view keeps every chip on one line, and so holds its window at least as wide as the
/// whole row; a flow lets the window be the width a person chose and grows a line instead.
@MainActor
final class ChipFlow: NSView {
    private var chips: [NSView] = []
    private var measuredWidth: CGFloat = 0
    private let gap = MacTheme.Spacing.xs

    nonisolated override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setChips(_ views: [NSView]) {
        for view in chips { view.removeFromSuperview() }
        chips = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: arrange(width: measuredWidth > 0 ? measuredWidth : .greatestFiniteMagnitude, placing: false))
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        arrange(width: bounds.width, placing: true)
    }

    /// Lays the chips out at `width` and answers the height they take. A chip wider than the
    /// whole strip gets a line of its own at the strip's width rather than running off its edge.
    @discardableResult
    private func arrange(width: CGFloat, placing: Bool) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for view in chips {
            let natural = view.intrinsicContentSize
            let size =
                natural.width == NSView.noIntrinsicMetric ? view.fittingSize : natural
            let chipWidth = min(size.width, width)
            if x > 0, x + chipWidth > width {
                x = 0
                y += line + gap
                line = 0
            }
            if placing {
                view.frame = NSRect(x: x, y: y, width: chipWidth, height: size.height)
            }
            x += chipWidth + gap
            line = max(line, size.height)
        }
        return chips.isEmpty ? 0 : y + line
    }
}

/// A wrapping label that measures its lines at the width it was given. A wrapping `NSTextField`
/// otherwise reports its text's width on one line, which either holds the window that wide or,
/// squeezed, keeps the height of one line and cuts the rest off.
@MainActor
final class FittedWrapLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(preferredMaxLayoutWidth - width) > 0.5 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}
