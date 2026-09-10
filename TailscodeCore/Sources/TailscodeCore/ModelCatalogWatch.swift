import CodingAgentKit
import Foundation

/// One answer about a server's model catalog: the best list known, and whether the server itself
/// answered the ask that produced it. `reachable == nil` means the ask is still out and the list is
/// what the store remembers; `false` means the server refused and the list is the last one known,
/// possibly empty; `true` is the server's own answer.
public struct ModelCatalogReading: Sendable, Equatable {
    public let models: [ModelInfo]
    public let reachable: Bool?

    public init(models: [ModelInfo], reachable: Bool?) {
        self.models = models
        self.reachable = reachable
    }
}

/// A live ask for one server's catalog, owned here so no client runs a poll of its own.
///
/// Subscribing paints immediately from what the store remembers — a machine's models are a fact
/// about the machine, nameable while it is down — and then retries the ask with a backoff until the
/// server answers. A chooser opened across a restart therefore first says the server is not
/// answering, and lists the models the moment it is back, without the client owning the loop.
public enum ModelCatalogWatch {
    private static let basePause = Duration.seconds(1)
    private static let maxPause = Duration.seconds(30)

    public static func readings(
        profileID: String, backend: any CodingAgentBackend
    ) -> AsyncStream<ModelCatalogReading> {
        AsyncStream { continuation in
            let task = Task {
                let remembered = ModelCatalogStore.cached(profileID)
                continuation.yield(ModelCatalogReading(models: remembered, reachable: nil))
                var pause = basePause
                while !Task.isCancelled {
                    do {
                        let asked = try await backend.availableModels()
                        if !asked.isEmpty { ModelCatalogStore.store(asked, for: profileID) }
                        continuation.yield(ModelCatalogReading(models: asked, reachable: true))
                        break
                    } catch {
                        continuation.yield(
                            ModelCatalogReading(models: remembered, reachable: false))
                        try? await Task.sleep(for: pause)
                        pause = min(pause * 2, maxPause)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One ask outside the retry loop — for a reader who already has a list and wants to know
    /// whether the server has more to say, not a watch that gives up the moment it hears anything.
    /// `readings(profileID:backend:)` above stops re-asking after its first success, so a model
    /// added to a server that was already answering never reaches a session that opened before it:
    /// this is the other half, fired from a press rather than a restart.
    public static func refreshOnce(
        profileID: String, backend: any CodingAgentBackend
    ) async -> ModelCatalogReading {
        do {
            let asked = try await backend.availableModels()
            if !asked.isEmpty { ModelCatalogStore.store(asked, for: profileID) }
            return ModelCatalogReading(models: asked, reachable: true)
        } catch {
            return ModelCatalogReading(models: ModelCatalogStore.cached(profileID), reachable: false)
        }
    }
}
