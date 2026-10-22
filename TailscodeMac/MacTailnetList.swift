import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The Tailscale API token this Mac keeps, for the copy that cannot ask the daemon.
///
/// The direct build reads `tailscale status` and needs nothing stored. The store build is not
/// allowed to run that command or open its socket, so the peer list comes from Tailscale's API
/// the way the phone's does, and a token that expires is remembered as refused rather than used
/// again. The machines last seen are kept so a dead token does not empty the scan.
enum MacTailnetCredentials {
    private static let keychain = KeychainSecretStore()
    private static let tokenKey = "tailscale.token"
    private static let rejectedKey = "tailscale.rejected"
    private static let knownKey = "tailscale.known"
    static let keysPage = "https://login.tailscale.com/admin/settings/keys"

    static var token: String? {
        let stored = (try? keychain.value(for: tokenKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var key: TailnetKey {
        guard token != nil else { return .none }
        return UserDefaults.standard.bool(forKey: rejectedKey) ? .rejected : .saved
    }

    static func setToken(_ value: String) throws {
        try keychain.setValue(value, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
    }

    static func clearToken() {
        try? keychain.removeValue(for: tokenKey)
        UserDefaults.standard.removeObject(forKey: rejectedKey)
        UserDefaults.standard.removeObject(forKey: knownKey)
    }

    static func markRejected() {
        UserDefaults.standard.set(true, forKey: rejectedKey)
    }

    static var rememberedDevices: [TailscaleDevice] {
        guard let data = UserDefaults.standard.data(forKey: knownKey),
            let known = try? JSONDecoder().decode(KnownMachines.self, from: data)
        else { return [] }
        return known.devices()
    }

    static func remember(_ listing: [TailscaleDevice]) {
        guard let data = try? JSONEncoder().encode(KnownMachines.remembering(listing)) else { return }
        UserDefaults.standard.set(data, forKey: knownKey)
    }
}

/// Who is on this Mac's tailnet, asked the way this build is allowed to ask.
///
/// The direct build runs Tailscale's command line. The store build cannot, so it asks Tailscale's
/// API with the token above, and falls back to the machines it last saw when that token is missing
/// or refused. Either way the result is the scanner's own device list, so a sweep does not care
/// which road filled it.
enum MacTailnetList {
    struct Listing: Sendable {
        var devices: [TailscaleDevice]
        var reading: TailscaleReading
        /// No live list and nothing remembered. The scan has to ask for a token before it can look.
        var needsToken: Bool
        var fromMemory: Bool
        var rejected: Bool
    }

    static func load(includingThisMachine: Bool) async -> Listing {
        #if TAILSCODE_MAS
            return await loadFromAPI(includingThisMachine: includingThisMachine)
        #else
            let survey = await Task.detached(priority: .utility) { DiscoverySurvey.read() }.value
            return Listing(
                devices: survey.scannable(includingThisMachine: includingThisMachine),
                reading: survey.reading, needsToken: false, fromMemory: false, rejected: false)
        #endif
    }

    #if TAILSCODE_MAS
        private static func loadFromAPI(includingThisMachine: Bool) async -> Listing {
            let reading = await Task.detached(priority: .utility) { TailnetStatusMac.read().reading }.value
            let key = MacTailnetCredentials.key
            if key == .saved, let token = MacTailnetCredentials.token {
                do {
                    let fetched = try await TailscaleClient().fetchDevices(with: token)
                    MacTailnetCredentials.remember(fetched)
                    return Listing(
                        devices: scannable(fetched, includingThisMachine: includingThisMachine),
                        reading: reading, needsToken: false, fromMemory: false, rejected: false)
                } catch {
                    if TailscaleClient.isRejection(error) { MacTailnetCredentials.markRejected() }
                }
            }
            let remembered = MacTailnetCredentials.rememberedDevices
            if !remembered.isEmpty {
                return Listing(
                    devices: scannable(remembered, includingThisMachine: includingThisMachine),
                    reading: reading, needsToken: false, fromMemory: true,
                    rejected: MacTailnetCredentials.key == .rejected)
            }
            return Listing(
                devices: [], reading: reading, needsToken: true, fromMemory: false,
                rejected: MacTailnetCredentials.key == .rejected)
        }

        private static func scannable(
            _ devices: [TailscaleDevice], includingThisMachine: Bool
        ) -> [TailscaleDevice] {
            var listed = TailnetScanner.scannableDevices(devices)
            guard includingThisMachine, let address = TailnetStatusMac.localAddress(),
                !listed.contains(where: { $0.addresses.contains(address) })
            else { return listed }
            let name = Host.current().localizedName ?? "This Mac"
            listed.insert(
                TailscaleDevice(
                    id: address, name: name, hostname: name, addresses: [address], os: "macOS",
                    connectedToControl: true),
                at: 0)
            return listed
        }
    #endif
}

/// The one place a token is typed. Discovery and Settings both open it, and a token is checked
/// with Tailscale before it is kept, so a wrong paste is said here rather than as an empty scan.
@MainActor
final class TailnetTokenSheet: NSObject {
    /// A sheet outlives the call that opened it, and its buttons only know their target weakly:
    /// without this the controller was gone before the first press, so Save and Cancel did nothing.
    private static var active: [TailnetTokenSheet] = []

    private let host: NSWindow
    private let onSaved: () -> Void
    private let window: NSWindow
    private let field = NSSecureTextField()
    private let status = MacDialogs.detailLabel("", wraps: true)
    private var checking = false

    static func present(on host: NSWindow, onSaved: @escaping @MainActor () -> Void = {}) {
        let sheet = TailnetTokenSheet(host: host, onSaved: onSaved)
        active.append(sheet)
        host.beginSheet(sheet.window) { _ in
            active.removeAll { $0 === sheet }
        }
    }

    private init(host: NSWindow, onSaved: @escaping @MainActor () -> Void) {
        self.host = host
        self.onSaved = onSaved
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = Localized.text("API access token")
        build()
    }

    private func build() {
        field.placeholderString = "tskey-api-..."
        field.stringValue = MacTailnetCredentials.token ?? ""
        status.stringValue = TailnetTokenReading.note
        let open = RowKit.ActionButton(title: Localized.text("Open Keys page to generate token")) {
            guard let url = URL(string: MacTailnetCredentials.keysPage) else { return }
            NSWorkspace.shared.open(url)
        }
        let save = RowKit.ActionButton(title: Localized.text("Save")) { [weak self] in self?.save() }
        save.keyEquivalent = "\r"
        let cancel = RowKit.ActionButton(title: Localized.text("Cancel")) { [weak self] in
            self?.close()
        }
        cancel.keyEquivalent = "\u{1b}"
        var buttons = [cancel, save]
        if MacTailnetCredentials.token != nil {
            let clear = RowKit.ActionButton(title: Localized.text("Clear token")) { [weak self] in
                MacTailnetCredentials.clearToken()
                self?.close()
            }
            buttons.insert(clear, at: 0)
        }
        let row = NSStackView(views: [RowKit.spacer()] + buttons)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let column = FillingStack(views: [
            MacDialogs.detailLabel(
                Localized.text(
                    "Generate an API access token with Devices read access on the Tailscale keys page. One paste is all you need."
                ), wraps: true),
            open, field, status, row,
        ])
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = column
        column.widthAnchor.constraint(equalToConstant: 460).isActive = true
    }

    private func save() {
        guard !checking else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        checking = true
        status.stringValue = TailnetTokenReading.checking
        let policy = ConnectionPolicy(
            requestTimeout: .seconds(15), resourceTimeout: .seconds(20))
        Task { [weak self] in
            do {
                let devices = try await TailscaleClient(policy: policy).fetchDevices(with: token)
                try MacTailnetCredentials.setToken(token)
                MacTailnetCredentials.remember(devices)
                await MainActor.run {
                    guard let self else { return }
                    let saved = self.onSaved
                    self.close()
                    saved()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.checking = false
                    self.status.stringValue =
                        TailscaleClient.isRejection(error)
                        ? TailnetTokenReading.rejected : TailnetTokenReading.unreachable
                }
            }
        }
    }

    private func close() {
        host.endSheet(window)
    }
}
