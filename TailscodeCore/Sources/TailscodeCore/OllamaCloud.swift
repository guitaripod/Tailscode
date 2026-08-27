import CodingAgentKit
import Foundation
import Synchronization
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An Ollama Cloud account is metered by two rolling windows — a session (about five hours) and
/// a week — each reported as a fraction of the plan's cap, plus the plan's cost over the last
/// four weeks. The reading comes from `https://ollama.com/api/usage` with the account's own API
/// key (Bearer), the endpoint the ollama.com settings page renders. The endpoint is
/// undocumented: it works today and community tools depend on it, but it can change or become
/// gated without notice, so every failure reads as absence rather than error — a surface that
/// never had Ollama numbers keeps looking like it never had them.
public enum OllamaCloud {
    public static let providerName = "Ollama Cloud"
    static let endpoint = URL(string: "https://ollama.com/api/usage")!

    /// One metered window. The endpoint reports a used fraction only — no token counts, no
    /// dollar ceiling — so the gauge carries a fraction and nothing else.
    public struct Bucket: Sendable, Equatable {
        public var key: String
        public var label: String
        public var usage: Double

        public init(key: String, label: String, usage: Double) {
            self.key = key
            self.label = label
            self.usage = usage
        }
    }

    public struct Reading: Sendable, Equatable {
        public var session: Bucket
        public var weekly: Bucket
        /// The plan's cost over its own reporting period, as the endpoint writes it ("12.34").
        public var cost: String

        public init(session: Bucket, weekly: Bucket, cost: String) {
            self.session = session
            self.weekly = weekly
            self.cost = cost
        }
    }

    private static let state = Mutex<(lastFetch: Date?, lastReading: Reading?)>((nil, nil))

    public static func forgetLastFetch() {
        state.withLock { $0 = (nil, nil) }
    }

    /// The last reading the endpoint answered, so a throttled or failed refresh keeps whatever
    /// the surfaces already drew — a card that once showed numbers never goes blank because one
    /// poll lost the race to a dead network.
    public static var cached: Reading? {
        state.withLock(\.lastReading)
    }

    /// Fetches and remembers. No key returns nil — no card rather than an error. The throttle
    /// keeps the poll and the surfaces' separate asks from hammering the endpoint; a caller that
    /// lands inside the window receives the cached reading.
    @discardableResult
    public static func refresh(key: String?) async -> Reading? {
        guard let key, !key.isEmpty else {
            forgetLastFetch()
            return nil
        }
        if state.withLock({ current in
            if let last = current.lastFetch, Date().timeIntervalSince(last) < throttle {
                return true
            }
            current.lastFetch = Date()
            return false
        }) {
            return cached
        }
        guard let reading = await fetch(key: key) else { return cached }
        state.withLock { $0.lastReading = reading }
        return reading
    }


    /// The account's windows as one provider quota. Both windows are account-wide — a session
    /// wall stops every cloud model, not one — and the plan's reported cost rides as a detail, a
    /// fact about the account rather than a window with a reset. No reset time is stated or
    /// invented: the endpoint gives none, and the renderers show no countdown for it.
    public static func snapshot(for reading: Reading) -> UsageQuota {
        let gauges = [reading.session, reading.weekly].map { bucket in
            UsageQuota.Gauge(
                key: bucket.key,
                label: bucket.label,
                fraction: bucket.usage,
                resetsAt: nil,
                trustedReset: false)
        }
        let details = reading.cost.isEmpty
            ? []
            : [UsageQuota.Detail(key: Localized.text("Plan cost"), value: "$\(reading.cost)")]
        return UsageQuota(
            providerName: providerName,
            subtitle: Localized.text("Cloud plan · session and weekly windows"),
            source: "ollama.com/api/usage",
            live: true,
            gauges: gauges,
            details: details)
    }

    private static let throttle: TimeInterval = 120

    private static func fetch(key: String) async -> Reading? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> Reading {
        struct Shape: Decodable {
            struct Activity: Decodable {
                var cost: String?
            }
            struct Limits: Decodable {
                struct Bucket: Decodable {
                    var usage: Double?
                }
                var session: Bucket?
                var weekly: Bucket?
            }
            var activity: Activity?
            var limits: Limits?
        }
        let shape = try JSONDecoder().decode(Shape.self, from: data)
        return Reading(
            session: Bucket(
                key: "session", label: Localized.text("Session"),
                usage: shape.limits?.session?.usage ?? 0),
            weekly: Bucket(
                key: "weekly", label: Localized.text("Weekly"),
                usage: shape.limits?.weekly?.usage ?? 0),
            cost: shape.activity?.cost ?? "")
    }
}