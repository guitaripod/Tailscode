import CodingAgentKit
import Foundation

/// Uploads the APNs device token to every connected claude-code bridge so the
/// server can push turn-completion alerts and silent usage refreshes. Older
/// bridges without the route 404; each upload is fire-and-forget.
@MainActor
enum PushRegistrar {
    private static let tokenKey = "tailscode.apnsToken"

    private(set) static var ackedBridgeURLs: Set<URL> = []

    static func register(tokenHex: String) {
        if UserDefaults.standard.string(forKey: tokenKey) != tokenHex {
            ackedBridgeURLs.removeAll()
        }
        UserDefaults.standard.set(tokenHex, forKey: tokenKey)
        upload(tokenHex)
    }

    static func reregisterIfNeeded() {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        upload(token)
    }

    static func unregister(from backend: any CodingAgentBackend, baseURL: URL, name: String) {
        ackedBridgeURLs.remove(baseURL)
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        let registration = DevicePushRegistration(token: token, environment: environment)
        Task {
            if (try? await backend.unregisterDeviceToken(registration)) != nil {
                AppLogger.connection.info("push: device token unregistered from \(name)")
            }
        }
    }

    private static var environment: String {
        #if DEBUG
            "development"
        #else
            "production"
        #endif
    }

    private static func upload(_ token: String) {
        let registration = DevicePushRegistration(token: token, environment: environment)
        var seen = Set<URL>()
        let bridges = ConnectionController.shared.allBackends().filter { entry in
            entry.profile.backend == .claudeCode
                && !entry.profile.id.hasPrefix(DemoWorld.profilePrefix)
                && !ackedBridgeURLs.contains(entry.profile.baseURL)
                && seen.insert(entry.profile.baseURL).inserted
        }
        guard !bridges.isEmpty else { return }
        AppLogger.connection.info("push: uploading device token to \(bridges.count) bridge(s)")
        for entry in bridges {
            let backend = entry.backend
            let name = entry.profile.name
            let baseURL = entry.profile.baseURL
            Task {
                if (try? await backend.registerDeviceToken(registration)) != nil {
                    ackedBridgeURLs.insert(baseURL)
                    AppLogger.connection.info("push: device token registered with \(name)")
                }
            }
        }
    }
}
