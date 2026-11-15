import Foundation
import TailscodeCore

/// Finds a model for plain words on this machine, so the setting needs no address and no model
/// name: every port a local model server listens on is asked what it serves, each server is told
/// apart by the document only it answers, Core's `PlainModelScout` ranks what was found, and the
/// best model is asked for one line about a fixed command before it is used. Only this machine is
/// looked at; a server elsewhere on the network is still an address the person gives.
final class PlainWordsScout: @unchecked Sendable {
    /// What the look found.
    enum Outcome: Equatable {
        /// This model wrote a fitting line, in this long.
        case ready(PlainModelScout.Model, line: String, seconds: Double)
        /// The best model is not running and its server may stop another to start it.
        case ask(PlainModelScout.Model)
        /// Model servers answered, these, but none of their models wrote a fitting line.
        case silent([String])
        /// Nothing on this machine answers like a model server.
        case none
    }

    static let lookFor: TimeInterval = 1.5
    static let trialFor: TimeInterval = 25
    static let trials = 4

    private let transport: any PlainWordsTransport
    private let host: String

    init(transport: any PlainWordsTransport = PlainWordsURLTransport(), host: String = "127.0.0.1") {
        self.transport = transport
        self.host = host
    }

    /// Looks, ranks and proves, starting nothing a server would have to stop another model for.
    func settle(refused: Set<String> = []) async -> Outcome {
        let models = await look()
        guard !models.isEmpty else { return .none }
        var refused = refused
        for _ in 0..<Self.trials {
            switch PlainModelScout.choose(models, refused: refused) {
            case .none:
                return .silent(Self.servers(models))
            case .ask(let model):
                return .ask(model)
            case .use(let model):
                if let proof = await trial(model) { return .ready(model, line: proof.line, seconds: proof.seconds) }
                refused.insert(PlainModelScout.key(model))
            }
        }
        return .silent(Self.servers(models))
    }

    /// Asks a model the person agreed to start for its line, which starts it.
    func start(_ model: PlainModelScout.Model) async -> Outcome {
        guard let proof = await trial(model) else { return .silent([model.kind.title]) }
        return .ready(model, line: proof.line, seconds: proof.seconds)
    }

    private static func servers(_ models: [PlainModelScout.Model]) -> [String] {
        var seen: [String] = []
        for model in models where !seen.contains(model.kind.title) { seen.append(model.kind.title) }
        return seen
    }

    /// Every model every local server offers, with what it is and whether it is running.
    func look() async -> [PlainModelScout.Model] {
        await withTaskGroup(of: [PlainModelScout.Model].self) { group in
            for port in PlainModelScout.ports {
                group.addTask { [self] in await server(on: port) }
            }
            var all: [PlainModelScout.Model] = []
            for await found in group { all += found }
            return all.sorted { ($0.base.port ?? 0, $0.id) < ($1.base.port ?? 0, $1.id) }
        }
    }

    private func server(on port: Int) async -> [PlainModelScout.Model] {
        guard let root = URL(string: "http://\(host):\(port)"), let base = PlainModel.endpoint(root.absoluteString + "/v1"),
            let list = await fetch(base.appendingPathComponent("models"))
        else { return [] }
        var models = PlainModelScout.models(fromList: list, kind: .other, base: base)
        guard !models.isEmpty else { return [] }
        if let running = await fetch(root.appendingPathComponent("running")).flatMap(PlainModelScout.swapRunning) {
            return models.map { model in
                var model = model
                model.kind = .llamaSwap
                if model.running == nil { model.running = running.contains(model.id) }
                return model
            }
        }
        if let loaded = await fetch(root.appendingPathComponent("api").appendingPathComponent("ps"))
            .flatMap(PlainModelScout.ollamaModels)
        {
            let sizes = await fetch(root.appendingPathComponent("api").appendingPathComponent("tags"))
                .flatMap(PlainModelScout.ollamaModels) ?? []
            let names = Set(loaded.map(\.name))
            return models.map { model in
                var model = model
                model.kind = .ollama
                model.running = names.contains(model.id)
                if model.parameters == nil { model.parameters = sizes.first { $0.name == model.id }?.parameters }
                return model
            }
        }
        if let states = await fetch(root.appendingPathComponent("api").appendingPathComponent("v0").appendingPathComponent("models"))
            .flatMap(PlainModelScout.lmStudioStates)
        {
            return models.compactMap { model in
                var model = model
                model.kind = .lmStudio
                guard states[model.id]?.embedding != true else { return nil }
                model.running = states[model.id]?.loaded ?? false
                return model
            }
        }
        let kind = PlainModelScout.kind(ofList: list) ?? .other
        let single = models.count == 1
        models = models.map { model in
            var model = model
            model.kind = kind
            if model.running == nil, single { model.running = true }
            return model
        }
        return models
    }

    /// Asks `model` for its line about the trial command and answers it with how long it took, or
    /// nil when it did not write one that reads as doing something.
    func trial(_ model: PlainModelScout.Model) async -> (line: String, seconds: Double)? {
        let url = model.base.appendingPathComponent("chat").appendingPathComponent("completions")
        let body = PlainModel.request(model: model.id, raw: PlainModelScout.trial)
        let started = Date()
        let transport = transport
        guard let data = try? await Self.bounded(Self.trialFor, { try await transport.post(url, body: body) }),
            let line = PlainModel.reply(from: data), PlainModelScout.passes(line)
        else { return nil }
        return (line, Date().timeIntervalSince(started))
    }

    private func fetch(_ url: URL) async -> Data? {
        let transport = transport
        return try? await Self.bounded(Self.lookFor) { try await transport.get(url) }
    }

    private static func bounded(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PlainWordsError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PlainWordsError.timedOut }
            return first
        }
    }
}
