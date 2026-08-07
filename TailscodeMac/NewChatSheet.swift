import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A new conversation is two questions — which machine, which folder — asked as one ranked list.
///
/// `NewChatChooser` decides all of it: which folders this device already knows for the chosen
/// server, how they rank against what is being typed, where each one came from, and what every key
/// means in each of the two modes. This sheet draws that answer and does nothing else, so the Mac,
/// the phone and the Linux desktop are the same modal rendered three times. When the chosen server
/// is this same Mac, Browse… opens the desktop's own folder chooser — the one place a native picker
/// tells the truth; a remote server never offers it rather than offering the wrong disk.
@MainActor
final class NewChatSheet: NSObject {
    private static var active: [NewChatSheet] = []
    /// The server a chat was last started on, so the overwhelmingly common answer is pre-chosen
    /// rather than re-asked. Device-local, like every other `tailscode.*` preference.
    private static let preferredServerKey = "tailscode.newChat.server"

    private let sheet: NSWindow
    private let profiles: [ConnectionProfile]
    private let entries: [SessionEntry]
    private let onCreate: @MainActor (ConnectionProfile, String?) -> Void
    private var chooser: NewChatChooser
    private let heading = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var monitor: Any?

    /// This machine answering its own tailnet address is still this machine — read once, off the
    /// main actor, because `tailscale ip` is a subprocess and the answer does not change within a
    /// run.
    nonisolated static let localAddresses: Set<String> = {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, 255) == 0 { hosts.insert(String(cString: name).lowercased()) }
        for binary in [
            "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ] where FileManager.default.isExecutableFile(atPath: binary) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["ip"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let address = line.trimmingCharacters(in: .whitespaces)
                if !address.isEmpty { hosts.insert(address.lowercased()) }
            }
            break
        }
        return hosts
    }()

    /// - Parameter preferredServer: the server a pane's chooser already settled on, which is never
    ///   asked twice; absent one, the server the last chat was started on leads.
    static func present(
        on host: NSWindow, profiles: [ConnectionProfile], entries: [SessionEntry],
        unreachable: [String], localAddresses: Set<String>, preferredServer: String? = nil,
        onCreate: @escaping @MainActor (ConnectionProfile, String?) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let sheet = NewChatSheet(
            profiles: profiles, entries: entries, unreachable: unreachable,
            localAddresses: localAddresses,
            preferredServer: preferredServer
                ?? UserDefaults.standard.string(forKey: preferredServerKey),
            onCreate: onCreate)
        active.append(sheet)
        host.beginSheet(sheet.sheet) { _ in
            sheet.teardown()
            active.removeAll { $0 === sheet }
        }
        sheet.rebuild()
    }

    private init(
        profiles: [ConnectionProfile], entries: [SessionEntry], unreachable: [String],
        localAddresses: Set<String>, preferredServer: String?,
        onCreate: @escaping @MainActor (ConnectionProfile, String?) -> Void
    ) {
        self.profiles = profiles
        self.entries = entries
        self.onCreate = onCreate
        chooser = NewChatChooser(
            servers: Self.servers(
                profiles: profiles, unreachable: unreachable, localAddresses: localAddresses),
            directories: Self.directories(for: profiles, entries: entries), entries: entries,
            preferredServer: preferredServer)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("New conversation")
        super.init()

        let content = NSView()
        sheet.contentView = content

        heading.font = MacTheme.Font.emphasis()
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        field.placeholderString = Localized.text("Where the agent works, e.g. ~/Dev/thing")
        field.font = MacTheme.Font.mono()
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(field)

        table.headerView = nil
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        empty.stringValue = Localized.text("Type the folder the agent should work in.")
        empty.font = MacTheme.Font.body()
        empty.textColor = MacTheme.Color.tertiaryLabel
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)

        hint.font = MacTheme.Font.mono(10)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancel = NSButton(
            title: Localized.text("Cancel"), target: self, action: #selector(cancelSheet))
        let start = NSButton(
            title: Localized.text("Start"), target: self, action: #selector(startFocused))
        let controls = NSStackView(views: [hint, spacer, cancel, start])
        controls.orientation = .horizontal
        controls.spacing = MacTheme.Spacing.s
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)

        let inset = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            field.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: MacTheme.Spacing.s),
            field.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: MacTheme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: MacTheme.Spacing.xl),
            controls.topAnchor.constraint(
                equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.s),
            controls.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
        installMonitor()
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Only a server that is this same Mac offers to browse: a native folder picker is the truth
    /// about this disk and a lie about anyone else's, and a remote listing is the file tree's job,
    /// not a modal's.
    private static func servers(
        profiles: [ConnectionProfile], unreachable: [String], localAddresses: Set<String>
    ) -> [NewChatServer] {
        profiles.map { profile in
            let local = isLocal(profile, localAddresses: localAddresses)
            return NewChatServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !unreachable.contains(ServerLabel.display(profile)),
                canBrowse: local, isLocal: local)
        }
    }

    private static func directories(
        for profiles: [ConnectionProfile], entries: [SessionEntry]
    ) -> [String: NewChatDirectories] {
        var gathered: [String: NewChatDirectories] = [:]
        for profile in profiles {
            gathered[profile.id] = NewChatDirectories.gather(
                profileID: profile.id, entries: entries)
        }
        return gathered
    }

    /// Every key the modal claims goes through the shared translation, so this Mac and the Linux
    /// desktop bind one keyboard; a chord the chooser does not claim is left to the text field,
    /// which is what keeps typing a path from tripping over the verbs.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet, let chord = MacKeys.chord(for: event),
                let command = NewChatChooser.command(for: chord, mode: self.chooser.mode)
            else { return event }
            let answer = self.chooser.handle(command)
            self.rebuild()
            self.apply(answer.outcome)
            return answer.handled ? nil : event
        }
    }

    private func rebuild() {
        heading.stringValue = chooser.heading
        hint.stringValue = chooser.hint
        if field.stringValue != chooser.query {
            field.stringValue = chooser.query
            field.currentEditor()?.selectedRange = NSRange(
                location: chooser.query.utf16.count, length: 0)
        }
        empty.isHidden = !chooser.rows.isEmpty
        scroll.isHidden = chooser.rows.isEmpty
        table.reloadData()
        revealCursor()
        syncMode()
    }

    /// The keyboard follows the chooser's own mode: while typing, the field owns the letters and
    /// holds the caret; in normal mode nothing is focused, so the letters are the verbs the rest of
    /// this app already binds. The field is never left unfocused while the modal says it is typing.
    private func syncMode() {
        switch chooser.mode {
        case .typing:
            guard field.currentEditor() == nil else { return }
            sheet.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(
                location: field.stringValue.utf16.count, length: 0)
        case .normal:
            guard field.currentEditor() != nil else { return }
            sheet.makeFirstResponder(nil)
        }
    }

    private func revealCursor() {
        guard chooser.rows.indices.contains(chooser.cursor) else { return }
        table.scrollRowToVisible(chooser.cursor)
    }

    private func apply(_ outcome: NewChatOutcome?) {
        guard let outcome else { return }
        switch outcome {
        case .start(let profileID, let directory):
            start(profileID: profileID, directory: directory)
        case .browse(let profileID):
            browse(profileID: profileID)
        case .favorite(let profileID, let path):
            FileBrowserFavorites.toggle(path, for: profileID)
            chooser = chooser.restated(
                directories: Self.directories(for: profiles, entries: entries), entries: entries)
            rebuild()
        case .dismiss:
            close()
        }
    }

    /// Starting also teaches the list: the folder joins this server's recents and the server
    /// becomes the one pre-chosen next time, so the modal is faster every time it is used.
    private func start(profileID: String, directory: String?) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty ? nil : trimmed
        if let target { FileBrowserRecents.record(target, for: profileID) }
        UserDefaults.standard.set(profileID, forKey: Self.preferredServerKey)
        let handler = onCreate
        close()
        handler(profile, target)
    }

    /// The panel is a decision in its own right — a folder picked in it was chosen, not typed — so
    /// its OK starts the conversation instead of filling the field for a second confirmation.
    private func browse(profileID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let seed = Self.browseSeed(chooser.directory ?? chooser.query) {
            panel.directoryURL = URL(fileURLWithPath: seed, isDirectory: true)
        }
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            self?.start(profileID: profileID, directory: picked.path)
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    /// The two buttons carry no key equivalents on purpose: Enter and Escape belong to the
    /// chooser's own grammar, and a default button would take Enter before the modal's monitor
    /// ever saw it.
    @objc private func cancelSheet() {
        close()
    }

    @objc private func startFocused() {
        let outcome = chooser.activate()
        rebuild()
        apply(outcome)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard chooser.rows.indices.contains(row) else { return }
        chooser.focus(row)
        let outcome = chooser.activate()
        rebuild()
        apply(outcome)
    }

    /// A profile is local when its host is a loopback, the hostname, or the address Tailscale
    /// gives this Mac — matching short names too, because MagicDNS speaks both.
    static func isLocal(_ profile: ConnectionProfile, localAddresses: Set<String>) -> Bool {
        guard let host = profile.baseURL.host?.lowercased() else { return false }
        if localAddresses.contains(host) { return true }
        let shortNames = Set(localAddresses.map { String($0.split(separator: ".").first ?? "") })
        return shortNames.contains(String(host.split(separator: ".").first ?? ""))
    }

    /// The picker opens where the chooser points when that is a real folder here, expanding a
    /// leading `~`; anywhere else it falls back to the chooser's own default.
    private static func browseSeed(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded =
            text == "~"
            ? home
            : text.hasPrefix("~/") ? home + text.dropFirst() : text
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"),
            FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return expanded
    }
}

