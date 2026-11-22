import AppKit
import CodingAgentKit
import TailscodeCore

/// The sidebar's place for masters: the Masters tile beside Scheduled, counting the notes waiting
/// across every master, with each master's state line in its tooltip. It is there only while some
/// machine keeps masters. A press opens the Masters window; its context menu opens a master or
/// starts a task for one.
@MainActor
final class MastersSidebarEntry: SidebarPlaceTile {
    private var rows: [MasterRow] = []
    private var now = Date()
    var onOpen: ((MasterRow?) -> Void)?
    var onNewTask: ((MasterRow) -> Void)?

    /// What the place offers per master, for a harness.
    var shownNames: [String] { rows.map(\.master.name) }
    var shownStates: [String] { rows.map { $0.state(now: now).text } }
    var headerBadge: String? { badgeText.isEmpty ? nil : badgeText }

    init() {
        super.init(symbol: "person.crop.rectangle.stack", caption: MasterWords.title)
        onPress = { [weak self] in self?.onOpen?(nil) }
        render()
        for name in [MasterDesk.didChange, MachineDesk.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }

    /// Shown while any machine keeps masters; at rest with none made, the tooltip says so.
    func render(now: Date = Date()) {
        let desk = MasterDesk.shared
        isHidden = !desk.anyKeepsMasters
        guard !isHidden else { return }
        self.now = now
        rows = desk.board.rows
        let pending = desk.board.pending
        show(badge: pending)
        let lines = rows.map { "\($0.master.name): \($0.state(now: now).text)" }
        toolTip = rows.isEmpty ? (desk.silentLine ?? MasterWords.empty) : lines.joined(separator: "\n")
        setAccessibilityLabel(
            [MasterWords.title, rows.isEmpty ? MasterWords.empty : nil, pending > 0 ? MasterWords.toReview(pending) : nil]
                .compactMap { $0 }.joined(separator: ", "))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !rows.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, row) in rows.enumerated() {
            let open = NSMenuItem(
                title: Localized.text("Open %@", row.master.name), action: #selector(openChosen(_:)), keyEquivalent: "")
            open.target = self
            open.tag = index
            menu.addItem(open)
        }
        menu.addItem(.separator())
        for (index, row) in rows.enumerated() {
            let task = NSMenuItem(
                title: MasterWords.newTask + " · " + row.master.name + "…", action: #selector(newTaskChosen(_:)),
                keyEquivalent: "")
            task.target = self
            task.tag = index
            menu.addItem(task)
        }
        return menu
    }

    @objc private func openChosen(_ item: NSMenuItem) {
        guard rows.indices.contains(item.tag) else { return }
        onOpen?(rows[item.tag])
    }

    @objc private func newTaskChosen(_ item: NSMenuItem) {
        guard rows.indices.contains(item.tag) else { return }
        onNewTask?(rows[item.tag])
    }
}
