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
    private let onCreate:
        @MainActor (ConnectionProfile, String?, @escaping @MainActor (NewChatFailure?) -> Void) ->
            Void
    private let onFix:
        @MainActor (NewChatFailure.Fix, @escaping @MainActor (NewChatFailure?) -> Void) -> Void
    /// What the sheet is doing. It outlives Start: a chat is minted on another machine, and a
    /// sheet that closes the instant a request goes out cannot say whether it worked.
    private var phase: NewChatPhase = .asking
    /// Folders already read off a server's disk, kept for the sheet's life so walking back up a
    /// path never asks the machine twice, and a folder it refused is refused from memory.
    private var listings: [NewChatListingRequest: NewChatListing] = [:]
    private var fetching: Set<NewChatListingRequest> = []
    private var lastAttempt: (profile: ConnectionProfile, directory: String?)?
    private let status = NewChatStatusView()
    private let cancel = NSButton()
    private let start = NSButton()
    private var chooser: NewChatChooser
    private let heading = NSTextField(labelWithString: "")
    private let defaultsLabel = NSTextField(labelWithString: "")
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
        onFix: @escaping @MainActor (
            NewChatFailure.Fix, @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void = { _, done in done(nil) },
        onCreate: @escaping @MainActor (
            ConnectionProfile, String?, @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let sheet = NewChatSheet(
            profiles: profiles, entries: entries, unreachable: unreachable,
            localAddresses: localAddresses,
            preferredServer: preferredServer
                ?? UserDefaults.standard.string(forKey: preferredServerKey),
            onFix: onFix, onCreate: onCreate)
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
        onFix: @escaping @MainActor (
            NewChatFailure.Fix, @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onCreate: @escaping @MainActor (
            ConnectionProfile, String?, @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void
    ) {
        self.profiles = profiles
        self.entries = entries
        self.onCreate = onCreate
        self.onFix = onFix
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

        heading.font = MacTheme.Ramp.font(.cardTitle)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        defaultsLabel.font = MacTheme.Ramp.font(.panelFootnote)
        defaultsLabel.textColor = MacTheme.Color.secondaryLabel
        defaultsLabel.lineBreakMode = .byTruncatingTail
        defaultsLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(defaultsLabel)

        field.placeholderString = Localized.text("Where the agent works, e.g. ~/Dev/thing")
        field.font = MacTheme.Ramp.font(.code)
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
        empty.font = MacTheme.Ramp.font(.panelLabel)
        empty.textColor = MacTheme.Color.tertiaryLabel
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)

        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)

        hint.font = MacTheme.Ramp.font(.rowNote)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        cancel.title = Localized.text("Cancel")
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelSheet)
        start.title = Localized.text("Start")
        start.bezelStyle = .rounded
        start.target = self
        start.action = #selector(startFocused)
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
            defaultsLabel.topAnchor.constraint(
                equalTo: heading.bottomAnchor, constant: MacTheme.Spacing.xs),
            defaultsLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            defaultsLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            field.topAnchor.constraint(
                equalTo: defaultsLabel.bottomAnchor, constant: MacTheme.Spacing.s),
            field.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: MacTheme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: MacTheme.Spacing.xl),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            status.topAnchor.constraint(equalTo: field.topAnchor),
            status.bottomAnchor.constraint(lessThanOrEqualTo: scroll.bottomAnchor),
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

    /// The shell half: whatever folder the chooser says it wants, answered from this sheet's own
    /// memory when it can be, and read off the server once when it cannot. A listing back for a
    /// query the person has already left is dropped by the chooser rather than rendered stale.
    private func serviceListing() {
        guard let request = chooser.wantedListing else { return }
        if let cached = listings[request] {
            chooser.offer(cached)
            return
        }
        guard fetching.insert(request).inserted else { return }
        guard let profile = profiles.first(where: { $0.id == request.profileID }),
            let backend = ServerDirectory.shared.backend(for: profile) as? any FileBrowsingBackend
        else {
            listings[request] = NewChatListing(
                profileID: request.profileID, parent: request.parent, folders: [], failed: true)
            fetching.remove(request)
            return
        }
        Task { [weak self] in
            let nodes = try? await backend.listFiles(path: request.parent)
            guard let self else { return }
            self.fetching.remove(request)
            let listing = NewChatListing(
                profileID: request.profileID, parent: request.parent,
                folders: nodes.map { $0.filter(\.isDirectory).map(\.name) } ?? [],
                failed: nodes == nil)
            self.listings[request] = listing
            self.chooser.offer(listing)
            self.serviceListing()
            if self.phase == .asking { self.rebuild() }
        }
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
            guard let self, event.window === self.sheet else { return event }
            if self.phase != .asking { return self.statusKey(event) }
            guard let chord = MacKeys.chord(for: event),
                let command = NewChatChooser.command(for: chord, mode: self.chooser.mode)
            else { return event }
            let answer = self.chooser.handle(command)
            self.serviceListing()
            self.rebuild()
            self.apply(answer.outcome)
            return answer.handled ? nil : event
        }
    }

    private func rebuild() {
        switch phase {
        case .starting(let server):
            heading.stringValue = Localized.text("Starting on %@…", server)
            hint.stringValue = Localized.text("Asking the server for a conversation")
            status.showWaiting()
            setChrome(asking: false)
            cancel.title = Localized.text("Cancel")
            start.isHidden = true
            return
        case .failed(let failure):
            heading.stringValue = Localized.text("Could not start the chat")
            hint.stringValue = ""
            status.show(failure)
            setChrome(asking: false)
            cancel.title = Localized.text("Back")
            start.isHidden = failure.actionTitle == nil
            start.title = failure.actionTitle ?? Localized.text("Start")
            start.action = #selector(takeFix)
            return
        case .asking:
            status.isHidden = true
            setChrome(asking: true)
            cancel.title = Localized.text("Cancel")
            start.isHidden = false
            start.title = Localized.text("Start")
            start.action = #selector(startFocused)
        }
        heading.stringValue = chooser.heading
        renderDefaults()
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

    /// What the chat will start with, worn under the server's name: the model as the same coloured
    /// chip the chat list wears, or the sentence that says the server decides. Re-read on every
    /// rebuild so switching servers re-labels the chat before it exists.
    private func renderDefaults() {
        guard let defaults = chooser.defaults else {
            defaultsLabel.stringValue = ""
            return
        }
        let font = MacTheme.Ramp.font(.panelFootnote)
        let text = NSMutableAttributedString(
            string: defaults.line,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel])
        if let chip = defaults.chip {
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            text.append(SidebarSessionCell.chipText(chip))
        }
        defaultsLabel.attributedStringValue = text
        defaultsLabel.setAccessibilityLabel(defaults.sentence)
    }

    /// While a machine is being waited on, the question's own chrome goes away rather than sitting
    /// there inert: a field that cannot be typed into and a list that cannot be picked from are
    /// worse than absent.
    private func setChrome(asking: Bool) {
        field.isHidden = !asking
        defaultsLabel.isHidden = !asking
        scroll.isHidden = !asking
        empty.isHidden = true
        status.isHidden = asking
        if !asking { sheet.makeFirstResponder(nil) }
    }

    /// Once the sheet is waiting or explaining, the chooser's grammar is not the sheet's: return
    /// takes the fix, escape steps back one state, and nothing else reaches a list that is not
    /// on screen. ⌘ is the exception, because this monitor runs before the menu bar ever sees a
    /// key equivalent — swallowing it would leave the whole app without ⌘Q for as long as a server
    /// takes to answer.
    private func statusKey(_ event: NSEvent) -> NSEvent? {
        guard !event.modifierFlags.contains(.command) else { return event }
        switch event.keyCode {
        case 53:
            if phase.failure != nil { show(.asking) } else { close() }
        case 36, 76:
            if let failure = phase.failure, failure.actionTitle != nil { applyFix(failure.fix) }
        default:
            break
        }
        return nil
    }

    @objc private func takeFix() {
        guard let failure = phase.failure else { return }
        applyFix(failure.fix)
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
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            show(.failed(NewChatDiagnosis.noSuchServer()))
            return
        }
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty ? nil : trimmed
        if let target { FileBrowserRecents.record(target, for: profileID) }
        UserDefaults.standard.set(profileID, forKey: Self.preferredServerKey)
        begin(profile: profile, directory: target)
    }

    /// Start, and stay up: the sheet holds the question until the other machine has answered, so
    /// a chat that cannot be created says why where it was asked for.
    ///
    /// The server is re-read from the directory at the moment of the mint, never taken from the
    /// copy this sheet opened with: a repoint applied from the failure card rewrote the address a
    /// second ago, and retrying against the stale copy would hit the same wrong port again.
    private func begin(profile stale: ConnectionProfile, directory: String?) {
        let profile = ServerDirectory.shared.profiles.first { $0.id == stale.id } ?? stale
        lastAttempt = (profile, directory)
        show(.starting(server: profile.name))
        onCreate(profile, directory) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                self.close()
                return
            }
            self.show(.failed(failure))
        }
    }

    /// The remedy is applied and the chat retried on the spot: someone who pressed "Use :4098"
    /// asked for the conversation, not for a settings screen.
    private func applyFix(_ fix: NewChatFailure.Fix) {
        switch fix {
        case .none:
            close()
        case .retry:
            guard let attempt = lastAttempt else { return show(.asking) }
            begin(profile: attempt.profile, directory: attempt.directory)
        case .editServer:
            onFix(fix) { _ in }
            close()
        case .repoint:
            show(.starting(server: lastAttempt?.profile.name ?? ""))
            onFix(fix) { [weak self] failure in
                guard let self else { return }
                if let failure { return self.show(.failed(failure)) }
                guard let attempt = self.lastAttempt else { return self.show(.asking) }
                let refreshed =
                    ServerDirectory.shared.profiles.first { $0.id == attempt.profile.id }
                    ?? attempt.profile
                self.begin(profile: refreshed, directory: attempt.directory)
            }
        }
    }

    private func show(_ next: NewChatPhase) {
        phase = next
        rebuild()
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
        guard phase.failure != nil else {
            close()
            return
        }
        show(.asking)
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
        serviceListing()
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

        number.font = MacTheme.Ramp.font(.rowNote)
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
            number.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
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
        title.font = MacTheme.Ramp.font(.cardTitle)
        layer?.backgroundColor =
            focused
            ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(row.title)
        if row.origin == .browse {
            path.stringValue = row.detail
            path.font = MacTheme.Ramp.font(.panelFootnote)
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
                .font: MacTheme.Ramp.font(.rowNote), .foregroundColor: MacTheme.Color.secondaryLabel,
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
        case .listed: return MacTheme.Color.secondaryLabel
        }
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.metricLabel)
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

