import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum GistFixtures {
    typealias NF = NeuralTurnFixtures

    /// Five rounds of a note and three commands: twenty steps, the third round's first command
    /// failing and its second passing.
    static func messages(rounds: Int = 5, answer: Bool = true, secret: Bool = false) -> [ChatMessage] {
        var out: [ChatMessage] = [NF.user(0, "ship the film")]
        for round in 0..<rounds {
            let note = secret && round == 0 ? "Round 0 with API_TOKEN=abcd1234 in hand." : "Round \(round) of the work is under way."
            out.append(NF.message(round * 2 + 1, [.text(note)], model: "fable"))
            let first = round == 2 ? NF.bash("make all", out: ["error: no rule"], status: .error) : NF.bash("ls \(round)", out: ["a"])
            let second = round == 2 ? NF.bash("make all", out: ["built"]) : NF.bash("pwd \(round)", out: ["/x"])
            out.append(NF.message(round * 2 + 2, [first, second, NF.edit("src/File\(round).swift", added: 4, removed: 1)], model: "fable"))
        }
        if answer { out.append(NF.message(rounds * 2 + 1, [.text("All shipped.")], model: "fable")) }
        return out
    }

    static func model(rounds: Int = 5, running: Bool = false, secret: Bool = false) -> NeuralBrainModel {
        BrainFixtures.model(
            NeuralTurns.partition(messages: messages(rounds: rounds, answer: !running, secret: secret), running: running)[0])
    }

    static func ask(_ model: NeuralBrainModel, told: NeuralGist? = nil, answer: String? = nil) -> NeuralGistAsk? {
        NeuralGistAsk.make(
            account: model.account(answer: answer), stepCount: model.steps.count,
            running: model.turn.outcome == .running, prompt: "ship the film", answer: answer, told: told,
            language: "English")
    }

    static func completion(_ content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static let written =
        #"{"title": "Shipping the film.", "now": "Everything shipped.", "stages": [{"says": "The agent looked around", "to": 6}, {"says": "built the project", "to": 13}, {"says": "Shipped it", "to": 19}]}"#

    static let helper = ImageGenHelper(address: "http://127.0.0.1:8081", model: "pennyroyal", label: "Pennyroyal")
}

final class GistTransport: NeuralGistTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    var answer = GistFixtures.completion(GistFixtures.written)
    var fails = false

    var asked: [String] {
        lock.withLock {
            bodies.compactMap { data in
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let messages = object?["messages"] as? [[String: Any]]
                return messages?.last?["content"] as? String
            }
        }
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        lock.withLock { bodies.append(body) }
        if fails { throw URLError(.cannotConnectToHost) }
        return answer
    }
}

final class GistClock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = Date(timeIntervalSince1970: 2_000_000)
    var now: Date { lock.withLock { held } }
    func advance(_ seconds: TimeInterval) { lock.withLock { held = held.addingTimeInterval(seconds) } }
}

@Suite("Megatron in short")
struct NeuralGistTests {
    typealias G = GistFixtures

    private func eventually(_ what: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if what() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return what()
    }

    private func desk(_ transport: GistTransport, _ clock: GistClock, ready: Bool = true, on: Bool = true) -> NeuralGistDesk {
        NeuralGistDesk(
            transport: transport, clock: { clock.now }, helper: { G.helper }, isOn: { on },
            isReady: { _ in ready })
    }

    @Test func aShortTurnIsNotTold() {
        #expect(!NeuralGistPolicy.worthTelling(stepCount: 9))
        #expect(NeuralGistPolicy.worthTelling(stepCount: 10))
        #expect(G.ask(G.model(rounds: 2)) == nil)
    }

    @Test func stagesAskedForGrowWithTheTurn() {
        #expect(NeuralGistPolicy.stageBounds(stepCount: 20) == 2...3)
        #expect(NeuralGistPolicy.stageBounds(stepCount: 150) == 3...5)
        #expect(NeuralGistPolicy.stageBounds(stepCount: 900) == 5...7)
    }

