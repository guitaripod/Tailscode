import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A DeepSeek model reached through a direct API key is metered by that key's prepaid balance,
/// not by any plan's windows. The key is optional and lives in the same Keychain the connection
/// profiles do — one service, one account name, the ones the phone and the desktop already
/// agreed on — so the machine that bills DeepSeek directly is the machine that reads the balance.
enum DeepSeekCredentials {
    private static let apiKey = "deepseek.apiKey"
    private static let keychain = KeychainSecretStore()

    static var token: String? {
        let stored = (try? keychain.value(for: apiKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    @MainActor
    static func setToken(_ value: String) throws {
        try keychain.setValue(value, for: apiKey)
        DeepSeekBalance.forgetLastFetch()
        NotificationCenter.default.post(name: DeepSeekBalance.didChange, object: nil)
    }

    @MainActor
    static func clearToken() {
        try? keychain.removeValue(for: apiKey)
        DeepSeekBalance.forgetLastFetch()
        NotificationCenter.default.post(name: DeepSeekBalance.didChange, object: nil)
    }
}

/// Reads the DeepSeek account balance straight from api.deepseek.com. No key returns nil — no
/// card rather than an error, so the surface stays exactly what it was. Best-effort by design:
/// every caller may lose the race to a dead network and keeps whatever it already had, and a
/// throttle keeps the sidebar's poll and the panel's refresh from hammering the endpoint.
enum DeepSeekBalance {
    static let providerName = "DeepSeek"
    /// Posted when the key is set or removed, so a surface drawn from the last reading drops or
    /// gains the balance at once rather than at the next poll.
    static let didChange = Notification.Name("tailscode.mac.deepseek.didChange")

    private static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private static let throttle: TimeInterval = 120

    @MainActor private static var lastFetch: Date?
    /// The last reading the endpoint answered, so a throttled or failed refresh keeps the card it
    /// already had — the surface never drops a balance it has shown, only one it never had.
    @MainActor private static var lastReading: Reading?

    struct Balance: Codable, Sendable {
        struct Info: Codable, Sendable {
            var currency: String
            var totalBalance: String
            var grantedBalance: String
            var toppedUpBalance: String
        }

        var isAvailable: Bool
        var balanceInfos: [Info]
    }

    struct Reading: Sendable, Equatable {
        var total: Double
        var toppedUp: Double
        var granted: Double
        var currency: String
        var isAvailable: Bool
    }

    @MainActor
    static var cached: Reading? { lastReading }

    @MainActor
    static func forgetLastFetch() {
        lastFetch = nil
        lastReading = nil
    }

    /// The key is read off the main actor because a Keychain that has no session to answer in —
    /// the build loop reaches this Mac over ssh — can take as long as it likes, and a poll that is
    /// nobody's idea of urgent must never be what stops the window redrawing.
    @MainActor
    @discardableResult
    static func refresh() async -> Reading? {
        guard let key = await Task.detached(operation: { DeepSeekCredentials.token }).value else {
            lastReading = nil
            return nil
        }
        if let last = lastFetch, Date().timeIntervalSince(last) < throttle { return lastReading }
        lastFetch = Date()
        guard let reading = await fetch(key: key) else { return lastReading }
        lastReading = reading
        return reading
    }

    /// The servers' reports with this machine's own reading folded in. The balance is nobody's
    /// server's to report — it is read here, from the key this Mac holds — so it joins the account
    /// where the account is drawn, and ``QuotaRollup`` folds it beside the plans like any other
    /// provider.
    @MainActor
    static func folded(into reports: [(String, UsageQuota)]) -> [(String, UsageQuota)] {
        guard let lastReading else { return reports }
        return reports + [("", snapshot(for: lastReading))]
    }

    /// A balance is not a quota: it carries no cap and no reset, so its single gauge is the money
    /// itself — `usedUSD` with no `limitUSD` is how the renderers recognise a balance row and skip
    /// the bar. An empty balance reads as the wall it is, so its fraction is 1 and the chooser's
    /// billing rule handles the rest.
    static func snapshot(for reading: Reading) -> UsageQuota {
        let subtitle =
            reading.isAvailable
            ? Localized.text("Prepaid balance · direct API")
            : Localized.text("Balance is empty — top up to keep DeepSeek models running")
        return UsageQuota(
            providerName: providerName,
            subtitle: subtitle,
            source: "api.deepseek.com",
            live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "balance",
                    label: Localized.text("Balance"),
                    fraction: reading.isAvailable ? 0 : 1,
                    resetsAt: nil,
                    trustedReset: false,
                    usedUSD: reading.total,
                    limitUSD: nil,
                    currency: reading.currency)
            ],
            details: [
                UsageQuota.Detail(
                    key: Localized.text("Topped up"),
                    value: money(reading.toppedUp, reading.currency)),
                UsageQuota.Detail(
                    key: Localized.text("Granted"),
                    value: money(reading.granted, reading.currency)),
            ])
    }

    /// What a balance row reads as: the money itself, and "Empty" at the wall.
    static func amount(for gauge: UsageQuota.Gauge) -> String {
        if gauge.fraction >= QuotaSurface.exhaustedFloor { return Localized.text("Empty") }
        return money(gauge.usedUSD ?? 0, gauge.currency)
    }

    static func money(_ value: Double, _ currency: String?) -> String {
        QuotaGlance.money(value, currency)
    }

    private static func fetch(key: String) async -> Reading? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let balance = try? decoder.decode(Balance.self, from: data),
            let info = balance.balanceInfos.first
        else { return nil }
        return Reading(
            total: Double(info.totalBalance) ?? 0,
            toppedUp: Double(info.toppedUpBalance) ?? 0,
            granted: Double(info.grantedBalance) ?? 0,
            currency: info.currency,
            isAvailable: balance.isAvailable)
    }
}

