import AppKit
import CodingAgentKit
import TailscodeCore

/// A remote machine's folders, walked from this Mac.
///
/// The old answer to "browse the other server" was nothing: a native open panel shows this disk,
/// and offering it on behalf of a machine across the tailnet would be a lie. `FolderBrowser`
/// (Core) decides every word and every key of the walk — the path to click back along, up and back
/// and home, a filter that narrows the folder as it is typed, the places already worked in, every
/// server a keystroke away, and one verb that picks the folder being stood in. This sheet draws
/// that answer over the server's own folder listing and does nothing else, so the phone, the Linux
/// desktop and this Mac are the same walk rendered three times.
@MainActor
final class FolderBrowserSheet: NSObject {
    private static var active: [FolderBrowserSheet] = []
    private static let size = NSSize(width: 720, height: 520)

    private let sheet: NSWindow
    private var browser: FolderBrowser
    private let regather: @MainActor () -> [String: NewChatDirectories]
    private let onChoose: @MainActor (String, String) -> Void
    private var fetching: Set<FolderRequest> = []
    private var monitor: Any?

    private let backButton = NSButton()
    private let upButton = NSButton()
    private let homeButton = NSButton()
    private let starButton = NSButton()
    private let crumbScroll = NSScrollView()
    private let crumbStack = NSStackView()
    private var shownCrumbs: [FolderCrumb] = []
    private let serverPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let field = NSSearchField()
    private let placesTable = NSTableView()
    private let placesScroll = NSScrollView()
    private let foldersTable = NSTableView()
    private let foldersScroll = NSScrollView()
    private let state = FolderStateView()
    private let summary = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let cancel = NSButton()
    private let start = NSButton()
    private var placeItems: [FolderPlaceItem] = []

    /// - Parameters:
    ///   - servers: every server that can list its folders; the browser cycles through them.
    ///   - start: where to open on the preferred server — the folder a half-typed path sits in —
    ///     or nil for the server's home.
    ///   - regather: the folders this device knows, read again after a star so it lands without the
    ///     list moving under the cursor.
    ///   - onChoose: the server and folder picked, called after the sheet has gone.
    static func present(
        over host: NSWindow, servers: [NewChatServer], entries: [SessionEntry],
        preferredServer: String?, start: String?,
        regather: @escaping @MainActor () -> [String: NewChatDirectories],
        onChoose: @escaping @MainActor (String, String) -> Void
    ) {
        guard !servers.isEmpty else { return }
        let sheet = FolderBrowserSheet(
            servers: servers, entries: entries, preferredServer: preferredServer, start: start,
            regather: regather, onChoose: onChoose)
        active.append(sheet)
        host.beginSheet(sheet.sheet) { _ in
            sheet.teardown()
            active.removeAll { $0 === sheet }
        }
        sheet.service()
        sheet.render()
        sheet.sheet.makeFirstResponder(sheet.field)
    }

    private init(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        start startPath: String?,
        regather: @escaping @MainActor () -> [String: NewChatDirectories],
        onChoose: @escaping @MainActor (String, String) -> Void
    ) {
        browser = FolderBrowser(
            servers: servers, directories: regather(), entries: entries,
            preferredServer: preferredServer, start: startPath)
        self.regather = regather
        self.onChoose = onChoose
        sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("Choose a folder")
        super.init()
        build(servers: servers)
        installMonitor()
    }

