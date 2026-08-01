import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The source list: servers, and the sessions on them. One outline, refreshed on its own while
/// it is visible, because a chat started in a terminal on any of those machines has to appear here
/// without anyone asking.
@MainActor
final class SidebarViewController: NSViewController {
    var onSelect: ((SessionEntry, any CodingAgentBackend) -> Void)?

    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private var entriesByProfile: [String: [SessionEntry]] = [:]
    private var unreachable: Set<String> = []
    private var refreshTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()
        outline.headerView = nil
        outline.rowSizeStyle = .medium
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startRefreshing()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() async {
        let profiles = ServerDirectory.shared.profiles
        var collected: [String: [SessionEntry]] = [:]
        var down: Set<String> = []
        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else { continue }
            do {
                let sessions = try await backend.listSessions()
                collected[profile.id] = sessions.map {
                    SessionEntry(
                        profileID: profile.id, profileName: profile.name,
                        host: profile.baseURL.host ?? profile.name, backendType: profile.backend,
                        session: $0)
                }
            } catch {
                down.insert(profile.id)
                collected[profile.id] = entriesByProfile[profile.id] ?? []
            }
        }
        entriesByProfile = collected
        unreachable = down
        outline.reloadData()
        for profile in profiles { outline.expandItem(profile) }
    }

    @objc private func rowClicked() {
        guard let entry = outline.item(atRow: outline.selectedRow) as? SessionEntry,
            let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }),
            let backend = ServerDirectory.shared.backend(for: profile)
        else { return }
        onSelect?(entry, backend)
    }
}

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return ServerDirectory.shared.profiles.count }
        guard let profile = item as? ConnectionProfile else { return 0 }
        return entriesByProfile[profile.id]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let profile = item as? ConnectionProfile else {
            return ServerDirectory.shared.profiles[index]
        }
        return entriesByProfile[profile.id]?[index] ?? profile
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ConnectionProfile
    }
}

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        if let profile = item as? ConnectionProfile {
            return SidebarRowView(
                title: profile.name,
                detail: unreachable.contains(profile.id)
                    ? Localized.text("Unreachable") : profile.baseURL.host ?? "",
                tint: MacTheme.Color.brand(profile.backend),
                emphasised: true,
                live: false)
        }
        guard let entry = item as? SessionEntry else { return nil }
        let project = entry.session.directory.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        return SidebarRowView(
            title: entry.session.hasPlaceholderTitle ? Localized.text("New conversation") : entry.session.title,
            detail: [project, entry.profileName].compactMap { $0 }.joined(separator: " · "),
            tint: MacTheme.Color.brand(entry.backendType),
            emphasised: false,
            live: entry.session.isActive == true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SessionEntry
    }
}

/// One line, two registers: what it is, then where it lives — with a dot when a turn is running,
/// which is the only thing on this list that has to catch the eye.
@MainActor
private final class SidebarRowView: NSTableCellView {
    init(title: String, detail: String, tint: NSColor, emphasised: Bool, live: Bool) {
        super.init(frame: .zero)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor =
            (live ? MacTheme.Color.success : tint.withAlphaComponent(0.35)).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = emphasised ? MacTheme.Font.emphasis() : MacTheme.Font.body()
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = MacTheme.Font.caption()
        subtitle.textColor = MacTheme.Color.secondaryLabel
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(name)
        addSubview(subtitle)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: MacTheme.Spacing.s),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
