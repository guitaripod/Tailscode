import TailscodeCore
import UIKit

@MainActor
struct SlashCommand {
    /// Stable across rebuilds of the list, so a selection survives a keystroke that only
    /// reorders the rows.
    let id: String
    /// The words this row answers to beyond its title — `/m` for Model, `/retry` for Regenerate.
    let keywords: [String]
    let title: String
    let subtitle: String
    let symbol: String
    /// Offsets into `title` the query matched, for highlighting the letters that were typed.
    var highlight: [Int] = []
    /// The server's own hint for what follows the command, shown as a trailing chip so the
    /// shape of the argument is legible before the space is typed.
    var argumentHint: String?
    /// Where a non-builtin command came from — a plugin, a project, an MCP server.
    var badge: String?
    /// Server commands are tinted; app actions stay neutral, so the two never read as one list.
    var runsOnServer: Bool = false
    let run: () -> Void
}

/// A titled run of commands. The split exists because `/` addresses two different machines: rows
/// that act on this app, and rows the agent itself will resolve — plus the short list of commands
/// this device actually reaches for, which outranks both.
@MainActor
struct SlashCommandSection {
    let title: String
    let commands: [SlashCommand]
}

/// What the person needs to see right now. Naming a command wants a list; filling in its arguments
/// wants that one command's hint and nothing else; a word the catalog does not have wants to be
/// told so, rather than having the list vanish under the caret.
@MainActor
enum SlashPaletteContent {
    case commands([SlashCommandSection])
    case arguments(command: SlashCommand, typed: String)
    /// `wording` is the whole sentence, composed by `SlashPresentation.noMatchWording` — a
    /// surface with no project says so, because a command that exists in a repository could not
    /// have been resolved from here either.
    case noMatch(wording: String, browse: SlashCommand?)
}

/// A floating command list shown above the composer when the draft begins with `/`.
/// The glass sits behind non-interactive; the rows are siblings on top so touches land
/// (iOS 26 `UIGlassEffect` swallows touches routed through a visual-effect content view).
@MainActor
final class SlashCommandPalette: UIView {
    private let glass = Theme.Glass.view(interactive: false)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var heightCap: NSLayoutConstraint!
    private var rows: [SlashRowView] = []
    private var selection: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 20
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        addSubview(glass)

        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        let hugContent = hugContentConstraint()
        heightCap = heightAnchor.constraint(lessThanOrEqualToConstant: 320)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor),

            hugContent,
            heightCap,
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    /// Shrinks the palette to its content when the list is short. Its priority must stay below the
    /// rows' compression resistance (750): any higher and it outranks their intrinsic heights, so a
    /// catalog taller than the gap between the navigation bar and the composer gets squashed —
    /// rows collapsing onto each other instead of scrolling.
    private func hugContentConstraint() -> NSLayoutConstraint {
        let constraint = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        constraint.priority = UILayoutPriority(700)
        return constraint
    }

    /// A backstop only: the owner constrains the palette's top to the safe area, which is what
    /// actually keeps a long catalog from growing up behind the navigation bar. This keeps the
    /// list from dominating the screen on a tall device even when there is room for it.
    override func layoutSubviews() {
        super.layoutSubviews()
        if let window {
            let cap = window.bounds.height * 0.55
            if heightCap.constant != cap { heightCap.constant = cap }
        }
    }

    func update(with content: SlashPaletteContent) {
        let previous = selection.flatMap { rows.indices.contains($0) ? rows[$0].command.id : nil }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        switch content {
        case .commands(let sections):
            let live = sections.filter { !$0.commands.isEmpty }
            let titled = live.count > 1
            for section in live {
                if titled, !section.title.isEmpty {
                    stack.addArrangedSubview(makeHeader(section.title))
                }
                for command in section.commands { stack.addArrangedSubview(makeRow(command)) }
            }
        case .arguments(let command, let typed):
            stack.addArrangedSubview(SlashArgumentView(command: command, typed: typed))
        case .noMatch(let wording, let browse):
            stack.addArrangedSubview(makeNoMatch(wording))
            if let browse { stack.addArrangedSubview(makeRow(browse)) }
        }

        selection = previous.flatMap { id in rows.firstIndex { $0.command.id == id } } ?? (rows.isEmpty ? nil : 0)
        applySelection(scroll: false)
        scroll.setContentOffset(.zero, animated: false)
    }

    var hasSelectableRows: Bool { !rows.isEmpty }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = selection ?? 0
        let count = rows.count
        selection = ((current + delta) % count + count) % count
        applySelection(scroll: true)
        Theme.Haptics.selection()
    }

    /// Runs the highlighted row. Returns false when nothing is highlighted, so a hardware Return
    /// falls through to sending the draft rather than doing nothing.
    @discardableResult
    func activateSelection() -> Bool {
        guard let index = selection, rows.indices.contains(index) else { return false }
        rows[index].command.run()
        return true
    }

    private func applySelection(scroll shouldScroll: Bool) {
        for (index, row) in rows.enumerated() { row.isSelected = index == selection }
        guard shouldScroll, let index = selection, rows.indices.contains(index) else { return }
        let row = rows[index]
        layoutIfNeeded()
        scroll.scrollRectToVisible(
            row.convert(row.bounds, to: scroll).insetBy(dx: 0, dy: -8), animated: true)
    }

    private func makeHeader(_ title: String) -> UIView {
        let label = UILabel()
        label.text = title.uppercased()
        label.font = Theme.Ramp.font(.hint)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.onGlassSecondary
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        return container
    }

    private func makeRow(_ command: SlashCommand) -> SlashRowView {
        let row = SlashRowView(command: command)
        row.onTap = { command.run() }
        rows.append(row)
        return row
    }

    /// A word the catalog does not have keeps the palette on screen saying so. Letting the list
    /// vanish reads as the app losing track of the draft, when in fact the words are about to be
    /// sent as an ordinary message — which is the one thing worth saying here.
    private func makeNoMatch(_ wording: String) -> UIView {
        let container = UIView()
        let title = UILabel()
        title.text = wording
        title.font = Theme.Ramp.font(.rowTitle)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.onGlass
        let detail = UILabel()
        detail.text = String(localized: "Send it and it goes as an ordinary message.")
        detail.font = Theme.Ramp.font(.rowDetail)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.onGlassSecondary
        detail.numberOfLines = 2

        let column = UIStackView(arrangedSubviews: [title, detail])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        return container
    }
}