/// The two states a new chat can be in that are not a question: waiting on another machine, and
/// the reason it did not happen. One view, because they are the same shape — a symbol, a
/// sentence, and the words under it — and because a modal that swaps its whole body for an error
/// is how a person knows the error belongs to what they just did.
final class NewChatStatusView: NSView {
    private let badge = ActivityBadgeView(pointSize: 15)
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        badge.translatesAutoresizingMaskIntoConstraints = false
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentTintColor = MacTheme.Color.danger
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.font = MacTheme.Ramp.font(.panelLabel)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(symbol)
        addSubview(title)
        addSubview(detail)
        NSLayoutConstraint.activate([
            symbol.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.l),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 26),
            badge.centerXAnchor.constraint(equalTo: symbol.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            title.topAnchor.constraint(equalTo: symbol.topAnchor),
            title.leadingAnchor.constraint(
                equalTo: symbol.trailingAnchor, constant: MacTheme.Spacing.m),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: MacTheme.Spacing.xs),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Waiting breathes on the same swell every busy badge in the app uses, so a sheet that is
    /// working looks like work rather than like a window that stopped.
    func showWaiting() {
        isHidden = false
        symbol.isHidden = true
        badge.isHidden = false
        badge.activity = .working
        title.stringValue = Localized.text("Asking the server for a conversation")
        title.textColor = MacTheme.Color.label
        detail.stringValue = Localized.text(
            "A chat is minted on the other machine; this takes a moment over a tailnet.")
    }

    func show(_ failure: NewChatFailure) {
        isHidden = false
        badge.isHidden = true
        badge.activity = nil
        symbol.isHidden = false
        symbol.image = NSImage(
            systemSymbolName: failure.symbol, accessibilityDescription: failure.title)
        title.stringValue = failure.title
        title.textColor = MacTheme.Color.label
        detail.stringValue = failure.detail
        setAccessibilityLabel(failure.spoken)
    }
}
