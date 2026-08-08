import AppKit
import CodingAgentKit
import TailscodeCore

extension GitTone {
    var color: NSColor {
        switch self {
        case .added: return MacTheme.Color.success
        case .removed: return MacTheme.Color.danger
        case .changed: return MacTheme.Color.info
        case .untracked: return MacTheme.Color.tertiaryLabel
        case .conflict: return MacTheme.Color.warning
        case .neutral: return MacTheme.Color.secondaryLabel
        }
    }
}

/// What the repository behind this conversation is doing, in a popover off the branch on the band
/// — the fact is where the question was asked, so the whole answer belongs there.
///
/// Read-only, like every git surface in this app: the state a change lands in is the thing a
/// transcript cannot tell you, while staging or committing from a remote client is a change nobody
/// reviewed on the machine that has to live with it. Clicking a path opens what actually changed
/// in it; clicking a commit opens what it did.
@MainActor
final class GitPanelViewController: NSViewController {
    private let state: GitState
    private let chatTitle: String
    private let patch: @Sendable (GitRow) async -> String?
    private let commit: @Sendable (GitCommitRow) async -> String?
    private var openDiff: ((String, String, @escaping @Sendable () async -> String?) -> Void)?

    init(
        state: GitState, title: String, patch: @escaping @Sendable (GitRow) async -> String?,
        commit: @escaping @Sendable (GitCommitRow) async -> String?,
        openDiff: @escaping (String, String, @escaping @Sendable () async -> String?) -> Void
    ) {
        self.state = state
        self.chatTitle = title
        self.patch = patch
        self.commit = commit
        self.openDiff = openDiff
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        column.addArrangedSubview(header())
        for section in state.sections { column.addArrangedSubview(files(section)) }
        if let note {
            column.addArrangedSubview(
                RowKit.wrapping(
                    note, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        if !state.commits.isEmpty { column.addArrangedSubview(commits()) }

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        let scroll = NSScrollView()
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 580),
        ])
        view = container
    }

    private var note: String? {
        if !state.isRepository {
            return Localized.text("This conversation is not working inside a git repository.")
        }
        if state.truncated, state.hiddenCount > 0 {
            return Localized.text("%d more changed paths are not listed.", state.hiddenCount)
        }
        if state.isClean {
            return Localized.text("Nothing has been touched since the last commit.")
        }
        return nil
    }

    /// The branch, what it owes the upstream, the working tree in one line — and above all of it,
    /// when the repository is mid-merge, the line that says every other number is a snapshot of a
    /// manoeuvre rather than of work.
    private func header() -> NSView {
        let name = RowKit.label(
            chatTitle, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
        let branch = RowKit.label(
            state.title, font: .systemFont(ofSize: 26 * MacTheme.UIScale.factor, weight: .semibold),
            color: MacTheme.Color.label)
        branch.lineBreakMode = .byTruncatingMiddle
        let sync = RowKit.label(
            state.sync, font: MacTheme.Font.body(), color: state.syncTone.color)
        let summary = RowKit.label(
            state.summary, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
        summary.attributedStringValue = Self.tinted(
            state.summaryParts, font: MacTheme.Font.caption())

        var views: [NSView] = [name, branch, sync, summary]
        if let alert = state.alert {
            let banner = RowKit.wrapping(
                alert, font: MacTheme.Font.emphasis(), color: MacTheme.Color.warning)
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = MacTheme.Color.warning.withAlphaComponent(0.14).cgColor
            box.layer?.cornerRadius = MacTheme.Radius.control
            box.layer?.cornerCurve = .continuous
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: box.topAnchor, constant: MacTheme.Spacing.s),
                banner.bottomAnchor.constraint(
                    equalTo: box.bottomAnchor, constant: -MacTheme.Spacing.s),
                banner.leadingAnchor.constraint(
                    equalTo: box.leadingAnchor, constant: MacTheme.Spacing.s),
                banner.trailingAnchor.constraint(
                    equalTo: box.trailingAnchor, constant: -MacTheme.Spacing.s),
            ])
            views.append(box)
        }
        for fact in state.facts {
            let key = RowKit.label(
                fact.label, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
            key.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let value = RowKit.label(
                fact.value, font: MacTheme.Font.caption(),
                color: fact.tone == .neutral ? MacTheme.Color.label : fact.tone.color)
            value.lineBreakMode = .byTruncatingMiddle
            value.alignment = .right
            let row = NSStackView(views: [key, value])
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.m
            row.distribution = .fill
            views.append(row)
        }
        return card(views)
    }