/// One command in the palette. A control rather than a configured button so the matched letters
/// can be tinted, the server's argument hint can sit inline after the name, and a keyboard
/// selection can wear a background — none of which `UIButton.Configuration` will carry together.
@MainActor
final class SlashRowView: UIControl {
    let command: SlashCommand
    var onTap: (() -> Void)?

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let highlightLayer = UIView()

    init(command: SlashCommand) {
        self.command = command
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { highlightLayer.alpha = isSelected ? 1 : 0 }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    private func build() {
        let tint = command.runsOnServer ? Theme.Color.accent : Theme.Color.onGlassSecondary

        highlightLayer.backgroundColor = Theme.Color.accent.withAlphaComponent(0.16)
        highlightLayer.layer.cornerRadius = 10
        highlightLayer.layer.cornerCurve = .continuous
        highlightLayer.alpha = 0
        highlightLayer.isUserInteractionEnabled = false
        highlightLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightLayer)

        icon.image = UIImage(
            systemName: command.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.attributedText = Self.attributedTitle(command)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.text = subtitleText
        subtitleLabel.font = Theme.Ramp.font(.rowDetail)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.onGlassSecondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitleText.isEmpty

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 1
        text.alignment = .fill

        let line = UIStackView(arrangedSubviews: [icon, text])
        line.axis = .horizontal
        line.spacing = 12
        line.alignment = .center
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            highlightLayer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlightLayer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlightLayer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlightLayer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = command.title
        accessibilityHint = subtitleText.isEmpty ? nil : subtitleText
    }

    private var subtitleText: String {
        [command.badge, command.subtitle]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    /// The typed letters are tinted inside the command's own name, so a fuzzy match explains
    /// itself: `/gm` visibly reaches `git:merge` through the g and the m. The server's argument
    /// hint follows inline rather than as a trailing chip — a chip wide enough to hold
    /// `<what the summary must keep>` would eat the description it sits beside.
    private static func attributedTitle(_ command: SlashCommand) -> NSAttributedString {
        let base = Theme.Ramp.font(.rowTitle)
        let string = NSMutableAttributedString(
            string: command.title,
            attributes: [.font: base, .foregroundColor: Theme.Color.onGlass])
        let bold =
            UIFont(
                descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor,
                size: base.pointSize)
        let count = command.title.count
        for offset in command.highlight where offset >= 0 && offset < count {
            string.addAttributes(
                [.foregroundColor: Theme.Color.accent, .font: bold],
                range: NSRange(location: offset, length: 1))
        }
        if let hint = command.argumentHint, !hint.isEmpty {
            string.append(
                NSAttributedString(
                    string: " \(hint)",
                    attributes: [
                        .font: Theme.Ramp.font(.rowNote),
                        .foregroundColor: Theme.Color.onGlassSecondary,
                    ]))
        }
        return string
    }
}

/// The second half of a slash invocation: the command is settled and the person is writing its
/// arguments. Showing the same list again would be noise — what is wanted is this command's own
/// hint and what it does, held on screen while the argument is typed.
@MainActor
final class SlashArgumentView: UIView {
    init(command: SlashCommand, typed: String) {
        super.init(frame: .zero)
        build(command: command, typed: typed)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build(command: SlashCommand, typed: String) {
        let icon = UIImageView(
            image: UIImage(
                systemName: command.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)))
        icon.tintColor = command.runsOnServer ? Theme.Color.accent : Theme.Color.onGlassSecondary
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.attributedText = Self.signature(command: command, typed: typed)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        let detail = UILabel()
        detail.text = command.subtitle.isEmpty ? nil : command.subtitle
        detail.font = Theme.Ramp.font(.rowDetail)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.onGlassSecondary
        detail.numberOfLines = 2
        detail.isHidden = command.subtitle.isEmpty

        let column = UIStackView(arrangedSubviews: [title, detail])
        column.axis = .vertical
        column.spacing = 2
        column.alignment = .leading

        let line = UIStackView(arrangedSubviews: [icon, column])
        line.axis = .horizontal
        line.spacing = 12
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    /// `/goal ‹condition›` — the command in its own colour, and the part still to be written as
    /// the server described it. Once something is typed the hint gives way, so the line stops
    /// asking for what is already there.
    private static func signature(command: SlashCommand, typed: String) -> NSAttributedString {
        let name = NSMutableAttributedString(
            string: command.title,
            attributes: [
                .font: Theme.Ramp.font(.rowTitle),
                .foregroundColor: command.runsOnServer ? Theme.Color.accent : Theme.Color.onGlass,
            ])
        let trailing =
            typed.isEmpty
            ? (command.argumentHint.map { " \($0)" } ?? "")
            : " \(typed)"
        guard !trailing.isEmpty else { return name }
        name.append(
            NSAttributedString(
                string: trailing,
                attributes: [
                    .font: Theme.Ramp.font(.code),
                    .foregroundColor: typed.isEmpty
                        ? Theme.Color.onGlassSecondary : Theme.Color.onGlass,
                ]))
        return name
    }
}
