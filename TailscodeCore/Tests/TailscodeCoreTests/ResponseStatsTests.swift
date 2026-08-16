import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Response stats")
struct ResponseStatsTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func turn(
        usage: MessageUsage? = MessageUsage(input: 400, output: 900, cacheRead: 20_000),
        seconds: TimeInterval? = 30, duration: TimeInterval? = nil, cost: Double? = 0.12,
        model: String? = "claude-opus-5", effort: String? = "high", streaming: Bool = false,
        error: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text("here you go"))], createdAt: start,
            completedAt: seconds.map { start.addingTimeInterval($0) }, isStreaming: streaming,
            error: error, costUSD: cost, modelID: model, reasoningEffort: effort,
            totalTokens: usage?.total, usage: usage, duration: duration)
    }

    private func prompt(at offset: TimeInterval = 0) -> ChatMessage {
        ChatMessage(
            id: "u1", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text("do the thing"))],
            createdAt: start.addingTimeInterval(offset))
    }

    private func value(_ stats: ResponseStats?, _ kind: ResponseStat.Kind) -> String? {
        stats?.facts.first { $0.kind == kind }?.value
    }

    @Test("The rate counts what the model wrote, never what it was handed")
    func rateIgnoresCacheReads() {
        let stats = ResponseStats(turn: turn(), promptedAt: start)
        #expect(value(stats, .speed) == "30 tok/s")
        #expect(value(stats, .written) == "900")
        #expect(value(stats, .read) == "20.4k")
    }

    @Test("Thinking counts as written and is named in the detail")
    func reasoningIsWritten() {
        let usage = MessageUsage(input: 100, output: 200, reasoning: 800)
        let stats = ResponseStats(turn: turn(usage: usage), promptedAt: start)
        #expect(value(stats, .written) == "1.0k")
        let detail = stats?.facts.first { $0.kind == .written }?.detail ?? ""
        #expect(detail.contains("thinking"))
    }

    @Test("The server's own duration outranks the stamps")
    func serverDurationWins() {
        let stats = ResponseStats(turn: turn(seconds: nil, duration: 45), promptedAt: start)
        #expect(value(stats, .elapsed) == "45s")
        #expect(value(stats, .speed) == "20 tok/s")
    }

    @Test("The wait starts when the prompt went out, not when the answer began")
    func elapsedStartsAtThePrompt() {
        let late = ChatMessage(
            id: "a1", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "text", kind: .text("x"))],
            createdAt: start.addingTimeInterval(20),
            completedAt: start.addingTimeInterval(30),
            usage: MessageUsage(output: 100))
        let stats = ResponseStats(turn: late, promptedAt: start)
        #expect(value(stats, .elapsed) == "30s")
    }

    @Test("A turn the server said nothing about shows nothing")
    func silentTurnHasNoStrip() {
        let bare = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text("x"))], createdAt: start)
        #expect(ResponseStats(turn: bare) == nil)
    }

    @Test("A turn with a clock but no tokens shows the clock and no rate")
    func clockWithoutTokens() {
        let stats = ResponseStats(turn: turn(usage: nil, cost: nil, model: nil), promptedAt: start)
        #expect(value(stats, .elapsed) == "30s")
        #expect(value(stats, .speed) == nil)
    }

    @Test("Nothing is claimed about a turn still being written, or one that failed")
    func unsettledTurnsAreSilent() {
        #expect(ResponseStats(turn: turn(seconds: nil, streaming: true)) == nil)
        #expect(ResponseStats(turn: turn(error: "the provider refused")) == nil)
    }

    @Test("A rate needs enough clock under it to mean anything")
    func rateFloor() {
        let quick = ResponseStats(turn: turn(seconds: 0.2), promptedAt: start)
        #expect(value(quick, .speed) == nil)
        #expect(value(quick, .elapsed) == "0.2s")
    }

    @Test("Money is always marked an estimate")
    func moneyIsEstimated() {
        let stats = ResponseStats(turn: turn(), promptedAt: start)
        #expect(value(stats, .cost) == "~$0.12")
        #expect(stats?.estimatedCost == true)
    }

    @Test("Reading a transcript pairs an answer with the question above it")
    func readsFromTranscript() {
        let messages = [prompt(), turn()]
        #expect(value(ResponseStats.read(messages, at: 1), .elapsed) == "30s")
        #expect(value(ResponseStats.read(messages, id: "a1"), .elapsed) == "30s")
        #expect(ResponseStats.read(messages, at: 0) == nil)
    }

    @Test("A turn's clock keeps the second it took")
    func clockPrecision() {
        #expect(ResponseStats.clock(1.44) == "1.4s")
        #expect(ResponseStats.clock(11.6) == "12s")
        #expect(ResponseStats.clock(95) == "1m 35s")
        #expect(ResponseStats.clock(3600) == "1h")
    }
}