    private func files(_ section: GitSection) -> NSView {
        var views: [NSView] = [
            heading(section.title, trailing: "\(section.rows.count)", tone: section.tone)
        ]
        for row in section.rows {
            let glyph = RowKit.label(
                row.kind.glyph, font: MacTheme.Font.mono(11), color: row.tone.color)
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            let name = RowKit.label(
                row.name, font: MacTheme.Font.body(), color: MacTheme.Color.label)
            name.lineBreakMode = .byTruncatingMiddle
            let place = RowKit.label(
                row.original.map { "← \($0)" } ?? row.folder, font: MacTheme.Font.caption(),
                color: MacTheme.Color.tertiaryLabel)
            place.lineBreakMode = .byTruncatingHead
            let counts = NSTextField(labelWithAttributedString: Self.counts(row))
            counts.translatesAutoresizingMaskIntoConstraints = false
            counts.setContentHuggingPriority(.required, for: .horizontal)
            let line = NSStackView(views: [glyph, name, place, NSView(), counts])
            line.orientation = .horizontal
            line.spacing = MacTheme.Spacing.s
            line.toolTip = row.spoken
            views.append(ClickRow(line) { [weak self] in self?.open(row) })
        }
        return card(views)
    }

    private func commits() -> NSView {
        var views: [NSView] = [
            heading(Localized.text("RECENT COMMITS"), trailing: nil, tone: .neutral)
        ]
        for entry in state.commits.prefix(20) {
            let hash = RowKit.label(
                entry.short, font: MacTheme.Font.mono(11),
                color: entry.isHead ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel)
            hash.setContentHuggingPriority(.required, for: .horizontal)
            let subject = RowKit.label(
                entry.subject, font: MacTheme.Font.body(), color: MacTheme.Color.label)
            subject.lineBreakMode = .byTruncatingTail
            let age = RowKit.label(
                entry.age, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
            age.setContentHuggingPriority(.required, for: .horizontal)
            let line = NSStackView(views: [hash, subject, NSView(), age])
            line.orientation = .horizontal
            line.spacing = MacTheme.Spacing.s
            var tip = [entry.short, entry.author, entry.age]
            if !entry.refs.isEmpty { tip.append(entry.refs.joined(separator: ", ")) }
            line.toolTip = tip.joined(separator: " · ")
            views.append(ClickRow(line) { [weak self] in self?.open(entry) })
        }
        return card(views)
    }

    private func open(_ row: GitRow) {
        let patch = patch
        openDiff?(row.name, row.path, { await patch(row) })
    }

    private func open(_ entry: GitCommitRow) {
        let commit = commit
        openDiff?(
            entry.subject, "\(entry.short) · \(entry.author) · \(entry.age)",
            { await commit(entry) })
    }

    /// Two numbers that mean opposite things, so they are never one colour — and nothing at all
    /// for a file with no lines to count, because a `+0` is a number a reader has to dismiss.
    private static func counts(_ row: GitRow) -> NSAttributedString {
        guard row.hasCounts else {
            return NSAttributedString(
                string: row.detail,
                attributes: [
                    .foregroundColor: MacTheme.Color.tertiaryLabel,
                    .font: MacTheme.Font.caption(),
                ])
        }
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: 11 * MacTheme.UIScale.factor, weight: .medium)
        if row.insertions > 0 {
            text.append(
                NSAttributedString(
                    string: "+\(GitState.number(row.insertions))",
                    attributes: [.foregroundColor: MacTheme.Color.success, .font: font]))
        }
        if row.deletions > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(
                NSAttributedString(
                    string: "−\(GitState.number(row.deletions))",
                    attributes: [.foregroundColor: MacTheme.Color.danger, .font: font]))
        }
        return text
    }

    /// A line whose clauses mean different things, each drawn in the colour of what it counts.
    static func tinted(_ parts: [GitBadgePart], font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for part in parts {
            if text.length > 0 {
                text.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
            }
            text.append(
                NSAttributedString(
                    string: part.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: part.tone == .neutral
                            ? MacTheme.Color.secondaryLabel : part.tone.color,
                    ]))
        }
        return text
    }

    private func heading(_ text: String, trailing: String?, tone: GitTone) -> NSView {
        let title = RowKit.label(
            text, font: MacTheme.Font.emphasis(),
            color: tone == .neutral ? MacTheme.Color.label : tone.color)
        var views: [NSView] = [title, NSView()]
        if let trailing {
            views.append(
                RowKit.label(
                    trailing, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }

    private func card(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.xs
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        stack.layer?.cornerRadius = MacTheme.Radius.card
        stack.layer?.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where view is NSStackView || view is ClickRow {
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * MacTheme.Spacing.s).isActive = true
        }
        return stack
    }
}

/// A row that answers a click without becoming a button: a push button would draw a bezel over the
/// card and take the row's own layout, and every row here is a path, not a control.
@MainActor
final class ClickRow: NSView {
    private let action: () -> Void

    init(_ content: NSView, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = MacTheme.Color.separator.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

/// One file's change, or one commit's, in a window of its own: a diff is read rather than glanced
/// at, and a popover that closes on the next click is the wrong container for it.
@MainActor
final class GitDiffWindowController: NSWindowController {
    private let load: @Sendable () async -> String?
    private let text = NSTextView()

    init(title: String, subtitle: String, load: @escaping @Sendable () async -> String?) {
        self.load = load
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: false)
        window.title = title
        window.subtitle = subtitle
        window.isReleasedWhenClosed = false
        super.init(window: window)

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = MacTheme.Color.codeBackground
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        window.contentView = scroll
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { [weak self] in
            guard let self else { return }
            let patch = await self.load()
            guard let patch else {
                self.text.textStorage?.setAttributedString(
                    NSAttributedString(
                        string: Localized.text("This server could not produce a diff for that."),
                        attributes: [
                            .foregroundColor: MacTheme.Color.secondaryLabel,
                            .font: MacTheme.Font.body(),
                        ]))
                return
            }
            self.text.textStorage?.setAttributedString(Self.render(patch))
        }
    }

    /// The gutter is part of the line rather than a column beside it: a text view that scrolls
    /// horizontally would slide the code out from under a separate column and leave the numbers
    /// pointing at nothing.
    static func render(_ patch: String) -> NSAttributedString {
        let mono = MacTheme.Font.mono(11)
        let lines = GitPatchReader.lines(patch)
        guard !lines.isEmpty else {
            return NSAttributedString(
                string: Localized.text("No textual change to show."),
                attributes: [.foregroundColor: MacTheme.Color.secondaryLabel, .font: mono])
        }
        let result = NSMutableAttributedString()
        for line in lines {
            let gutter = line.kind == .deletion ? line.oldLine : line.newLine
            let number = gutter.map { String(format: "%5d ", $0) } ?? "      "
            result.append(
                NSAttributedString(
                    string: number,
                    attributes: [.foregroundColor: MacTheme.Color.tertiaryLabel, .font: mono]))
            let sign: String
            let colour: NSColor
            switch line.kind {
            case .addition:
                sign = "+ "
                colour = MacTheme.Color.success
            case .deletion:
                sign = "− "
                colour = MacTheme.Color.danger
            case .hunk:
                sign = ""
                colour = MacTheme.Color.info
            case .meta:
                sign = ""
                colour = MacTheme.Color.tertiaryLabel
            case .context:
                sign = "  "
                colour = MacTheme.Color.secondaryLabel
            }
            result.append(
                NSAttributedString(
                    string: sign + line.text + "\n",
                    attributes: [.foregroundColor: colour, .font: mono]))
        }
        return result
    }
}