extension NewChatSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { chooser.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        42 * MacTheme.UIScale.factor
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard chooser.rows.indices.contains(row) else { return nil }
        let view = NewChatRowView()
        view.configure(chooser.rows[row], number: row + 1, focused: row == chooser.cursor)
        return view
    }
}

extension NewChatSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        chooser.type(field.stringValue)
        rebuild()
    }
}

/// One folder: what it is called, where it came from, the letters the query landed on inside its
/// path, and how many chats already work there. Numbered, because 1–9 pick a row outright.
@MainActor
private final class NewChatRowView: NSTableCellView {
    private let number = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control

        number.font = MacTheme.Font.mono(10)
        number.textColor = MacTheme.Color.tertiaryLabel
        number.translatesAutoresizingMaskIntoConstraints = false

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.spacing = MacTheme.Spacing.xs
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)

        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let lines = NSStackView(views: [titleRow, path])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false

        addSubview(number)
        addSubview(lines)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            number.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            number.widthAnchor.constraint(equalToConstant: 14),
            lines.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            lines.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: NewChatRow, number index: Int, focused: Bool) {
        number.stringValue = index <= 9 ? "\(index)" : " "
        title.stringValue = row.title
        title.font = MacTheme.Font.emphasis()
        layer?.backgroundColor =
            focused
            ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(row.title)
        if row.origin == .browse {
            path.stringValue = row.detail
            path.font = MacTheme.Font.caption()
            path.textColor = MacTheme.Color.secondaryLabel
        } else {
            path.attributedStringValue = Self.highlighted(row)
        }
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let label = row.origin.label {
            titleRow.addArrangedSubview(
                Self.pill(label, tint: Self.tint(row.origin)))
        }
        if row.chats > 0 {
            titleRow.addArrangedSubview(
                Self.pill(
                    row.chats == 1
                        ? Localized.text("1 chat")
                        : Localized.text("%@ chats", "\(row.chats)"),
                    tint: MacTheme.Color.secondaryLabel))
        }
    }

    /// The whole path carries the match rather than the folder name alone: the chooser's offsets
    /// are into the path, and a person searching `dev/tail` needs to see which of the two words the
    /// list actually read.
    private static func highlighted(_ row: NewChatRow) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.path,
            attributes: [
                .font: MacTheme.Font.mono(10), .foregroundColor: MacTheme.Color.secondaryLabel,
            ])
        let characters = Array(row.path)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [.foregroundColor: MacTheme.Color.accent],
                range: NSRange(location: start, length: length))
        }
        return text
    }

    private static func tint(_ origin: NewChatOrigin) -> NSColor {
        switch origin {
        case .favorite: return MacTheme.Color.mark
        case .recent: return MacTheme.Color.secondaryLabel
        case .project: return MacTheme.Color.secondaryLabel
        case .typed: return MacTheme.Color.accent
        case .browse: return MacTheme.Color.secondaryLabel
        }
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9 * MacTheme.UIScale.factor, weight: .semibold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        capsule.layer?.cornerRadius = 7
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -1),
        ])
        capsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        capsule.setContentHuggingPriority(.required, for: .horizontal)
        return capsule
    }
}
