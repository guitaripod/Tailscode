import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A new conversation needs a server and a directory; everything else the agent works out. The
/// field opens focused and pre-filled with the last directory, so ⌘N then Enter starts a chat
/// where the last one worked. When the chosen server is this same Mac, Browse… opens the
/// desktop's own folder chooser — the one place a native picker tells the truth; for a remote
/// server it stays hidden rather than offering the wrong disk.
@MainActor
final class NewChatSheet {
    private static var active: [NewChatSheet] = []

    private let sheet: NSWindow
    private let profiles: [ConnectionProfile]
    private let localAddresses: Set<String>
    private let onCreate: @MainActor (ConnectionProfile, String?) -> Void
    private let directoryField = NSTextField()
    private let serverPicker = NSPopUpButton()
    private let browseButton = NSButton()

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

    static func present(
        on host: NSWindow, profiles: [ConnectionProfile], recentDirectories: [String],
        localAddresses: Set<String>,
        onCreate: @escaping @MainActor (ConnectionProfile, String?) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let sheet = NewChatSheet(
            profiles: profiles, recentDirectories: recentDirectories,
            localAddresses: localAddresses, onCreate: onCreate)
        active.append(sheet)
        host.beginSheet(sheet.sheet) { _ in
            active.removeAll { $0 === sheet }
        }
        sheet.sheet.makeFirstResponder(sheet.directoryField)
        sheet.directoryField.currentEditor()?.selectAll(nil)
    }

    private init(
        profiles: [ConnectionProfile], recentDirectories: [String],
        localAddresses: Set<String>,
        onCreate: @escaping @MainActor (ConnectionProfile, String?) -> Void
    ) {
        self.profiles = profiles
        self.localAddresses = localAddresses
        self.onCreate = onCreate
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("New conversation")

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: Localized.text("New conversation"))
        title.font = MacTheme.Font.emphasis()
        column.addArrangedSubview(title)

        if profiles.count > 1 {
            column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("SERVER")))
            for profile in profiles {
                serverPicker.addItem(withTitle: ServerLabel.display(profile))
                serverPicker.lastItem?.toolTip = ServerLabel.address(profile)
            }
            serverPicker.target = self
            serverPicker.action = #selector(serverPicked)
            column.addArrangedSubview(serverPicker)
        }

        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("DIRECTORY")))
        directoryField.placeholderString = Localized.text("Where the agent works, e.g. ~/Dev/thing")
        directoryField.font = MacTheme.Font.mono()
        directoryField.target = self
        directoryField.action = #selector(start)
        if let first = recentDirectories.first { directoryField.stringValue = first }

        browseButton.title = Localized.text("Browse…")
        browseButton.bezelStyle = .rounded
        browseButton.setButtonType(.momentaryPushIn)
        browseButton.target = self
        browseButton.action = #selector(browse)
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        let directoryRow = NSStackView(views: [directoryField, browseButton])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(directoryRow)

        for directory in recentDirectories.prefix(6) {
            let recent = NSButton(
                title: directory, target: self, action: #selector(recentPicked))
            recent.bezelStyle = .inline
            recent.isBordered = false
            recent.alignment = .left
            recent.font = MacTheme.Font.mono(11)
            recent.contentTintColor = MacTheme.Color.secondaryLabel
            recent.lineBreakMode = .byTruncatingMiddle
            column.addArrangedSubview(recent)
            column.setCustomSpacing(2, after: recent)
        }

        let cancel = NSButton(title: Localized.text("Cancel"), target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1B}"
        let startButton = NSButton(title: Localized.text("Start"), target: self, action: #selector(start))
        startButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(buttons)

        sheet.contentView = column
        column.widthAnchor.constraint(equalToConstant: 520).isActive = true
        syncBrowseVisibility()
        sheet.setContentSize(column.fittingSize)
    }

    private var chosenProfile: ConnectionProfile {
        guard profiles.count > 1 else { return profiles[0] }
        let index = serverPicker.indexOfSelectedItem
        return profiles.indices.contains(index) ? profiles[index] : profiles[0]
    }

    @objc private func serverPicked() {
        syncBrowseVisibility()
    }

    @objc private func recentPicked(_ sender: NSButton) {
        directoryField.stringValue = sender.title
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let seed = Self.browseSeed(directoryField.stringValue) {
            panel.directoryURL = URL(fileURLWithPath: seed, isDirectory: true)
        }
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            self?.directoryField.stringValue = picked.path
        }
    }

    @objc private func start() {
        let directory = directoryField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let profile = chosenProfile
        close()
        onCreate(profile, directory.isEmpty ? nil : directory)
    }

    @objc private func cancelSheet() {
        close()
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    private func syncBrowseVisibility() {
        browseButton.isHidden = !Self.isLocal(chosenProfile, localAddresses: localAddresses)
    }

    /// A profile is local when its host is a loopback, the hostname, or the address Tailscale
    /// gives this Mac — matching short names too, because MagicDNS speaks both.
    static func isLocal(_ profile: ConnectionProfile, localAddresses: Set<String>) -> Bool {
        guard let host = profile.baseURL.host?.lowercased() else { return false }
        if localAddresses.contains(host) { return true }
        let shortNames = Set(localAddresses.map { String($0.split(separator: ".").first ?? "") })
        return shortNames.contains(String(host.split(separator: ".").first ?? ""))
    }

    /// The picker opens where the field points when that is a real folder here, expanding a
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