    private func build(servers: [NewChatServer]) {
        let content = NSView()
        sheet.contentView = content
        let inset = MacTheme.Spacing.l

        configure(
            backButton, symbol: "chevron.left", label: Localized.text("Back"),
            action: #selector(goBack))
        configure(
            upButton, symbol: "arrow.up", label: Localized.text("Up one folder"),
            action: #selector(goUp))
        configure(
            homeButton, symbol: "house", label: Localized.text("Home"), action: #selector(goHome))
        configure(
            starButton, symbol: "star", label: Localized.text("Star this folder"),
            action: #selector(toggleStar))

        crumbStack.orientation = .horizontal
        crumbStack.spacing = 2
        crumbStack.alignment = .centerY
        crumbStack.translatesAutoresizingMaskIntoConstraints = false
        crumbScroll.documentView = crumbStack
        crumbScroll.hasHorizontalScroller = false
        crumbScroll.hasVerticalScroller = false
        crumbScroll.drawsBackground = false
        crumbScroll.horizontalScrollElasticity = .allowed
        crumbScroll.verticalScrollElasticity = .none
        crumbScroll.translatesAutoresizingMaskIntoConstraints = false

        serverPopup.removeAllItems()
        for server in servers { serverPopup.addItem(withTitle: server.title) }
        serverPopup.target = self
        serverPopup.action = #selector(serverPicked)
        serverPopup.font = MacTheme.Ramp.font(.panelLabel)
        serverPopup.refusesFirstResponder = true
        serverPopup.isHidden = servers.count < 2
        serverPopup.setAccessibilityLabel(Localized.text("Server"))
        serverPopup.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = Localized.text("Filter folders…")
        field.font = MacTheme.Ramp.font(.code)
        field.delegate = self
        field.target = self
        field.action = #selector(filterChanged)
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        configure(placesTable, column: "place", action: #selector(placeClicked))
        placesScroll.documentView = placesTable
        configure(foldersTable, column: "folder", action: #selector(folderClicked))
        foldersScroll.documentView = foldersTable
        for scroll in [placesScroll, foldersScroll] {
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        state.translatesAutoresizingMaskIntoConstraints = false

        summary.font = MacTheme.Ramp.font(.panelLabel)
        summary.textColor = MacTheme.Color.secondaryLabel
        summary.lineBreakMode = .byTruncatingTail
        hint.font = MacTheme.Ramp.font(.rowNote)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.lineBreakMode = .byTruncatingTail
        hint.stringValue = browser.hint
        let notes = NSStackView(views: [summary, hint])
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = 1
        notes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        cancel.title = Localized.text("Cancel")
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelSheet)
        cancel.refusesFirstResponder = true
        start.bezelStyle = .rounded
        start.bezelColor = MacTheme.Color.accent
        start.target = self
        start.action = #selector(chooseHere)
        start.refusesFirstResponder = true
        let footer = NSStackView(views: [notes, spacer, cancel, start])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s
        footer.alignment = .centerY
        footer.setHuggingPriority(.required, for: .vertical)
        footer.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            backButton, upButton, homeButton, crumbScroll, starButton, serverPopup, field,
            placesScroll, divider, foldersScroll, state, footer,
        ] {
            content.addSubview(view)
        }

        let gap = MacTheme.Spacing.s
        let navHeight: CGFloat = 28
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.size.width),
            content.heightAnchor.constraint(equalToConstant: Self.size.height),
            backButton.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            backButton.heightAnchor.constraint(equalToConstant: navHeight),
            backButton.widthAnchor.constraint(equalToConstant: navHeight + 8),
            upButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            upButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            upButton.heightAnchor.constraint(equalTo: backButton.heightAnchor),
            upButton.widthAnchor.constraint(equalTo: backButton.widthAnchor),
            homeButton.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 4),
            homeButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            homeButton.heightAnchor.constraint(equalTo: backButton.heightAnchor),
            homeButton.widthAnchor.constraint(equalTo: backButton.widthAnchor),
            starButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -inset),
            starButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            starButton.heightAnchor.constraint(equalTo: backButton.heightAnchor),
            starButton.widthAnchor.constraint(equalTo: backButton.widthAnchor),
            crumbScroll.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: gap),
            crumbScroll.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -gap),
            crumbScroll.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            crumbScroll.heightAnchor.constraint(equalToConstant: navHeight),
            crumbStack.leadingAnchor.constraint(equalTo: crumbScroll.contentView.leadingAnchor),
            crumbStack.topAnchor.constraint(equalTo: crumbScroll.contentView.topAnchor),
            crumbStack.bottomAnchor.constraint(equalTo: crumbScroll.contentView.bottomAnchor),

            serverPopup.leadingAnchor.constraint(equalTo: backButton.leadingAnchor),
            serverPopup.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: gap),
            serverPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            field.topAnchor.constraint(equalTo: serverPopup.topAnchor),
            field.trailingAnchor.constraint(equalTo: starButton.trailingAnchor),
            field.heightAnchor.constraint(equalTo: serverPopup.heightAnchor),

