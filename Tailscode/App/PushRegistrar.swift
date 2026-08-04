import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Uploads the APNs device token to every connected claude-code bridge so the
/// server can push turn-completion alerts and silent usage refreshes. Older
/// bridges without the route 404; each upload is fire-and-forget.
@MainActor
enum PushRegistrar {
    private static let tokenKey = "tailscode.apnsToken"

    /// What the last upload attempt to a bridge established, so Settings can
    /// answer "why am I not getting pushes from this server" without the user
    /// reading the log.
    enum State: Equatable {
        case unknown
        case registered
        case unsupported
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .registered: return "Registered"
            case .unsupported: return "Bridge too old"
            case .failed: return "Failed"
            }
        }
    }

    private(set) static var states: [URL: State] = [:]

    static var ackedBridgeURLs: Set<URL> {
        Set(states.filter { $0.value == .registered }.keys)
    }

    static func state(for baseURL: URL) -> State { states[baseURL] ?? .unknown }

    static var hasToken: Bool { UserDefaults.standard.string(forKey: tokenKey) != nil }

    static func register(tokenHex: String) {
        if UserDefaults.standard.string(forKey: tokenKey) != tokenHex {
            states.removeAll()
        }
        UserDefaults.standard.set(tokenHex, forKey: tokenKey)
        upload(tokenHex)
    }

    static func reregisterIfNeeded() {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        upload(token)
    }

    /// Applies the server-push preference: on, every bridge gets the token back;
    /// off, every bridge is told to forget it, which is the only thing that
    /// actually stops the pushes arriving.
    static func applyPreference() {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        if AppPreferences.pushAlertsEnabled {
            upload(token)
        } else {
            unregisterAll(token: token)
        }
    }

    static func unregister(from backend: any CodingAgentBackend, baseURL: URL, name: String) {
        states.removeValue(forKey: baseURL)
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        let registration = DevicePushRegistration(token: token, environment: environment)
        Task {
            if (try? await backend.unregisterDeviceToken(registration)) != nil {
                AppLogger.connection.info("push: device token unregistered from \(name)")
            }
        }
    }

    private static func unregisterAll(token: String) {
        let registration = DevicePushRegistration(token: token, environment: environment)
        for entry in bridges(skippingAcked: false) {
            let backend = entry.backend
            let name = entry.profile.name
            let baseURL = entry.profile.baseURL
            states.removeValue(forKey: baseURL)
            Task {
                if (try? await backend.unregisterDeviceToken(registration)) != nil {
                    AppLogger.connection.info("push: device token unregistered from \(name)")
                }
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

    private static func bridges(skippingAcked: Bool)
        -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)]
    {
        var seen = Set<URL>()
        return ConnectionController.shared.allBackends().filter { entry in
            entry.profile.backend == .claudeCode
                && !entry.profile.id.hasPrefix(DemoWorld.profilePrefix)
                && !(skippingAcked && ackedBridgeURLs.contains(entry.profile.baseURL))
                && seen.insert(entry.profile.baseURL).inserted
        }
    }

    private static func upload(_ token: String) {
        guard AppPreferences.pushAlertsEnabled else { return }
        let registration = DevicePushRegistration(token: token, environment: environment)
        let bridges = bridges(skippingAcked: true)
        guard !bridges.isEmpty else { return }
        AppLogger.connection.info("push: uploading device token to \(bridges.count) bridge(s)")
        for entry in bridges {
            let backend = entry.backend
            let name = entry.profile.name
            let baseURL = entry.profile.baseURL
            Task {
                do {
                    try await backend.registerDeviceToken(registration)
                    states[baseURL] = .registered
                    AppLogger.connection.info("push: device token registered with \(name)")
                } catch {
                    states[baseURL] = Self.classify(error)
                    AppLogger.connection.error(
                        "push: registration with \(name) failed: \(error.localizedDescription)")
                }
                NotificationCenter.default.post(name: didChangeStates, object: nil)
            }
        }
    }

    /// A bridge that predates the push routes answers 404, which is a
    /// deployment fact the user can fix, not a transient error.
    private static func classify(_ error: Error) -> State {
        if case AgentError.http(let status, _) = error, status == 404 { return .unsupported }
        return .failed(SessionListViewModel.readable(error))
    }

    static let didChangeStates = Notification.Name("PushRegistrar.didChangeStates")
}