/// The one editor for the optional DeepSeek API key, reached from Settings and from the balance
/// card's own empty state. Purely additive: without a key the usage surfaces stay exactly as they
/// were, and with one the prepaid balance joins the meters. Saving an empty field is how a key is
/// removed, so the state and the gesture that ends it never disagree.
@MainActor
enum DeepSeekKeySheet {
    private static let keysURL = URL(string: "https://platform.deepseek.com/api_keys")!

    static func present(on window: NSWindow?, onChange: @escaping @MainActor () -> Void) {
        let hadKey = DeepSeekCredentials.hasToken
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Localized.text("DeepSeek API key")
        alert.informativeText = [
            Localized.text(
                "DeepSeek models reached through opencode normally ride your opencode go plan. If you bill them straight to DeepSeek instead, paste the platform's API key here and Tailscode will show the prepaid balance beside the plan quotas."),
            Localized.text(
                "Stored only in this Mac's Keychain. Read once per refresh from api.deepseek.com — the key never touches your servers."),
        ].joined(separator: "\n\n")

        let field = NSSecureTextField(string: DeepSeekCredentials.token ?? "")
        field.placeholderString = "sk-..."
        field.font = MacTheme.Ramp.font(.toolOutput)
        let link = RowKit.linkButton(
            Localized.text("Open platform.deepseek.com to get a key")
        ) {
            NSWorkspace.shared.open(keysURL)
        }
        let accessory = NSStackView(views: [field, link])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = MacTheme.Spacing.xs
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: Localized.text("Save"))
        if hadKey { alert.addButton(withTitle: Localized.text("Remove key")) }
        alert.addButton(withTitle: Localized.text("Cancel"))

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                save(field.stringValue, on: window, onChange: onChange)
            case .alertSecondButtonReturn where hadKey:
                DeepSeekCredentials.clearToken()
                onChange()
            default:
                return
            }
        }
        guard let window else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    private static func save(
        _ typed: String, on window: NSWindow?, onChange: @escaping @MainActor () -> Void
    ) {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            DeepSeekCredentials.clearToken()
            onChange()
            return
        }
        do {
            try DeepSeekCredentials.setToken(key)
            onChange()
        } catch {
            refuse(error, on: window)
        }
    }

    /// A Keychain that refuses the write is the one failure this box can have, and it is said out
    /// loud — a key that looks saved and is not would show up minutes later as a balance that
    /// never arrives. The second sheet waits a turn because the first one is still leaving.
    private static func refuse(_ error: any Error, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localized.text("The Keychain refused the key")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Localized.text("Close"))
        guard let window else {
            alert.runModal()
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
