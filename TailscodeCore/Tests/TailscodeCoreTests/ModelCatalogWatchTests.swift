import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Model catalog watch")
struct ModelCatalogWatchTests {
    private static let catalog = [
        ModelInfo(id: "qwen3.8-27b", name: "Qwen3.8-27B", providerID: "ollama"),
        ModelInfo(id: "nemotron", name: "Nemotron", providerID: "ollama"),
    ]

    private func collect(
        profileID: String, backend: any CodingAgentBackend, until: @Sendable (ModelCatalogReading) -> Bool
    ) async -> [ModelCatalogReading] {
        var seen: [ModelCatalogReading] = []
        for await reading in ModelCatalogWatch.readings(profileID: profileID, backend: backend) {
            seen.append(reading)
            if until(reading) { break }
        }
        return seen
    }

    @Test("A live ask yields the remembered list first, then the server's answer")
    func freshAnswer() async {
        let backend = MockBackend(models: Self.catalog)
        let readings = await collect(profileID: "w-fresh", backend: backend) { $0.reachable == true }
        #expect(readings.count == 2)
        #expect(readings[0].models.isEmpty)
        #expect(readings[0].reachable == nil)
        #expect(readings[1].models.map(\.id) == Self.catalog.map(\.id))
        #expect(readings[1].reachable == true)
        #expect(ModelCatalogStore.cached("w-fresh").map(\.id) == Self.catalog.map(\.id))
    }

    @Test("A server that refuses is retried, and the answer lands when it comes back")
    func retriesUntilReachable() async {
        let backend = MockBackend(models: Self.catalog, modelsFailures: 2)
        let readings = await collect(profileID: "w-retry", backend: backend) { $0.reachable == true }
        #expect(readings.count >= 2)
        #expect(readings.contains { $0.reachable == false })
        #expect(readings.last?.reachable == true)
        #expect(readings.last?.models.map(\.id) == Self.catalog.map(\.id))
        #expect(ModelCatalogStore.cached("w-retry").count == 2)
    }

    @Test("A watched answer lands in the store, so a later reader paints it from memory")
    func answerIsRemembered() async throws {
        let backend = MockBackend(models: Self.catalog)
        let readings = await collect(profileID: "w-remembered", backend: backend) { $0.reachable == true }
        #expect(readings.last?.reachable == true)
        let remembered = ModelCatalogStore.cached("w-remembered")
        #expect(remembered.map(\.id) == Self.catalog.map(\.id))
    }

    @Test("A refusal with a remembered list keeps the list and says so")
    func refusalKeepsMemory() async throws {
        ModelCatalogStore.store(Self.catalog, for: "w-refusal")
        let backend = MockBackend(models: [], modelsFailures: 1)
        let readings = await collect(profileID: "w-refusal", backend: backend) { $0.reachable == false }
        #expect(readings.count == 2)
        #expect(readings[0].models.count == 2)
        #expect(readings[0].reachable == nil)
        #expect(readings[1].reachable == false)
        #expect(readings[1].models.map(\.id) == Self.catalog.map(\.id))
    }
}
