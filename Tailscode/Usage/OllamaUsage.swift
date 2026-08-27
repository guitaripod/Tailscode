import CodingAgentKitApple
import Foundation
import TailscodeCore

/// An Ollama Cloud account's API key, optional and held in the Keychain (app group, so the
/// widget can read it). With a key the account's session and weekly windows join the usage
/// surfaces; without one nothing changes.
enum OllamaCredentials {
    private static let apiKey = "ollamaCloud.apiKey"

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
        OllamaCloud.forgetLastFetch()
        UserDefaults(suiteName: UsageWidgetStore.suiteName)?.removeObject(forKey: "ollamaCloud.lastFetch")
        AppLogger.session.info("ollama-cloud: api key saved")
    }

    static func clearToken() {
        try? keychain().removeValue(for: apiKey)
        OllamaCloud.forgetLastFetch()
        UserDefaults(suiteName: UsageWidgetStore.suiteName)?.removeObject(forKey: "ollamaCloud.lastFetch")
        AppLogger.session.info("ollama-cloud: api key cleared")
    }
}

/// Reads the Ollama Cloud account's windows and writes them as one provider snapshot in the
/// shared usage store, the way the DeepSeek balance arrives — this device's own credential,
/// fetched straight from ollama.com, folded in beside the plans.
enum OllamaUsage {
    static func refresh() async -> OllamaCloud.Reading? {
        guard OllamaCredentials.hasToken else {
            UsageWidgetStore.removeProvider(named: OllamaCloud.providerName)
            return nil
        }
        guard let reading = await OllamaCloud.refresh(key: OllamaCredentials.token) else { return nil }
        UsageWidgetStore.upsertProvider(snapshot(for: reading))
        return reading
    }

    static func snapshot(for reading: OllamaCloud.Reading) -> UsageWidgetEntry.ProviderSnapshot {
        let quota = OllamaCloud.snapshot(for: reading)
        return UsageWidgetEntry.ProviderSnapshot(
            providerName: quota.providerName,
            subtitle: quota.subtitle,
            isLive: true,
            gauges: quota.gauges.map { gauge in
                let percent = Int((min(max(gauge.fraction, 0), 1) * 100).rounded())
                return UsageWidgetEntry.GaugeSnapshot(
                    label: gauge.label,
                    fraction: gauge.fraction,
                    percentText: "\(percent)%",
                    caption: "",
                    resetsAt: nil,
                    usedUSD: nil,
                    limitUSD: nil,
                    currency: nil)
            })
    }
}