import CodingAgentKit
import Foundation

/// Images and video are proven by the client, not by a daemon: this source runs `MediaDoctor` against
/// the renderer a target names and serves its `SetupReport` to the desk exactly as the voice
/// gateway's `/setup` is served, so the checklist, the server screen's row and the poller are the
/// same machinery for both.
///
/// The doctor's look at a machine is ten small requests, so the desk's poll is answered from
/// `MediaReadiness` whenever a look younger than `freshness` is held: the video board, the picture
/// studios and a visible checklist share one look rather than each taking their own. A machine that is
/// up but has no ComfyUI answering, and that this device has never used as a renderer, is `absent`,
/// which the server screen reads as the single quiet invitation instead of a red state; one that
/// cannot be spoken to at all is `unreachable`, which the server screen does not draw.
public struct MediaSetupSource: SetupSource {
    public let capability = SetupCapability.media

    public static let freshness: TimeInterval = 6

    private let readiness: MediaReadiness
    private let used: @Sendable (ForgeEndpoint) -> Bool
    private let now: @Sendable () -> Date

    public init(
        readiness: MediaReadiness = .shared,
        used: @escaping @Sendable (ForgeEndpoint) -> Bool = MediaSetupSource.hasUsed,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readiness = readiness
        self.used = used
        self.now = now
    }

    public static func hasUsed(_ endpoint: ForgeEndpoint) -> Bool {
        ForgeStore.endpoint() == endpoint || ForgeStore.renderers().contains { $0.endpoint == endpoint }
    }

    public func report(for target: SetupTarget) async -> SetupSourceAnswer {
        guard let endpoint = target.forgeEndpoint else {
            return .unreachable(Localized.text("nothing here can check this"))
        }
        let verdict = await look(at: endpoint)
        if verdict.isAnswering || verdict.isStarting || used(endpoint) { return .report(verdict.report) }
        switch verdict.comfy {
        case .timedOut:
            return .unreachable(ForgeEndpoint.sentence(for: .timedOut, host: endpoint.host))
        case .unresolved:
            return .unreachable(ForgeEndpoint.sentence(for: .nameNotResolved, host: endpoint.host))
        case .answering, .starting, .refused, .loopbackOnly, .notComfy:
            return .absent(verdict.report)
        }
    }

    public func start(fix: String, for target: SetupTarget) async throws -> SetupJob {
        throw SetupSourceError.refused(Localized.text("nothing here can do this"))
    }

    public func job(id: String, for target: SetupTarget) async throws -> SetupJob {
        throw SetupSourceError.gone
    }

    public func cancel(job id: String, for target: SetupTarget) async throws {}

    private func look(at endpoint: ForgeEndpoint) async -> MediaVerdict {
        if let held = await readiness.cached(for: endpoint), now().timeIntervalSince(held.at) < Self.freshness {
            return held
        }
        return await readiness.verdict(for: endpoint, force: true)
    }
}