    @Test func aTurnIsToldAgainOnlyWhenItGrewAndTheWaitPassed() {
        let told = (stepCount: 40, running: true)
        func due(_ steps: Int, running: Bool = true, since: TimeInterval?, took: TimeInterval? = 2, failed: Bool = false) -> Bool {
            NeuralGistPolicy.isDue(
                told: told, stepCount: steps, running: running, sinceLast: since, lastTook: took, failed: failed)
        }
        #expect(NeuralGistPolicy.isDue(told: nil, stepCount: 40, running: true, sinceLast: nil, lastTook: nil, failed: false))
        #expect(!due(43, since: 300))
        #expect(!due(60, since: 10))
        #expect(due(60, since: 21))
        #expect(!due(60, since: 60, took: 30))
        #expect(due(60, since: 241, took: 30))
        #expect(due(40, running: false, since: 1))
        #expect(
            NeuralGistPolicy.isDue(
                told: (stepCount: 40, running: false), stepCount: 42, running: true, sinceLast: 1, lastTook: 2,
                failed: false))
        #expect(!due(60, since: 30, failed: true))
        #expect(due(60, since: 91, failed: true))
    }

    @Test func theLogIsTheAccountInOrder() throws {
        let ask = try #require(G.ask(G.model(), answer: "All shipped."))
        #expect(ask.stepCount == 20)
        #expect(ask.ends == [1, 4, 5, 8, 9, 12, 13, 16, 17, 20])
        #expect(ask.user.contains("What the person asked: ship the film"))
        #expect(ask.user.contains("The session is finished."))
        #expect(ask.user.contains("1. SAID: Round 0 of the work is under way."))
        #expect(ask.user.contains("2-4. WORK: "))
        #expect(ask.user.contains("What it answered at the end: All shipped."))
        #expect(ask.system.contains("2 to 3 stages"))
        #expect(!ask.system.contains("Write the title"))
    }

    @Test func aRunningTurnSaysSoAndSendsNoAnswer() throws {
        let ask = try #require(G.ask(G.model(running: true), answer: "ignored"))
        #expect(ask.running)
        #expect(ask.user.contains("The session is still running."))
        #expect(!ask.user.contains("What it answered"))
    }

    @Test func aSecretInANoteNeverTravels() throws {
        let ask = try #require(G.ask(G.model(secret: true)))
        #expect(!ask.user.contains("abcd1234"))
        #expect(ask.user.contains("API_TOKEN="))
    }

    @Test func anotherLanguageIsAskedFor() {
        #expect(NeuralGistAsk.system(stages: 2...4, language: "Finnish").contains("in Finnish"))
    }

    @Test func onlyStagesThatCarryWeightAreShownAgain() {
        let told = NeuralGist(
            title: "T", now: "N",
            stages: [
                .init(says: "Light", from: 1, to: 3), .init(says: "Heavy", from: 4, to: 60),
                .init(says: "Last", from: 61, to: 80),
            ], stepCount: 80, running: true, writer: "P", place: "arch", writtenAt: Date())
        let heavy = NeuralGistAsk.heavyStages(of: told, stepCount: 100, most: 4)
        #expect(heavy.map(\.says) == ["Heavy"])
    }

    @Test func anAnswerIsCheckedNotTrusted() throws {
        let ask = try #require(G.ask(G.model()))
        let gist = try #require(ask.read(completion: G.completion(G.written), writer: "Pennyroyal", place: "arch"))
        #expect(gist.title == "Shipping the film")
        #expect(gist.now == "Everything shipped.")
        #expect(gist.stages.map(\.says) == ["Looked around", "Built the project", "Shipped it"])
        #expect(gist.stages.map(\.to) == [8, 13, 20])
        #expect(gist.stages.map(\.from) == [1, 9, 14])
        #expect(gist.stepCount == 20)
        #expect(!gist.running)
    }

    @Test func anAnswerInAFenceAfterThinkingIsRead() throws {
        let ask = try #require(G.ask(G.model()))
        let wrapped = "<think>hm</think>\n```json\n" + G.written + "\n```"
        #expect(ask.read(wrapped, writer: "P", place: "arch") != nil)
    }

    @Test func whatIsNotATellingIsNoAnswer() throws {
        let ask = try #require(G.ask(G.model()))
        #expect(ask.read("Sure! Here is a summary.", writer: "P", place: "") == nil)
        #expect(ask.read(#"{"title": "T", "now": "N", "stages": []}"#, writer: "P", place: "") == nil)
        #expect(ask.read(#"{"title": "", "now": "N", "stages": [{"says": "A", "to": 20}]}"#, writer: "P", place: "") == nil)
    }

    @Test func stagesThatDoNotRiseAreDropped() throws {
        let ask = try #require(G.ask(G.model()))
        let text = #"{"title": "T", "now": "N", "stages": [{"says": "A", "to": 12}, {"says": "B", "to": 5}, {"says": "C", "to": 400}]}"#
        let gist = try #require(ask.read(text, writer: "P", place: ""))
        #expect(gist.stages.map(\.says) == ["A", "C"])
        #expect(gist.stages.map(\.to) == [12, 20])
    }

    @Test func tooManyStagesFoldIntoTheirHeavierNeighbours() {
        let stages = (0..<10).map { NeuralGist.Stage(says: "S\($0)", from: $0 * 10 + 1, to: $0 * 10 + ($0 == 4 ? 10 : 10)) }
        let folded = NeuralGistAsk.folded(stages, keepLast: true)
        #expect(folded.count == NeuralGistPolicy.mostStages)
        #expect(folded.first?.from == 1)
        #expect(folded.last?.to == 100)
        #expect(folded.last?.says == "S9")
        for (left, right) in zip(folded, folded.dropFirst()) { #expect(right.from == left.to + 1) }
    }

    @Test func aLongSentenceIsCutAtAWord() {
        let long = "Rebuilt the whole of the transcript pipeline from the ground up and verified every part of it twice"
        let cut = NeuralGistAsk.clean(long, limit: 60, period: false)
        #expect(cut.count <= 61)
        #expect(cut.hasSuffix("\u{2026}"))
        #expect(!cut.contains("  "))
    }

    @Test func aStageOpensItsPartOfTheAccount() {
        let account = G.model().account(answer: "All shipped.")
        let scoped = account.scoped(to: 5...12)
        let numbers = scoped.items.compactMap { NeuralGistAsk.lastNumber(of: $0) }
        #expect(numbers == [5, 8, 9, 12])
        #expect(scoped.utteranceCount == 2)
        #expect(scoped.answer == nil)
        #expect(scoped.result == nil)
        #expect(account.scoped(to: 17...20).answer != nil)
        let said = scoped.items.first { $0.isUtterance }
        #expect(said.flatMap { scoped.item(containing: $0.stepIDs[0]) } != nil)
    }

    @Test func thePaneCountsWhatTheModelOnlyNamed() throws {
        let model = G.model()
        let ask = try #require(G.ask(model))
        let gist = try #require(ask.read(completion: G.completion(G.written), writer: "Pennyroyal", place: "arch"))
        let reading = NeuralGistDesk.Reading(phase: .told, gist: gist, writer: "Pennyroyal", place: "arch", refreshing: false)
        let pane = try #require(NeuralGistPane.make(reading: reading, model: model))
        #expect(pane.title == "Shipping the film")
        #expect(pane.byline == "Pennyroyal on arch")
        #expect(pane.rows.map(\.stepCount) == [8, 5, 7])
        #expect(pane.rows.map(\.mark) == [.done, .done, .done])
        #expect(pane.rows[1].fixed == 1)
        #expect(pane.rows[1].ticks.count == 1)
        #expect(pane.rows[0].added == 8)
        #expect(pane.rows[0].tally != nil)
        #expect(abs(pane.rows.map(\.weight).reduce(0, +) - 1) < 0.0001)
        #expect(pane.row(containing: 10)?.index == 1)
        #expect(pane.rows[1].facts(of: 3).contains("9\u{2013}13"))
    }

    @Test func aTurnThatGrewKeepsItsLastStageOpen() throws {
        let small = G.model(rounds: 4, running: true)
        let ask = try #require(G.ask(small))
        let text = #"{"title": "T", "now": "Working.", "stages": [{"says": "Looked around", "to": 8}, {"says": "Building it", "to": 16}]}"#
        let gist = try #require(ask.read(text, writer: "P", place: "arch"))
        let grown = G.model(rounds: 5, running: true)
        let reading = NeuralGistDesk.Reading(phase: .told, gist: gist, writer: "P", place: "arch", refreshing: true)
        let pane = try #require(NeuralGistPane.make(reading: reading, model: grown))
        #expect(pane.rows.last?.to == 20)
        #expect(pane.rows.last?.mark == .now)
        #expect(pane.isRefreshing)
    }

    @Test func whileTheFirstTellingIsWrittenThePaneSaysWhoReads() throws {
        let reading = NeuralGistDesk.Reading(phase: .writing, gist: nil, writer: "Pennyroyal", place: "arch", refreshing: true)
        let pane = try #require(NeuralGistPane.make(reading: reading, model: G.model()))
        #expect(pane.isWriting)
        #expect(pane.title.contains("Pennyroyal"))
        #expect(pane.rows.isEmpty)
        #expect(NeuralGistPane.make(reading: .none, model: G.model()) == nil)
    }

    @Test func theDeskTellsATurnOnceAndKeepsIt() async {
        let transport = GistTransport()
        let clock = GistClock()
        let desk = desk(transport, clock)
        let model = G.model()
        #expect(desk.reading(for: "a").phase == .none)
        desk.want(key: "a", model: model, answer: "All shipped.", prompt: "ship the film")
        #expect(await eventually { desk.reading(for: "a").phase == .told })
        #expect(desk.reading(for: "a").gist?.title == "Shipping the film")
        #expect(desk.reading(for: "a").gist?.writer == "Pennyroyal")
        desk.want(key: "a", model: model, answer: "All shipped.", prompt: "ship the film")
        clock.advance(600)
        desk.want(key: "a", model: model, answer: "All shipped.", prompt: "ship the film")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(desk.requests == 1)
    }

    @Test func aRunningTurnIsToldAgainAsItGrowsAndOnceMoreWhenItEnds() async {
        let transport = GistTransport()
        transport.answer = G.completion(#"{"title": "T", "now": "Working.", "stages": [{"says": "Looked around", "to": 8}, {"says": "Building it", "to": 16}]}"#)
        let clock = GistClock()
        let desk = desk(transport, clock)
        desk.want(key: "a", model: G.model(rounds: 4, running: true))
        #expect(await eventually { desk.reading(for: "a").phase == .told })
        desk.want(key: "a", model: G.model(rounds: 6, running: true))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(desk.requests == 1)
        clock.advance(30)
        desk.want(key: "a", model: G.model(rounds: 6, running: true))
        #expect(await eventually { desk.requests == 2 })
        #expect(transport.asked.last?.contains("Stages told earlier:") == true)
        #expect(await eventually { !desk.reading(for: "a").refreshing })
        desk.want(key: "a", model: G.model(rounds: 6, running: false), answer: "All shipped.")
        #expect(await eventually { desk.requests == 3 })
        #expect(await eventually { desk.reading(for: "a").gist?.running == false })
    }

    @Test func aTellingNeverOutlivesATurnThatBeganAgain() async throws {
        let transport = GistTransport()
        let clock = GistClock()
        let desk = desk(transport, clock)
        desk.want(key: "a", model: G.model(), answer: "All shipped.")
        #expect(await eventually { desk.reading(for: "a").phase == .told })
        let told = try #require(desk.reading(for: "a").gist)
        let stale = NeuralGistDesk.Reading(phase: .told, gist: told, writer: "P", place: "arch", refreshing: false)
        #expect(NeuralGistPane.make(reading: stale, model: G.model(rounds: 3, running: true)) == nil)
        transport.answer = G.completion(#"{"title": "T", "now": "Working.", "stages": [{"says": "Looked around", "to": 8}, {"says": "Building it", "to": 12}]}"#)
        desk.want(key: "a", model: G.model(rounds: 3, running: true))
        #expect(await eventually { desk.reading(for: "a").gist?.stepCount == 12 })
        #expect(desk.reading(for: "a").gist?.running == true)
    }

    @Test func aModelThatIsNotInMemoryIsNeverAsked() async {
        let transport = GistTransport()
        let desk = desk(transport, GistClock(), ready: false)
        desk.want(key: "a", model: G.model())
        try? await Task.sleep(for: .milliseconds(80))
        #expect(desk.requests == 0)
        #expect(desk.reading(for: "a").phase == .none)
    }

    @Test func theSwitchOffAsksNothing() async {
        let transport = GistTransport()
        let desk = desk(transport, GistClock(), on: false)
        desk.want(key: "a", model: G.model())
        try? await Task.sleep(for: .milliseconds(60))
        #expect(desk.requests == 0)
        #expect(desk.writer == nil)
    }

    @Test func aModelThatDoesNotAnswerLeavesTheAccountAsItWas() async {
        let transport = GistTransport()
        transport.fails = true
        let clock = GistClock()
        let desk = desk(transport, clock)
        desk.want(key: "a", model: G.model())
        #expect(await eventually { desk.requests == 1 })
        #expect(await eventually { desk.reading(for: "a").phase == .none })
        clock.advance(30)
        desk.want(key: "a", model: G.model())
        try? await Task.sleep(for: .milliseconds(60))
        #expect(desk.requests == 1)
        transport.fails = false
        clock.advance(100)
        desk.want(key: "a", model: G.model())
        #expect(await eventually { desk.reading(for: "a").phase == .told })
    }

    @Test func aPlacedTellingShowsWithNoModelAndIsNeverAskedAgain() async throws {
        let transport = GistTransport()
        let desk = NeuralGistDesk(
            transport: transport, clock: { Date() }, helper: { nil }, isOn: { true }, isReady: { _ in true })
        let model = G.model()
        let gist = try #require(NeuralGistDemo.film(for: model))
        #expect(gist.stages.count == 3)
        #expect(gist.stages.last?.to == 20)
        desk.place(gist, for: "demo", model: model)
        #expect(desk.reading(for: "demo").phase == .told)
        desk.want(key: "demo", model: model)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(desk.requests == 0)
        let pane = try #require(NeuralGistPane.make(reading: desk.reading(for: "demo"), model: model))
        #expect(pane.byline == NeuralGistDemo.writer)
        desk.forget("demo")
        #expect(desk.reading(for: "demo").phase == .none)
    }

    @Test func aModelOnTheInternetIsNeverTheWriter() {
        let desk = NeuralGistDesk(
            transport: GistTransport(), helper: { ImageGenHelper(address: "https://api.example.com", model: "m") },
            isOn: { true }, isReady: { _ in true })
        #expect(desk.writer == nil)
    }
}