            placesScroll.leadingAnchor.constraint(equalTo: backButton.leadingAnchor),
            placesScroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: MacTheme.Spacing.m),
            placesScroll.widthAnchor.constraint(equalToConstant: 190),
            divider.leadingAnchor.constraint(equalTo: placesScroll.trailingAnchor, constant: gap),
            divider.topAnchor.constraint(equalTo: placesScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: placesScroll.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            foldersScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: gap),
            foldersScroll.trailingAnchor.constraint(equalTo: starButton.trailingAnchor),
            foldersScroll.topAnchor.constraint(equalTo: placesScroll.topAnchor),
            foldersScroll.bottomAnchor.constraint(equalTo: placesScroll.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: foldersScroll.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: foldersScroll.trailingAnchor),
            state.topAnchor.constraint(equalTo: foldersScroll.topAnchor),
            state.bottomAnchor.constraint(equalTo: foldersScroll.bottomAnchor),

            placesScroll.bottomAnchor.constraint(
                equalTo: footer.topAnchor, constant: -MacTheme.Spacing.m),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            footer.leadingAnchor.constraint(equalTo: backButton.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: starButton.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
        if servers.count < 2 {
            field.leadingAnchor.constraint(equalTo: backButton.leadingAnchor).isActive = true
            serverPopup.heightAnchor.constraint(equalToConstant: 24).isActive = true
        } else {
            field.leadingAnchor.constraint(equalTo: serverPopup.trailingAnchor, constant: gap)
                .isActive = true
        }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configure(_ table: NSTableView, column: String, action: Selector) {
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.refusesFirstResponder = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column)))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = action
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The shell half: whatever folder the browser says it wants, read off the server once and
    /// offered back. An answer for a folder the person has already left is kept by the browser for
    /// later and not shown, so a slow server never repaints the wrong place.
    private func service() {
        guard let request = browser.wanted, fetching.insert(request).inserted else { return }
        let backend =
            ServerDirectory.shared.profiles.first { $0.id == request.profileID }
            .flatMap { ServerDirectory.shared.backend(for: $0) } as? any FileBrowsingBackend
        Task { [weak self] in
            let nodes: [FileNode]?
            if let backend {
                nodes = await Self.list(backend, path: request.path)
            } else {
                nodes = nil
            }
            guard let self else { return }
            self.fetching.remove(request)
            self.browser.offer(request, nodes: nodes)
            self.render()
            self.service()
        }
    }

    /// One folder, read with a deadline of its own: the Kit waits for connectivity, so a server that
    /// has gone quiet would otherwise leave the column reading for minutes instead of saying it
    /// could not list.
    nonisolated private static func list(
        _ backend: any FileBrowsingBackend, path: String
    ) async -> [FileNode]? {
        let limit = Duration.seconds(20)
        return await withTaskGroup(of: [FileNode]?.self) { group in
            group.addTask { try? await backend.listFiles(path: path) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Every key the browser claims goes through the shared translation, so this Mac and the
    /// other desks bind one keyboard; a chord it does not claim is left to the filter, which is
    /// what keeps typing a name from tripping over the verbs.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet else { return event }
            if (self.field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return event
            }
            guard let chord = MacKeys.chord(for: event),
                let command = FolderBrowser.command(
                    for: chord, filterIsEmpty: self.browser.filter.isEmpty)
            else { return event }
            self.perform(command)
            return nil
        }
    }

    private func perform(_ command: FolderCommand) {
        let answer = browser.handle(command)
        service()
        render()
        apply(answer.outcome)
    }

    private func apply(_ outcome: FolderOutcome?) {
        guard let outcome else { return }
        switch outcome {
        case .choose(let profileID, let path):
            FileBrowserRecents.record(path, for: profileID)
            let chosen = onChoose
            close()
            chosen(profileID, path)
        case .favorite(let profileID, let path):
            FileBrowserFavorites.toggle(path, for: profileID)
            browser = browser.restated(directories: regather())
            render()
        case .dismiss:
            close()
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    private func render() {
        backButton.isEnabled = browser.canGoBack
        upButton.isEnabled = browser.canGoUp
        homeButton.isEnabled =
            browser.server != nil && !(browser.home != nil && browser.location == browser.home)
        renderStar()
        renderCrumbs()
        if serverPopup.indexOfSelectedItem != browser.serverIndex {
            serverPopup.selectItem(at: browser.serverIndex)
        }
        if field.stringValue != browser.filter {
            field.stringValue = browser.filter
            field.currentEditor()?.selectedRange = NSRange(
                location: browser.filter.utf16.count, length: 0)
        }
        renderPlaces()
        renderFolders()
        summary.stringValue = browser.summary
        renderStart()
        if field.currentEditor() == nil { sheet.makeFirstResponder(field) }
    }

    private func renderStar() {
        let starred = browser.isStarredHere
        let label = starred ? Localized.text("Remove the star") : Localized.text("Star this folder")
        starButton.image = NSImage(
            systemSymbolName: starred ? "star.fill" : "star", accessibilityDescription: label)
        starButton.contentTintColor = starred ? MacTheme.Color.mark : nil
        starButton.toolTip = label
        starButton.setAccessibilityLabel(label)
        starButton.isEnabled = browser.location != nil
    }

    /// The path as buttons, rebuilt only when it changed so a keystroke in the filter never
    /// disturbs where the strip is scrolled to; the end of the path is always the end in view.
    private func renderCrumbs() {
        let crumbs = browser.crumbs
        guard crumbs != shownCrumbs else { return }
        shownCrumbs = crumbs
        for view in crumbStack.arrangedSubviews {
            crumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 {
                let chevron = NSImageView(
                    image: NSImage(
                        systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                chevron.contentTintColor = MacTheme.Color.tertiaryLabel
                chevron.symbolConfiguration = NSImage.SymbolConfiguration(
                    pointSize: 9, weight: .semibold)
                crumbStack.addArrangedSubview(chevron)
            }
            let button = NSButton()
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: crumb.title,
                attributes: [
                    .font: crumb.isCurrent
                        ? MacTheme.Ramp.font(.cardTitle) : MacTheme.Ramp.font(.panelLabel),
                    .foregroundColor: crumb.isCurrent
                        ? MacTheme.Color.label : MacTheme.Color.secondaryLabel,
                ])
            button.tag = index
            button.target = self
            button.action = #selector(crumbClicked(_:))
            button.toolTip = crumb.path
            button.refusesFirstResponder = true
            crumbStack.addArrangedSubview(button)
        }
        crumbScroll.layoutSubtreeIfNeeded()
        let clip = crumbScroll.contentView
        let overflow = crumbStack.frame.width - clip.bounds.width
        clip.scroll(to: NSPoint(x: max(0, overflow), y: 0))
        crumbScroll.reflectScrolledClipView(clip)
    }

    private func renderPlaces() {
        var items: [FolderPlaceItem] = []
        var index = 0
        for section in browser.placeSections {
            if let title = section.title { items.append(.header(title)) }
            for place in section.places {
                items.append(
                    .place(place, index: index, current: place.path == browser.location))
                index += 1
            }
        }
        guard items != placeItems else { return }
        placeItems = items
        placesTable.reloadData()
    }

    private func renderFolders() {
        switch browser.phase {
        case .loading:
            state.showLoading()
        case .failed(.cannotList):
            state.show(
                symbol: "wifi.exclamationmark",
                title: Localized.text("Could not list this server’s folders"),
                detail: Localized.text(
                    "It may be offline, want a password, or be too old to list its folders. A path typed in the new-chat field still works."
                ))
        case .failed(.missing(let path)):
            state.show(
                symbol: "folder.badge.questionmark",
                title: Localized.text("The server could not open %@", path),
                detail: Localized.text("Go up a level, use the path above, or pick another place."))
        case .ready:
            if browser.rows.isEmpty {
                state.show(symbol: nil, title: browser.summary, detail: nil)
            } else {
                state.isHidden = true
            }
        }
        foldersScroll.isHidden = !state.isHidden
        foldersTable.reloadData()
        if browser.rows.indices.contains(browser.cursor) {
            foldersTable.scrollRowToVisible(browser.cursor)
        }
    }

    private func renderStart() {
        let title: String
        if browser.choice == nil {
            title = Localized.text("Start")
        } else {
            let name =
                browser.filter.isEmpty
                ? browser.currentName : (browser.focused?.name ?? browser.currentName)
            let shown = name.count > 24 ? String(name.prefix(23)) + "…" : name
            title = Localized.text("Start in %@", shown)
        }
        let enabled = browser.choice != nil
        start.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: MacTheme.Ramp.font(.panelLabel),
                .foregroundColor: enabled ? MacTheme.Color.onAccent : NSColor.disabledControlTextColor,
            ])
        start.isEnabled = enabled
    }

    @objc private func goBack() { perform(.back) }
    @objc private func goUp() { perform(.ascend) }
    @objc private func goHome() { perform(.home) }
    @objc private func toggleStar() { perform(.favoriteHere) }
    @objc private func chooseHere() { perform(.chooseHere) }
    @objc private func cancelSheet() { close() }

    @objc private func serverPicked() {
        let index = serverPopup.indexOfSelectedItem
        guard browser.servers.indices.contains(index) else { return }
        browser.chooseServer(browser.servers[index].profileID)
        service()
        render()
    }

    @objc private func filterChanged() {
        browser.type(field.stringValue)
        service()
        render()
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard shownCrumbs.indices.contains(sender.tag) else { return }
        browser.open(shownCrumbs[sender.tag].path)
        service()
        render()
    }

    @objc private func placeClicked() {
        let row = placesTable.clickedRow
        guard placeItems.indices.contains(row), case .place(_, let index, _) = placeItems[row]
        else { return }
        browser.openPlace(index)
        service()
        render()
    }

    @objc private func folderClicked() {
        let row = foldersTable.clickedRow
        guard browser.rows.indices.contains(row) else { return }
        browser.focus(row)
        browser.open(browser.rows[row].path)
        service()
        render()
    }
}

extension FolderBrowserSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === placesTable ? placeItems.count : browser.rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === placesTable {
            guard placeItems.indices.contains(row), case .header = placeItems[row] else {
                return 28 * MacTheme.UIScale.factor
            }
            return 26 * MacTheme.UIScale.factor
        }
        return 32 * MacTheme.UIScale.factor
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        if tableView === placesTable {
            guard placeItems.indices.contains(row) else { return nil }
            let view = FolderPlaceRowView()
            view.configure(placeItems[row])
            return view
        }
        guard browser.rows.indices.contains(row) else { return nil }
        let view = FolderRowView()
        view.configure(browser.rows[row], focused: row == browser.cursor)
        return view
    }
}

