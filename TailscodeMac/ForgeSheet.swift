import AppKit
import TailscodeCore

/// The forge, opened over the work rather than beside it.
///
/// A render is a task you start, watch and collect — not a place you work — so it does not earn half
/// of a window the way a second conversation does. It used to take a pane: the transcript lost its
/// width to a surface nobody types into for four minutes, and the pane stayed behind afterwards.
/// This is the same board as a sheet over the main window, so the conversation is untouched behind
/// it and comes back whole the moment it closes.
///
/// Closing may never stop a render. The job, its socket and the board live in ``ForgeRunner``, so
/// this sheet is only the view: it says so while a render is out (`ForgeSurface.dismissNote`) and
/// reopening finds the same render exactly where it was.
///
/// The heading is the sheet's rather than the board's. A pane had no chrome to hold a title, so the
/// board carried what a render costs as a line tucked under the renderer row; a sheet has a heading,
/// and the same sentence twice sixty pixels apart reads as two facts.
@MainActor
final class ForgeSheet {
    private static var active: [ForgeSheet] = []

    /// The one that is up, for the headless driver and for anything that wants to know whether the
    /// surface is on screen at all.
    static var current: ForgeSheet? { active.last }

    private let sheet: NSWindow
    private let slot = ForgeSlotView()
    private let heading = NSTextField(labelWithString: ForgeSurface.title)
    private let subtitle = NSTextField(wrappingLabelWithString: ForgeSurface.subtitle)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    /// The sheet's own surface. The board paints the theme's canvas edge to edge, so the heading and
    /// the way out have to stand on the same ground rather than on whatever AppKit puts behind a
    /// window — with a palette in force those are two different colours, and the seam shows.
    private let ground = RowKit.Ground(frame: .zero)
    private var keyMonitor: Any?

    @discardableResult
    static func present(on host: NSWindow) -> ForgeSheet {
        if let open = current {
            open.raise()
            return open
        }
        ForgeRunner.shared.prepare()
        let made = ForgeSheet(near: host)
        active.append(made)
        host.beginSheet(made.sheet) { _ in
            made.release()
            active.removeAll { $0 === made }
        }
        made.slot.focusPrompt()
        return made
    }

    private init(near host: NSWindow) {
        sheet = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: ForgeSurface.preferredWidth,
                height: Self.height(near: host)),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = ForgeSurface.title
        sheet.contentMinSize = NSSize(
            width: ForgeSurface.minimumWidth, height: ForgeSurface.minimumHeight)

