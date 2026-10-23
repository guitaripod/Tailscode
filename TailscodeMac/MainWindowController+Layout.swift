import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    func applyUIScale() {
        splitPanes.eachPane { $0.applyUIScale() }
        sidebar.applyUIScale()
        #if !TAILSCODE_MAS
            terminalPane.applyTypeScale()
        #endif
        applyPaneThickness()
    }

    /// A slider dragged through forty sizes asks for forty redraws of every conversation, and each
    /// one rebuilds every row. The preview in Settings answers every notch; the window answers
    /// when the hand has paused.
    func typeScaleChanged() {
        typeScaleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyUIScale() }
        typeScaleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// A theme change is a restyle of everything, and AppKit has no trait to invalidate for it: a
    /// `CGColor` in a layer and a rendering in a memo both keep the colour they were born with. So
    /// the window takes the same road it takes for a change of type scale — drop what was baked,
    /// rebuild what was drawn — and the two paths stay one path on purpose.
    func applyTheme() {
        MacMarkdown.invalidate()
        window?.appearance = MacTheme.Chrome.appearance
        applyUIScale()
        transcript.applyPaneColours()
        splitPanes.eachPane { $0.applyPaneColours() }
        splitPanes.applyFocusStyling()
        updateMark?.render()
        videoMark?.render()
    }

    /// Sidebar, content column, files inspector — and inside the content column its own vertical
    /// split, the transcript over the terminal, so the terminal pane belongs to the conversation
    /// the way it does on Linux rather than running under the whole window.
    func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !paneShown(.sidebar)
        split.addSplitViewItem(sidebarItem)
        self.sidebarItem = sidebarItem

        contentSplit.splitView.isVertical = false
        contentSplit.splitView.dividerStyle = .thin
        let transcriptItem = NSSplitViewItem(viewController: splitPanes)
        transcriptItem.minimumThickness = 240
        contentSplit.addSplitViewItem(transcriptItem)
        #if !TAILSCODE_MAS
            let terminal = NSSplitViewItem(viewController: terminalPane)
            terminal.minimumThickness = 120
            terminal.canCollapse = true
            terminal.holdingPriority = NSLayoutConstraint.Priority(261)
            terminal.isCollapsed = !paneShown(.terminal)
            contentSplit.addSplitViewItem(terminal)
            terminalItem = terminal
        #endif
        let content = NSSplitViewItem(viewController: contentSplit)
        content.minimumThickness = CGFloat(PaneDropTarget.minimumPaneExtent)
        split.addSplitViewItem(content)

        applyPaneThickness()
        window?.contentViewController = split
    }

    /// The chat list and the inspector are measured in points but filled with type, so their limits
    /// travel with the type scale. A doubled ramp under a fixed 400pt ceiling truncates every row
    /// it just grew and leaves no way to widen the pane, which is the one thing a reader would
    /// reach for.
    private func applyPaneThickness() {
        let scale = MacTheme.UIScale.factor
        sidebarItem?.minimumThickness = 240 * scale
        sidebarItem?.maximumThickness = 400 * scale
    }

    func configureToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "TailscodeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
    }

    @discardableResult
    func focus(_ pane: Pane) -> Bool {
        if pane != .transcript { transcript.composer.dismissCompletion() }
        switch pane {
        case .chats:
            focused = .chats
            sidebar.takeFocus()
        case .transcript:
            focused = .transcript
            window?.makeFirstResponder(nil)
        case .terminal:
            #if TAILSCODE_MAS
                return false
            #else
                guard terminalItem?.isCollapsed == false else { return false }
                focused = .terminal
                terminalPane.takeFocus()
            #endif
        case .files:
            return false
        }
        return true
    }

    /// Where the keyboard actually is, first responder as ground truth: the composer counts as
    /// its own stop so Tab from the transcript lands in the prompt box before moving on.
    private enum CycleStop {
        case chats
        case transcript
        case composer
        case terminal
    }

    private func currentStop() -> CycleStop {
        if terminalHasFocus { return .terminal }
        if transcript.composer.editorHasFocus { return .composer }
        return focused == .chats ? .chats : .transcript
    }

    /// Linux `nextPane`, with the Mac's extra stop: chats → transcript → composer → files →
    /// terminal, wrapping, and a hidden pane is simply not on the route.
    func cycle(_ delta: Int) {
        var stops: [CycleStop] = []
        if sidebarItem?.isCollapsed == false { stops.append(.chats) }
        stops.append(.transcript)
        stops.append(.composer)
        if terminalItem?.isCollapsed == false { stops.append(.terminal) }
        let index = (stops.firstIndex(of: currentStop()) ?? 0) + delta
        let count = stops.count
        switch stops[((index % count) + count) % count] {
        case .chats:
            focus(.chats)
        case .transcript:
            focus(.transcript)
        case .composer:
            focused = .transcript
            transcript.focusComposer()
        case .terminal:
            focus(.terminal)
        }
    }

    /// Every pane closes, and the choice survives relaunch under the same `tailscode.pane.*`
    /// keys the other desktops use — a window someone shaped once should open shaped that way.
    enum ClosablePane: String {
        case sidebar
        case files
        case terminal

        var key: String { "tailscode.pane.\(rawValue)" }
        var defaultShown: Bool { self == .sidebar }
    }

    private func paneShown(_ pane: ClosablePane) -> Bool {
        UserDefaults.standard.object(forKey: pane.key) as? Bool ?? pane.defaultShown
    }

    /// Toggles from what the split item actually is, not from the stored flag: a divider dragged
    /// shut collapses the item without asking this method, and a toggle that trusted the flag
    /// would answer the next press by doing nothing. Hiding the pane that holds the keyboard hands
    /// the keyboard to the transcript, because a region that is gone cannot receive a chord.
    /// A pane put where Settings says it should be, which is a toggle only when it is not there.
    func driveSetSidebar(shown: Bool) { setPane(.sidebar, shown: shown) }

    func setPane(_ pane: ClosablePane, shown: Bool) {
        let isShown: Bool
        switch pane {
        case .sidebar: isShown = sidebarShown
        case .terminal: isShown = terminalShown
        case .files: return
        }
        if isShown != shown { togglePane(pane) }
    }

    func togglePane(_ pane: ClosablePane) {
        let item: NSSplitViewItem?
        switch pane {
        case .sidebar: item = sidebarItem
        case .terminal: item = terminalItem
        case .files: item = nil
        }
        let shown = item?.isCollapsed ?? !paneShown(pane)
        UserDefaults.standard.set(shown, forKey: pane.key)
        guard let item else { return }
        if !shown {
            let holdsKeyboard: Bool
            switch pane {
            case .sidebar: holdsKeyboard = focused == .chats
            case .terminal: holdsKeyboard = focused == .terminal || terminalHasFocus
            case .files: holdsKeyboard = false
            }
            if holdsKeyboard { focus(.transcript) }
        }
        NSAnimationContext.runAnimationGroup(
            { _ in item.animator().isCollapsed = !shown },
            completionHandler: { [weak self] in
                MainThread.call {
                    guard let self, shown else { return }
                    self.applyStoredDividers()
                    if pane == .terminal { self.focus(.terminal) }
                }
            })
    }

    /// The dividers survive relaunch under the same `tailscode.divider.*` keys the Linux desktop
    /// uses — sidebar and project on the outer split, terminal on the content column's own — and
    /// a pane toggled back open is re-asserted to the position it was shaped to, because
    /// NSSplitView's own resizing would otherwise re-deal the space.
    private enum DividerKey: String {
        case sidebar
        case project
        case terminal

        var key: String { "tailscode.divider.\(rawValue)" }
    }

    private func storedDivider(_ divider: DividerKey) -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: divider.key)
        return value > 0 ? CGFloat(value) : nil
    }

    func applyStoredDividers() {
        if paneShown(.sidebar), let position = storedDivider(.sidebar) {
            split.splitView.setPosition(position, ofDividerAt: 0)
        }
        if paneShown(.terminal), let position = storedDivider(.terminal) {
            contentSplit.splitView.setPosition(position, ofDividerAt: 0)
        }
    }

    func observeDividers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(dividersMoved),
            name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(dividersMoved),
            name: NSSplitView.didResizeSubviewsNotification, object: contentSplit.splitView)
    }

    /// Positions are read back whenever the split settles rather than watched per-drag, and only
    /// sane ones are kept: a pane mid-collapse or mid-reveal passes through widths that are
    /// nobody's intent, so anything under the pane's own minimum is ignored.
    @objc private func dividersMoved() {
        guard dividerSavingEnabled else { return }
        let defaults = UserDefaults.standard
        if let sidebarItem { defaults.set(!sidebarItem.isCollapsed, forKey: ClosablePane.sidebar.key) }
        if let terminalItem { defaults.set(!terminalItem.isCollapsed, forKey: ClosablePane.terminal.key) }
        if let sidebarItem, !sidebarItem.isCollapsed {
            let width = sidebarItem.viewController.view.frame.width
            if width >= sidebarItem.minimumThickness {
                defaults.set(Double(width), forKey: DividerKey.sidebar.key)
            }
        }
        if let terminalItem, !terminalItem.isCollapsed {
            let height = terminalItem.viewController.view.frame.height
            if height >= terminalItem.minimumThickness {
                let position = contentSplit.splitView.bounds.height - height
                    - contentSplit.splitView.dividerThickness
                defaults.set(Double(position), forKey: DividerKey.terminal.key)
            }
        }
    }
}