extension FolderBrowserSheet: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        browser.type(field.stringValue)
        service()
        render()
    }
}

/// One line of the places column: a heading that names a group, or a jump.
private enum FolderPlaceItem: Equatable {
    case header(String)
    case place(FolderPlace, index: Int, current: Bool)
}

/// A place worth going without walking there: its symbol says where it came from, the folder
/// being read wears the accent, and the whole path is one hover away.
@MainActor
private final class FolderPlaceRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FolderPlaceItem) {
        switch item {
        case .header(let text):
            icon.isHidden = true
            title.stringValue = text
            title.font = MacTheme.Ramp.font(.metricLabel)
            title.textColor = MacTheme.Color.tertiaryLabel
            layer?.backgroundColor = NSColor.clear.cgColor
            toolTip = nil
            setAccessibilityLabel(text)
        case .place(let place, _, let current):
            icon.isHidden = false
            icon.image = NSImage(
                systemSymbolName: Self.symbol(place.kind), accessibilityDescription: nil)
            icon.contentTintColor = Self.tint(place.kind)
            title.stringValue = place.title
            title.font = MacTheme.Ramp.font(.panelLabel)
            title.textColor = current ? MacTheme.Color.accent : MacTheme.Color.label
            layer?.backgroundColor =
                current ? MacTheme.Color.accent.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
            toolTip = place.path
            setAccessibilityLabel(place.title)
        }
    }

    private static func symbol(_ kind: FolderPlaceKind) -> String {
        switch kind {
        case .home: return "house"
        case .root: return "internaldrive"
        case .favorite: return "star.fill"
        case .recent: return "clock"
        case .project: return "bubble.left"
        }
    }

    private static func tint(_ kind: FolderPlaceKind) -> NSColor {
        kind == .favorite ? MacTheme.Color.mark : MacTheme.Color.secondaryLabel
    }
}

