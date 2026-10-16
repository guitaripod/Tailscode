import CodingAgentKit
import Foundation

/// The questions a pane asks about its preview beyond the picture. Each is a request to the host,
/// made when a person opens the lens that needs it, never on a timer: a lens nobody is looking at
/// costs nothing.
extension PreviewRunner {
    public var activeSession: String? { currentSession }

    private func requireSession() throws -> String {
        guard let id = currentSession else { throw PreviewRunnerError.sessionGone }
        return id
    }

    public func history() async throws -> [HistoryInfo] {
        try await client.history(requireSession())
    }

    public func historyPicture(_ shot: Int) async throws -> Data {
        try await client.historyPicture(requireSession(), shot)
    }

    public func diff(before: Int, after: Int?) async throws -> DiffReport {
        try await client.diff(requireSession(), a: before, b: after)
    }

    public func replay(seconds: Double = 10) async throws -> [FrameRecord] {
        try await client.replay(requireSession(), seconds: seconds)
    }

    public func startVariants(_ specs: [VariantSpec]) async throws -> String {
        try await client.startVariants(requireSession(), VariantsRequest(variants: specs))
    }

    public func variantJob(_ job: String) async throws -> VariantJob {
        try await client.variantJob(job)
    }

    public func variantPicture(_ job: String, _ index: Int) async throws -> Data {
        try await client.variantPicture(job, index)
    }

    public func inspectHello() async throws -> InspectHello {
        try Self.decodeInspection(await client.inspect(requireSession(), operation: "hello"))
    }

    public func inspectTree(maxDepth: Int = 40) async throws -> InspectTree {
        try Self.decodeInspection(
            await client.inspect(requireSession(), operation: "tree", arguments: ["maxDepth": Double(maxDepth)]))
    }

    public func inspectAudit() async throws -> InspectAudit {
        try Self.decodeInspection(await client.inspect(requireSession(), operation: "audit"))
    }

    /// Operates the app on the picture. The words for a refusal are `PreviewTouchReading.failure`.
    public func sendTouch(_ request: TouchRequest) async throws {
        try await client.touch(requireSession(), request)
    }

    public func tap(x: Double, y: Double) async throws {
        try await sendTouch(.tap(x: x, y: y))
    }

    public func swipe(from: PreviewTouchPoint, to: PreviewTouchPoint, seconds: Double) async throws {
        try await sendTouch(.swipe(x: from.x, y: from.y, toX: to.x, toY: to.y, seconds: seconds))
    }

    public func type(_ text: String) async throws {
        try await sendTouch(.text(text))
    }

    public func press(key: String) async throws {
        try await sendTouch(.key(key))
    }

    public func pressHome() async throws {
        try await sendTouch(.button("home"))
    }

    static func decodeInspection<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