        sheet.contentView = makeContent()
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        slot.onChange = { [weak self] in self?.drawFooter() }
        drawFooter()
        installKeyMonitor()
    }

    /// The board fills the sheet; the heading above it and the way out below it are the sheet's own,
    /// because a sheet has no title bar to carry either.
    ///
    /// A stack would give the board only its intrinsic height and hand the slack to whichever gravity
    /// area AppKit felt like, so the three parts are pinned by hand: the heading and the way out take
    /// what they need and the board takes everything left.
    private func makeContent() -> NSView {
        let header = makeHeader()
        let footer = makeFooter()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, slot, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            slot.topAnchor.constraint(equalTo: header.bottomAnchor),
            footer.topAnchor.constraint(equalTo: slot.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        claimTheSlack(header: header, footer: footer)
        content.addSubview(ground, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    /// Which of the three takes the height the window has left over. Pinning them end to end fixes
    /// the total and nothing else: a stack's own bottom edge is an inequality at priority 250 and the
    /// board has no intrinsic height at all, so the engine could as happily grow the heading as the
    /// board — layout that happens to look right and reports itself ambiguous, which is the state
    /// that moves on its own the first time anything above it changes size. `setHuggingPriority` is
    /// the one that matters here: a stack view's content hugging is a different property and does not
    /// touch those edge constraints.
    private func claimTheSlack(header: NSStackView, footer: NSStackView) {
        for stack in [header, footer] {
            stack.setHuggingPriority(.required, for: .vertical)
            stack.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        slot.setContentHuggingPriority(.init(1), for: .vertical)
        slot.setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    private func makeHeader() -> NSStackView {
        let header = NSStackView(views: [heading, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = MacTheme.Spacing.xs
        header.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.l)
        return header
    }

    /// The way out, under the sentence that says what closing does. The button carries no key
    /// equivalent: Escape and Enter both belong to the board while the sheet is up — the first
    /// collapses an expanded section before it closes anything, the second activates the row under
    /// the cursor — and a key equivalent would take either of them first.
    ///
    /// The note is a column above the row rather than a label beside it, because a wrapping label in
    /// a horizontal stack has no width to measure its height against: it resolves to whatever the
    /// engine likes, which is exactly the ambiguity that makes a footer change height on its own.
    private func makeFooter() -> NSStackView {
        let done = RowKit.ActionButton(title: ForgeSurface.dismissTitle) { [weak self] in
            self?.close()
        }
        let buttons = NSStackView(views: [RowKit.spacer(), done])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = MacTheme.Spacing.s

        let footer = FillingStack(views: [noteLabel, buttons])
        footer.spacing = MacTheme.Spacing.s
        footer.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        return footer
    }

    @objc private func repaint() {
        applyTheme()
    }

    private func applyTheme() {
        ground.fill = MacTheme.Color.canvas
        ground.needsDisplay = true
        heading.font = MacTheme.Ramp.font(.panelTitle)
        heading.textColor = MacTheme.Color.label
        for label in [subtitle, noteLabel] {
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.secondaryLabel
        }
    }

    /// The one sentence that has to sit beside the way out: closing over a render leaves the render
    /// running. The sheet's own button says the same thing by doing it, so the note is what makes the
    /// promise legible before the press rather than after it.
    private func drawFooter() {
        let note = ForgeSurface.dismissNote(rendering: ForgeRunner.shared.isRendering)
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
    }

    /// The board's keys first, then the sheet's one key. Escape closes only what the board did not
    /// already close — an expanded section takes it first — so somebody who opened the history closes
    /// the history rather than the whole surface.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet else { return event }
            guard let chord = MacKeys.chord(for: event) else { return event }
            if self.slot.handleChord(chord) { return nil }
            guard chord.keyval == Keymap.escape else { return event }
            self.close()
            return nil
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    /// The sheet that is already up, fetched to the front of the window it hangs from. There is one
    /// forge for the whole app and a Mac can have several main windows, so the press that finds it
    /// open is often made in a window the sheet is not attached to: leaving it where it is makes
    /// that press do nothing a person can see, and the prompt it focuses is not in the key window.
    private func raise() {
        sheet.sheetParent?.makeKeyAndOrderFront(nil)
        slot.focusPrompt()
    }

    /// The sheet is gone. The slot lets go of its player and its lookups; the render is left exactly
    /// where it is, in the runner, still arriving.
    private func release() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        slot.shutdown()
    }

    /// As tall as the surface asks for, and never taller than the window it hangs from. The sheet
    /// carries the renderer, the render, seven settings and the first clips, which is a tall sheet by
    /// design — and a tall sheet whose bottom falls off a laptop screen is one whose way out is
    /// somewhere below the fold.
    private static func height(near host: NSWindow) -> CGFloat {
        let asked = CGFloat(ForgeSurface.preferredHeight)
        let available = host.screen?.visibleFrame.height ?? host.frame.height
        guard available > 0 else { return asked }
        return max(CGFloat(ForgeSurface.minimumHeight), min(asked, available * 0.9))
    }

    var summary: String { slot.summary }

    func describe(_ text: String) {
        slot.describe(text)
    }

    func demonstrate(_ name: String) {
        slot.demonstrate(name)
    }

    func focusPrompt() {
        slot.focusPrompt()
    }

    /// The setup, opened on this sheet — the same press the renderer row makes, so a surface reached
    /// from the command line is reached the way a person reaches it.
    func openRenderer() {
        slot.openRenderer()
    }
}

/// The toolbar's way in to video, and the render's own mark while one is out.
///
/// Video reached through a menu item alone is a preference; reached through a control that sits with
/// the window's other primary actions it is what it actually is — an action, the same weight as
/// starting a chat. What it promises differs before a renderer exists and after, and while the other
/// machine is working it wears the state's own badge, so a person who closed the sheet can still see
/// the render is out. Every word, the symbol and the badge are `ForgeEntryPoint`'s.
@MainActor
final class ForgeMarkButton: NSButton {
    private let badge = ActivityBadgeView(pointSize: 7)

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: ForgeEntryPoint.symbol,
            accessibilityDescription: ForgeEntryPoint.title)
        setButtonType(.momentaryPushIn)
        bezelStyle = .toolbar
        isBordered = true
        self.target = target
        self.action = action
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: -1),
        ])
        ForgeRunner.shared.watch(self) { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A tooltip is not read aloud, so what this control promises goes into the accessibility label
    /// as well — and the label says whether a render is out, because the badge alone says it only to
    /// somebody who can see it.
    func render() {
        let rendering = ForgeRunner.shared.isRendering
        badge.activity = ForgeEntryPoint.activity(rendering: rendering)
        toolTip = ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil)
        setAccessibilityLabel(ForgeEntryPoint.accessibilityLabel(rendering: rendering))
    }
}