@Suite("Model abilities")
struct ModelAbilitiesTests {
    private let seeing = ModelInfo(
        id: "opus", name: "Opus", providerID: "anthropic",
        capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: true),
        variants: ["low", "high"])
    private let blind = ModelInfo(
        id: "qwen3:14b", name: "Qwen3 14B", providerID: "ollama",
        capabilities: ModelCapabilities(attachment: true, imageInput: false, pdfInput: false),
        variants: [])
    private let undescribed = ModelInfo(id: "mystery", name: "Mystery", providerID: "ollama")

    @Test("A model that cannot see is offered no picture")
    func blindModel() {
        let abilities = ModelAbilities.resolve(
            supportsAttachments: true, models: [seeing, blind],
            selection: blind.selection, camera: true)
        #expect(abilities.attachments)
        #expect(!abilities.vision)
        #expect(!abilities.camera)
        #expect(!abilities.accepts(mime: "image/png"))
        #expect(abilities.accepts(mime: "text/plain"))
    }

    @Test("A model the catalog cannot describe is trusted, not assumed blind")
    func undescribedModel() {
        let abilities = ModelAbilities.resolve(
            supportsAttachments: true, models: [undescribed], selection: undescribed.selection)
        #expect(abilities.vision)
    }

    @Test("A pick with no door still finds its model")
    func matchesOnIDAlone() {
        let abilities = ModelAbilities.resolve(
            supportsAttachments: true, models: [seeing, blind],
            selection: ModelSelection(providerID: "server", modelID: "qwen3:14b"))
        #expect(!abilities.vision)
    }

    @Test("A server that takes nothing offers nothing, and says which it was")
    func serverWithoutAttachments() {
        let abilities = ModelAbilities.resolve(
            supportsAttachments: false, models: [seeing], selection: seeing.selection)
        #expect(!abilities.attachments)
        #expect(
            abilities.unavailableReason(supportsAttachments: false)
                == "This server does not take attachments")
        let narrowed = ModelAbilities.resolve(
            supportsAttachments: true,
            model: ModelCapabilities(attachment: false, imageInput: false, pdfInput: false))
        #expect(
            narrowed.unavailableReason(supportsAttachments: true)
                == "This model takes no attachments")
    }
}

@Suite("Model effort")
struct ModelEffortTests {
    private let levelled = ModelInfo(
        id: "opus", name: "Opus", providerID: "anthropic", variants: ["low", "high"])
    private let flat = ModelInfo(
        id: "qwen3:14b", name: "Qwen3 14B", providerID: "ollama", variants: [])
    private let silent = ModelInfo(id: "mystery", name: "Mystery", providerID: "ollama")

    @Test("A model with no levels has no control at all")
    func noControlWithoutLevels() {
        let options = ModelEffort.options(
            models: [levelled, flat], selection: flat.selection, agentOptions: [])
        #expect(options.isEmpty)
        #expect(!ModelEffort.isOffered(options: options))
        #expect(ModelEffort.label(nil, options: options) == nil)
        #expect(ModelEffort.label("high", options: options) == nil)
    }

    @Test("A catalog that names no variants leaves it to the agent")
    func fallsBackToTheAgent() {
        let options = ModelEffort.options(
            models: [silent], modelID: "mystery", agentOptions: ["low", "max"])
        #expect(options == ["low", "max"])
    }

    @Test("A catalog that says the model has none is believed")
    func emptyVariantsAreAnAnswer() {
        #expect(
            ModelEffort.options(models: [flat], modelID: "qwen3:14b", agentOptions: ["low"])
                .isEmpty)
    }

    @Test("The model's own levels outrank the agent's")
    func modelWins() {
        let options = ModelEffort.options(
            models: [levelled], selection: levelled.selection,
            agentOptions: ["low", "medium", "high", "max"])
        #expect(options == ["low", "high"])
        #expect(ModelEffort.label(nil, options: options) == "server effort")
    }

    @Test("A level the new model cannot run is handed back to the machine")
    func levelSurvivesOnlyWhereItCanRun() {
        #expect(ModelEffort.surviving("max", options: ["low", "high"]) == nil)
        #expect(ModelEffort.surviving("high", options: ["low", "high"]) == "high")
    }
}
