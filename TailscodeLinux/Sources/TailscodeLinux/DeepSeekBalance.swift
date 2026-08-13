import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import TailscodeCore

/// A DeepSeek model reached through a direct API key is metered by that key's prepaid balance,
/// not by any plan's windows. The key is optional and lives in the platform's secret store — the
/// same 0600 file that holds server passwords — and the balance joins the usage surfaces as one
/// provider snapshot, so the sidebar footer, the Usage panel and the chooser's walls all read
/// the same list.
enum DeepSeekCredentials {
    private static let apiKey = "deepseek.apiKey"
    private static let store = FileSecretStore()

    static var token: String? {
        let stored = (try? store.value(for: apiKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    static func setToken(_ value: String) throws {
        try store.setValue(value, for: apiKey)
        DeepSeekBalance.forgetLastFetch()
        Trace.mark("deepseek: api key saved")
    }

    static func clearToken() {
        try? store.removeValue(for: apiKey)
        DeepSeekBalance.forgetLastFetch()
        Trace.mark("deepseek: api key cleared")
    }
}

/// Reads the DeepSeek account balance straight from api.deepseek.com. A missing key returns nil —
/// no card rather than an error, so the surface stays exactly what it was. Best-effort by design:
/// every caller may lose the race to a dead network and keeps whatever it already had, and a
/// throttle keeps the poll and the panel from hammering the endpoint.
enum DeepSeekBalance {
    static let providerName = "DeepSeek"
    private static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private static let throttle: TimeInterval = 120
    private nonisolated(unsafe) static var lastFetch: Date?
    /// The last reading the endpoint answered, so a throttled or failed refresh keeps the card
    /// it already had — the surface never drops a balance it has shown, only one it never had.
    private nonisolated(unsafe) static var lastReading: Reading?

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

    struct Reading: Sendable {
        var total: Double
        var toppedUp: Double
        var granted: Double
        var currency: String
        var isAvailable: Bool
    }

    static func forgetLastFetch() {
        lastFetch = nil
        lastReading = nil
    }

    @discardableResult
    static func refresh() async -> Reading? {
        guard let key = DeepSeekCredentials.token else {
            lastReading = nil
            return nil
        }
        if let last = lastFetch, Date().timeIntervalSince(last) < throttle {
            return lastReading
        }
        lastFetch = Date()
        if let reading = await fetch(key: key) {
            lastReading = reading
            return reading
        }
        Trace.mark("deepseek: balance fetch failed")
        return lastReading
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
        if gauge.fraction >= 1 { return Localized.text("Empty") }
        return money(gauge.usedUSD ?? 0, gauge.currency)
    }

    static func money(_ value: Double, _ currency: String?) -> String {
        let symbol = (currency ?? "USD").uppercased() == "CNY" ? "¥" : "$"
        return String(format: "%@%.2f", symbol, value)
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

/// The one editor for the optional DeepSeek API key. Purely additive: without a key the usage
/// surfaces stay exactly as they were, and with one the DeepSeek balance joins the meters and the
/// chooser's DeepSeek rows learn their own wall.
enum DeepSeekKeyDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        onChanged: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("DeepSeek API key"), parent: parent, width: 420)
        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "DeepSeek models reached through opencode normally ride your opencode go plan. If you bill them straight to DeepSeek instead, paste the platform's API key here and Tailscode will show the prepaid balance beside the plan quotas."),
                css: "row-detail", wrap: true, selectable: false))

        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), "sk-...")
        gtk_entry_set_visibility(ptr(entry), 0)
        gtk_editable_set_text(op(entry), DeepSeekCredentials.token ?? "")
        gtk_box_append(ptr(content), entry)

        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Stored only in the app's secret store, on this machine. Read once per refresh from api.deepseek.com — the key never touches your servers."),
                css: "row-detail", wrap: true, selectable: false))

        let entryBits = UInt(bitPattern: entry)
        let windowBits = UInt(bitPattern: window)
        let finish: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
            onChanged()
        }
        let save: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            let text = Dialogs.entryText(ptr(raw))
            if text.isEmpty {
                DeepSeekCredentials.clearToken()
            } else {
                try? DeepSeekCredentials.setToken(text)
            }
            finish()
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate", save)

        let remove = Gtk.button(Localized.text("Remove key"), css: ["destructive-action"]) {
            DeepSeekCredentials.clearToken()
            finish()
        }
        gtk_widget_set_visible(remove, DeepSeekCredentials.hasToken ? 1 : 0)

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        gtk_box_append(ptr(buttons), remove)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Save"), css: ["suggested-action"], onClick: save))
        gtk_box_append(ptr(content), buttons)
        gtk_window_present(ptr(window))
    }
}