/// One folder: what it is called with the letters the filter landed on in the accent, how many
/// chats already work in it or under it, and a star when it is kept.
@MainActor
private final class FolderRowView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let star = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control

        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = MacTheme.Color.info
        icon.imageScaling = .scaleProportionallyDown
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        note.font = MacTheme.Ramp.font(.rowNote)
        note.textColor = MacTheme.Color.secondaryLabel
        note.setContentCompressionResistancePriority(.required, for: .horizontal)
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        star.contentTintColor = MacTheme.Color.mark
        star.imageScaling = .scaleProportionallyDown

        let line = NSStackView(views: [icon, name, note, star])
        line.orientation = .horizontal
        line.spacing = MacTheme.Spacing.s
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            star.widthAnchor.constraint(equalToConstant: 14),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            line.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: FolderRow, focused: Bool) {
        name.attributedStringValue = Self.highlighted(row)
        let text = Self.note(for: row)
        note.stringValue = text
        note.isHidden = text.isEmpty
        star.isHidden = !row.starred
        layer?.backgroundColor =
            focused
            ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(text.isEmpty ? row.name : "\(row.name), \(text)")
    }

    private static func note(for row: FolderRow) -> String {
        if row.chats > 0 {
            return row.chats == 1
                ? Localized.text("1 chat") : Localized.text("%@ chats", "\(row.chats)")
        }
        if row.chatsBelow > 0 { return Localized.text("%@ inside", "\(row.chatsBelow)") }
        return ""
    }

    /// The filter's offsets are into the name's characters, not its UTF-16 units, so each one is
    /// walked to its own range rather than used as a location.
    private static func highlighted(_ row: FolderRow) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.name,
            attributes: [
                .font: MacTheme.Ramp.font(.cardTitle), .foregroundColor: MacTheme.Color.label,
            ])
        let characters = Array(row.name)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [.foregroundColor: MacTheme.Color.accent],
                range: NSRange(location: start, length: length))
        }
        return text
    }
}

/// What the folder column says when it has no folders to show: a read in progress, a server that
/// would not answer, a folder it would not open, or a folder with nothing in it.
@MainActor
private final class FolderStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        symbol.contentTintColor = MacTheme.Color.tertiaryLabel
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.alignment = .center
        title.preferredMaxLayoutWidth = 360
        detail.font = MacTheme.Ramp.font(.panelLabel)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 360

        let column = NSStackView(views: [spinner, symbol, title, detail])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xl * 2),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showLoading() {
        isHidden = false
        symbol.isHidden = true
        detail.isHidden = true
        title.stringValue = Localized.text("Reading…")
        title.textColor = MacTheme.Color.secondaryLabel
        spinner.isHidden = false
        spinner.startAnimation(nil)
        setAccessibilityLabel(title.stringValue)
    }

    func show(symbol name: String?, title text: String, detail words: String?) {
        isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        symbol.isHidden = name == nil
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        title.stringValue = text
        title.textColor = name == nil ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        detail.isHidden = words == nil
        detail.stringValue = words ?? ""
        setAccessibilityLabel([text, words].compactMap { $0 }.joined(separator: ". "))
    }
}
