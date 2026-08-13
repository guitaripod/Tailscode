import CodingAgentKitApple
import Foundation

/// A DeepSeek model reached through a direct API key is metered by that key's prepaid balance,
/// not by any plan's windows. The key is optional, lives in the Keychain (app group, so the
/// widget can read it), and this refreshes the balance into the shared usage snapshot the Home
/// cards, the Usage screen and the widget all read from.
enum DeepSeekCredentials {
    private static let apiKey = "deepseek.apiKey"

    private static func keychain() -> KeychainSecretStore {
        #if targetEnvironment(simulator)
            KeychainSecretStore()
        #else
            KeychainSecretStore(accessGroup: SharedConnectionStore.appGroup)
        #endif
    }

    static var token: String? {
        let stored = (try? keychain().value(for: apiKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    static func setToken(_ value: String) throws {
        try keychain().setValue(value, for: apiKey)
        UserDefaults(suiteName: UsageWidgetStore.suiteName)?.removeObject(forKey: "deepseek.lastFetch")
        AppLogger.session.info("deepseek: api key saved")
    }

    static func clearToken() {
        try? keychain().removeValue(for: apiKey)
        UserDefaults(suiteName: UsageWidgetStore.suiteName)?.removeObject(forKey: "deepseek.lastFetch")
        AppLogger.session.info("deepseek: api key cleared")
    }
}

/// Reads the DeepSeek account balance straight from api.deepseek.com and writes it as one
/// provider snapshot in the shared usage store. A balance is not a quota: it carries no cap
/// and no reset, so the snapshot's single gauge is the money itself — `usedUSD` with no
/// `limitUSD` is how the renderers recognise a balance row and skip the bar.
enum DeepSeekBalance {
    static let providerName = "DeepSeek"
    private static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

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

    /// Fetches the balance and writes the snapshot; a missing key removes the provider rather
    /// than pretending a stale card is current. Best-effort by design: every caller (Home, the
    /// Usage screen, background refresh, the widget) may lose the race to a dead network and
    /// must keep whatever it already had.
    private static let lastFetchKey = "deepseek.lastFetch"
    private static let throttle: TimeInterval = 120

    @discardableResult
    static func refresh() async -> Reading? {
        guard let key = DeepSeekCredentials.token else {
            UsageWidgetStore.removeProvider(named: providerName)
            return nil
        }
        let defaults = UserDefaults(suiteName: UsageWidgetStore.suiteName)
        if let last = defaults?.double(forKey: lastFetchKey),
            Date().timeIntervalSince1970 - last < throttle
        {
            return nil
        }
        let reading = await fetch(key: key)
        if reading == nil {
            AppLogger.session.info("deepseek: balance fetch failed; keeping stored snapshot")
        }
        if let defaults {
            defaults.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
        }
        guard let reading else { return nil }
        UsageWidgetStore.upsertProvider(snapshot(for: reading))
        AppLogger.session.info(
            "deepseek: balance \(currency(reading.total, reading.currency)) "
                + "(topped up \(currency(reading.toppedUp, reading.currency)), "
                + "granted \(currency(reading.granted, reading.currency)))")
        return reading
    }

    static func snapshot(for reading: Reading) -> UsageWidgetEntry.ProviderSnapshot {
        let value = reading.isAvailable
            ? currency(reading.total, reading.currency) : String(localized: "Empty")
        let caption: String
        if reading.isAvailable {
            var parts = [String(localized: "Topped up \(currency(reading.toppedUp, reading.currency))")]
            if reading.granted > 0 {
                parts.append(String(localized: "granted \(currency(reading.granted, reading.currency))"))
            }
            caption = parts.joined(separator: " · ")
        } else {
            caption = String(localized: "Balance is empty — top up to keep DeepSeek models running")
        }
        return UsageWidgetEntry.ProviderSnapshot(
            providerName: providerName,
            subtitle: String(localized: "Prepaid balance · direct API"),
            isLive: true,
            gauges: [
                UsageWidgetEntry.GaugeSnapshot(
                    label: String(localized: "Balance"),
                    fraction: reading.isAvailable ? 0 : 1,
                    percentText: value,
                    caption: caption,
                    resetsAt: nil,
                    usedUSD: reading.total,
                    limitUSD: nil,
                    currency: reading.currency)
            ])
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

    static func currency(_ value: Double, _ currency: String) -> String {
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"
        return String(format: "\(symbol)%.2f", value)
    }
}
