import AppKit
import TailscodeCore

/// One action in the Shortcuts list: its name, the keys it answers to as caps, the narrower
/// scope a key may have, and the buttons that change or restore it. Placed by frame, like the
/// rest of the list, so no constraint joins one row to another.
@MainActor
private final class ShortcutRowView: NSView {
    let entryID: String
    let signature: [String]
    private(set) var height: CGFloat = 0
    private let title: NSTextField
    private let caps: KeycapView
    private let scopes: [NSTextField]
    private let buttons: [NSButton]

    private static let inner: CGFloat = 4
    private static let across = MacTheme.Spacing.s

    init(entry: ShortcutEntry, target: AnyObject, change: Selector, restore: Selector) {
        entryID = entry.id
        signature = ShortcutRowView.signature(of: entry)
        let title = NSTextField(labelWithString: entry.definition.title)
        title.font = MacTheme.Ramp.font(.panelLabel)
        title.lineBreakMode = .byTruncatingTail
        self.title = title
        caps = Keycaps.keys(entry.keys)
        scopes = entry.keys.compactMap { key in
            guard let scope = key.scope else { return nil }
            return MacDialogs.detailLabel(entry.keys.count > 1 ? "\(key.display) — \(scope)" : scope)
        }
        var made: [NSButton] = []
        if entry.isCustomized {
            made.append(
                Self.button(
                    Localized.text("Restore"), id: entry.id, target: target, action: restore))
        }
        made.append(
            Self.button(Localized.text("Change…"), id: entry.id, target: target, action: change))
        buttons = made
        super.init(frame: .zero)
        for view in [title, caps] + scopes + buttons { addSubview(view) }
        height = lineHeight + Self.inner + caps.intrinsicContentSize.height
            + scopes.reduce(0) { $0 + Self.inner + $1.intrinsicContentSize.height }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func signature(of entry: ShortcutEntry) -> [String] {
        entry.keys.map(\.spec) + [entry.isCustomized ? "*" : ""]
    }

    private var lineHeight: CGFloat {
        max(title.intrinsicContentSize.height, buttons.map { $0.intrinsicContentSize.height }.max() ?? 0)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let line = lineHeight
        var right = bounds.width
        for button in buttons.reversed() {
            let size = button.intrinsicContentSize
            button.frame = NSRect(
                x: right - size.width, y: (line - size.height) / 2, width: size.width,
                height: size.height)
            right -= size.width + Self.across
        }
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(
            x: 0, y: (line - titleHeight) / 2, width: max(0, right), height: titleHeight)
        var y = line + Self.inner
        caps.frame = NSRect(
            x: 0, y: y, width: min(caps.intrinsicContentSize.width, bounds.width),
            height: caps.intrinsicContentSize.height)
        y += caps.frame.height
        for scope in scopes {
            y += Self.inner
            let scopeHeight = scope.intrinsicContentSize.height
            scope.frame = NSRect(x: 0, y: y, width: bounds.width, height: scopeHeight)
            y += scopeHeight
        }
    }

    private static func button(_ title: String, id: String, target: AnyObject, action: Selector)
        -> NSButton
    {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }
}

/// Every shortcut the app has, grouped as the cheatsheet groups them, drawn once and then kept:
/// a search only hides what does not match, and an edit replaces only the rows whose keys
/// changed. The list is placed by frame (a hundred and forty rows in a stack view cost a few
/// hundred milliseconds of layout every time the page opened) and its height depends on its
/// rows alone, so the page it stands in asks for it without knowing its width.
@MainActor
final class ShortcutListView: NSView {
    private enum Entry {
        case header(ShortcutCategory)
        case row(String)
    }

    var onChange: (String) -> Void = { _ in }
    var onRestore: (String) -> Void = { _ in }
    private var headers: [ShortcutCategory: NSTextField] = [:]
    private var rows: [String: ShortcutRowView] = [:]
    private var order: [Entry] = []
    private let empty = MacDialogs.detailLabel(Localized.text("No shortcut matches that."))
    private(set) var query = ""

    private static let betweenRows = MacTheme.Spacing.m
    private static let beforeSection = MacTheme.Spacing.xl - MacTheme.Spacing.xs
    private static let afterHeader = MacTheme.Spacing.s

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(empty)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var rowCount: Int { rows.count }
    var visibleRowCount: Int { rows.values.filter { !$0.isHidden }.count }

    func row(for id: String) -> NSView? { rows[id] }

    func visibleRows() -> [NSView] {
        order.compactMap { entry in
            guard case .row(let id) = entry, let row = rows[id], !row.isHidden else { return nil }
            return row
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: placements().height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Where every visible view goes: top to bottom, with the breath a section gets above its
    /// header and the tighter one between a header and its first row.
    private func placements() -> (views: [(view: NSView, y: CGFloat, height: CGFloat)], height: CGFloat) {
        var placed: [(view: NSView, y: CGFloat, height: CGFloat)] = []
        var y: CGFloat = 0
        var previous: Entry?
        for entry in order {
            let view: NSView
            let height: CGFloat
            switch entry {
            case .header(let category):
                guard let header = headers[category], !header.isHidden else { continue }
                view = header
                height = header.intrinsicContentSize.height
            case .row(let id):
                guard let row = rows[id], !row.isHidden else { continue }
                view = row
                height = row.height
            }
            if let previous {
                switch (previous, entry) {
                case (_, .header): y += Self.beforeSection
                case (.header, .row): y += Self.afterHeader
                default: y += Self.betweenRows
                }
            }
            placed.append((view, y, height))
            y += height
            previous = entry
        }
        if !empty.isHidden {
            let height = empty.intrinsicContentSize.height
            placed.append((empty, 0, height))
            y = height
        }
        return (placed, y)
    }

    override func layout() {
        super.layout()
        for each in placements().views {
            each.view.frame = NSRect(x: 0, y: each.y, width: bounds.width, height: each.height)
        }
    }

    /// Reads the file again and brings the rows up to date with it.
    func reload() {
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings.load())
        var kept: [String: ShortcutRowView] = [:]
        order = []
        for section in sections {
            let header =
                headers[section.category] ?? MacDialogs.sectionHeader(section.category.title)
            headers[section.category] = header
            order.append(.header(section.category))
            for entry in section.entries {
                if let held = rows[entry.id], held.signature == ShortcutRowView.signature(of: entry) {
                    kept[entry.id] = held
                } else {
                    kept[entry.id] = ShortcutRowView(
                        entry: entry, target: self, change: #selector(changePressed(_:)),
                        restore: #selector(restorePressed(_:)))
                }
                order.append(.row(entry.id))
            }
        }
        for (id, row) in rows where kept[id] !== row { row.removeFromSuperview() }
        rows = kept
        for header in headers.values where header.superview == nil { addSubview(header) }
        for row in rows.values where row.superview == nil { addSubview(row) }
        filter(query)
    }

    func filter(_ text: String) {
        query = text
        let shown = Set(
            ShortcutEditor.sections(bindings: ShortcutBindings.load(), query: text)
                .flatMap { $0.entries.map(\.id) })
        for (id, row) in rows { row.isHidden = !shown.contains(id) }
        var current: ShortcutCategory?
        var anyShown: [ShortcutCategory: Bool] = [:]
        for entry in order {
            switch entry {
            case .header(let category): current = category
            case .row(let id): if shown.contains(id), let current { anyShown[current] = true }
            }
        }
        for (category, header) in headers { header.isHidden = anyShown[category] != true }
        empty.isHidden = !shown.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func changePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onChange(id)
    }

    @objc private func restorePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onRestore(id)
    }
}
