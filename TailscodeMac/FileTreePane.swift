import AppKit
import CodingAgentKit
import TailscodeCore

/// The project the conversation is working in, browsable.
///
/// The files come from the server, not from this machine — the agent's working directory is on
/// whichever box runs the bridge, and a desktop client that browsed its own disk would be showing
/// the wrong tree. Selecting a file drops its path into the composer, which is how a prompt names
/// something without anyone typing it out; directories open in place, their listing fetched the
/// first time the triangle turns.
@MainActor
final class FileTreePane: NSViewController {
    var onOpen: ((String) -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var backend: (any FileBrowsingBackend)?
    private var root: String?
    private var nodes: [Node] = []
    private var pendingLoads: Set<String> = []
    private var generation = 0

    /// One entry of the server's tree and the listing under it, fetched once on first expansion:
    /// `nil` children means "not asked yet", an empty array means the server answered "empty".
    private final class Node {
        let file: FileNode
        var children: [Node]?

        init(file: FileNode) {
            self.file = file
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        configureOutline()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = Localized.text("Open a conversation to see its project files.")
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(pathLabel)
        container.addSubview(scrollView)
        container.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            pathLabel.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
            pathLabel.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
            scrollView.topAnchor.constraint(
                equalTo: pathLabel.bottomAnchor, constant: MacTheme.Spacing.xs),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            messageLabel.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),
        ])
        view = container
        restyle()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @objc private func themeChanged() {
        restyle()
    }

    /// A palette hands out its ink under the theme that was in force when it was asked, so a token
    /// taken once at load keeps answering for a theme nobody is looking at any more — and the rows
    /// are measured against a type scale that moves under them. Both are read again here.
    private func restyle() {
        pathLabel.font = MacTheme.Ramp.font(.panelFootnote)
        pathLabel.textColor = MacTheme.Color.tertiaryLabel
        messageLabel.font = MacTheme.Ramp.font(.panelFootnote)
        messageLabel.textColor = MacTheme.Color.tertiaryLabel
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 12 * MacTheme.UIScale.factor
        outline.reloadData()
    }

    /// A row is as tall as the face it sets, not a constant: the label grows with the type scale
    /// and a fixed row cuts its descenders off long before the scale runs out.
    private static var rowHeight: CGFloat {
        ceil(MacTheme.Ramp.font(.panelLabel).boundingRectForFont.height) + 6
    }

    /// A fresh listing on every conversation change, rooted at that conversation's project
    /// directory — a nil directory lists the server's own default, the same answer the agent
    /// would get. A server that cannot browse says so instead of showing nothing, and a refused
    /// listing says so rather than borrowing the wording for an empty one.
    ///
    /// The old tree goes before the new path arrives: a pane showing one project's files under
    /// another project's heading is asserting something false, and a click during that window
    /// drops the wrong `@path` into the composer.
    func show(directory: String?, on backend: any CodingAgentBackend) {
        generation += 1
        guard let browsing = backend as? any FileBrowsingBackend else {
            self.backend = nil
            root = nil
            pathLabel.stringValue = ""
            render(nodes: [], message: Localized.text("This server has no file browser."))
            return
        }
        self.backend = browsing
        root = directory
        pathLabel.stringValue = directory ?? "~"
        render(nodes: [], message: Localized.text("Listing…"))
        let current = generation
        Task { [weak self] in
            do {
                let listing = try await browsing.listFiles(path: directory)
                guard let self, self.generation == current else { return }
                self.render(
                    nodes: Self.sorted(listing).map(Node.init),
                    message: listing.isEmpty ? Localized.text("Empty folder.") : nil)
            } catch {
                guard let self, self.generation == current else { return }
                self.render(nodes: [], message: Localized.text("Could not list this folder."))
            }
        }
    }

    func takeFocus() {
        view.window?.makeFirstResponder(outline)
    }

    func ownsFocus(in window: NSWindow?) -> Bool {
        window?.firstResponder === outline
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.autoresizesOutlineColumn = true
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
    }

    private func render(nodes: [Node], message: String?) {
        self.nodes = nodes
        pendingLoads = []
        outline.reloadData()
        if let message {
            messageLabel.stringValue = message
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
    }

    private static func sorted(_ listing: [FileNode]) -> [FileNode] {
        listing.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// A directory's listing arrives once and the triangle opens itself when it does; a stale
    /// answer — the conversation changed underneath the fetch — is dropped, because it describes
    /// a tree no longer on screen.
    ///
    /// A refusal leaves the children unasked rather than recording an empty answer: an empty node
    /// is a folder that is genuinely empty, and one written from a failure is a triangle that
    /// swallows every later click without ever trying again.
    private func loadChildren(of node: Node) {
        guard let backend, !pendingLoads.contains(node.file.path) else { return }
        pendingLoads.insert(node.file.path)
        let current = generation
        Task { [weak self] in
            do {
                let listing = try await backend.listFiles(path: node.file.path)
                guard let self, self.generation == current else { return }
                self.pendingLoads.remove(node.file.path)
                node.children = Self.sorted(listing).map(Node.init)
                self.outline.reloadItem(node, reloadChildren: true)
                self.outline.expandItem(node)
            } catch {
                guard let self, self.generation == current else { return }
                self.pendingLoads.remove(node.file.path)
            }
        }
    }

    /// One click, exactly what Linux does: a file goes to the composer as `@path`, a directory
    /// opens or closes in place.
    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        guard node.file.isDirectory else {
            onOpen?(node.file.path)
            return
        }
        if node.children == nil {
            loadChildren(of: node)
        } else if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }
}

extension FileTreePane: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return nodes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return nodes[index] }
        return node.children?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.file.isDirectory ?? false
    }
}

extension FileTreePane: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? Node, node.file.isDirectory else { return false }
        if node.children != nil { return true }
        loadChildren(of: node)
        return false
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileCell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier)
        cell.textField?.stringValue = node.file.name
        cell.textField?.font = MacTheme.Ramp.font(.panelLabel)
        cell.imageView?.image = NSImage(
            systemSymbolName: node.file.isDirectory ? "folder" : "doc.text",
            accessibilityDescription: nil)
        cell.imageView?.contentTintColor =
            node.file.isDirectory ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11 * MacTheme.UIScale.factor, weight: .regular)
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16 * MacTheme.UIScale.factor),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
