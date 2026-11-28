import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Money in the person's currency")
struct MoneyTests {
    static let document = Data(
        """
        <gesmes:Envelope><Cube><Cube time='2026-11-27'>
        <Cube currency='USD' rate='1.0957'/><Cube currency='JPY' rate='174.81'/>
        <Cube currency='SEK' rate='11.2080'/><Cube currency='ISK' rate='137.20'/>
        </Cube></Cube></gesmes:Envelope>
        """.utf8)

    private func rates(at date: Date = Date(), document: Data? = MoneyTests.document) -> CurrencyRates {
        let suite = "money-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return CurrencyRates(defaults: defaults, clock: { date }, fetch: { document })
    }

    private func eventually(_ what: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if what() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return what()
    }

    @Test func dollarsAreWrittenAsTheyAlwaysWere() {
        #expect(Money.dollars(0) == "$0")
        #expect(Money.dollars(0.004) == "<$0.01")
        #expect(Money.dollars(0.5) == "$0.50")
        #expect(Money.dollars(6) == "$6.00")
        #expect(Money.dollars(99.994) == "$99.99")
        #expect(Money.dollars(1305.4) == "$1,305")
    }

    @Test func theBanksDocumentIsUnitsPerEuro() throws {
        let read = try #require(CurrencyRates.read(Self.document))
        #expect(read["USD"] == 1.0957)
        #expect(read["JPY"] == 174.81)
        #expect(read.count == 4)
        #expect(CurrencyRates.read(Data("nothing".utf8)) == nil)
    }

    @Test func aDollarBuysTheCrossRate() async throws {
        let rates = rates()
        #expect(rates.rate(fromDollarsTo: "EUR") == nil)
        rates.refreshIfStale()
        #expect(await eventually { rates.rate(fromDollarsTo: "EUR") != nil })
        let euro = try #require(rates.rate(fromDollarsTo: "EUR"))
        #expect(abs(euro - 1 / 1.0957) < 0.000001)
        let krona = try #require(rates.rate(fromDollarsTo: "SEK"))
        #expect(abs(krona - 11.2080 / 1.0957) < 0.000001)
        #expect(rates.rate(fromDollarsTo: "TWD") == nil)
        #expect(rates.quoted == ["ISK", "JPY", "SEK", "USD"])
    }

    @Test func aTableNobodyCouldFetchConvertsNothing() async {
        let rates = rates(document: nil)
        rates.refreshIfStale()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rates.rate(fromDollarsTo: "EUR") == nil)
    }

    @Test func anAmountIsWrittenAsItsLocaleWritesMoney() {
        let finnish = Locale(identifier: "fi_FI")
        let american = Locale(identifier: "en_US")
        #expect(Money.local(162.4, code: "EUR", locale: american) == "€162")
        #expect(Money.local(3.1, code: "EUR", locale: american) == "€3.10")
        #expect(Money.local(0.004, code: "EUR", locale: american) == "<€0.01")
        #expect(Money.local(0, code: "EUR", locale: american) == "€0")
        let written = Money.local(3.1, code: "EUR", locale: finnish)
        #expect(written.contains("3,10"))
        #expect(written.contains("€"))
        #expect(Money.local(2590.7, code: "JPY", locale: american) == "¥2,591")
        #expect(Money.local(0.4, code: "JPY", locale: american) == "<¥1")
    }

    @Test func aCheckSpeaksDollars() {
        let was = Money.speaksDollarsOnly
        Money.speaksDollarsOnly = true
        defer { Money.speaksDollarsOnly = was }
        #expect(Money.estimate(6) == "$6.00")
        #expect(Money.approximate(6) == "~$6.00")
        #expect(SessionSpend.money(1305.4) == "$1,305")
    }
}

@Suite("What a turn cost, and where its list starts", .serialized)
struct NeuralTurnCostTests {
    typealias NF = NeuralTurnFixtures

    private func priced(_ message: ChatMessage, _ cost: Double) -> ChatMessage {
        var held = message
        held.costUSD = cost
        return held
    }

    private func messages(everyMessagePriced: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = [NF.user(0)]
        for round in 0..<5 {
            out.append(NF.message(round * 2 + 1, [.text("Round \(round) of the work is under way.")], model: "fable"))
            let work = NF.message(round * 2 + 2, [NF.bash("ls \(round)", out: ["a"]), NF.bash("pwd \(round)", out: ["b"]), NF.read("f\(round)", out: ["c"])], model: "fable")
            out.append(everyMessagePriced || round == 0 ? priced(work, 0.5) : work)
        }
        out.append(priced(NF.message(11, [.text("All shipped.")], model: "fable"), 0.25))
        return out
    }

    private func model(everyMessagePriced: Bool) -> NeuralBrainModel {
        BrainFixtures.model(NeuralTurns.partition(messages: messages(everyMessagePriced: everyMessagePriced), running: false)[0])
    }

    private func pane(_ model: NeuralBrainModel) throws -> NeuralGistPane {
        let ask = try #require(
            NeuralGistAsk.make(
                account: model.account(), stepCount: model.steps.count, running: false, prompt: nil, answer: nil,
                told: nil, language: "English"))
        let gist = try #require(
            ask.read(
                #"{"title": "T", "now": "N.", "stages": [{"says": "First half", "to": 8}, {"says": "Second half", "to": 20}]}"#,
                writer: "P", place: ""))
        return try #require(
            NeuralGistPane.make(
                reading: .init(phase: .told, gist: gist, writer: "P", place: "", refreshing: false), model: model))
    }

    @Test func aTurnCostsWhatItsMessagesCostTheAnswerIncluded() {
        let model = model(everyMessagePriced: true)
        #expect(model.turn.costUSD == 2.75)
        #expect(model.steps.compactMap(\.costUSD).reduce(0, +) == 2.5)
        #expect(model.steps.filter { $0.costUSD != nil }.count == 5)
        #expect(model.account().header.costUSD == 2.75)
    }

    @Test func aTurnNobodyPricedSaysNoPrice() {
        let turn = NeuralTurns.partition(messages: GistFixtures.messages(), running: false)[0]
        #expect(turn.costUSD == nil)
        #expect(turn.steps.allSatisfy { $0.costUSD == nil })
        let was = Money.speaksDollarsOnly
        Money.speaksDollarsOnly = true
        defer { Money.speaksDollarsOnly = was }
        #expect(!BrainFixtures.model(turn).account().vitals(now: Date()).counts.contains("$"))
    }

    @Test func theHeaderSaysThePriceAsAnEstimate() {
        let was = Money.speaksDollarsOnly
        Money.speaksDollarsOnly = true
        defer { Money.speaksDollarsOnly = was }
        #expect(model(everyMessagePriced: true).account().vitals(now: Date()).counts.hasSuffix("~$2.75"))
    }

    @Test func stagesArePricedOnlyWhenEveryStageIs() throws {
        let was = Money.speaksDollarsOnly
        Money.speaksDollarsOnly = true
        defer { Money.speaksDollarsOnly = was }
        let whole = try pane(model(everyMessagePriced: true))
        #expect(whole.rows.map(\.costUSD) == [1, 1.5])
        #expect(whole.rows[0].costWords == "~$1.00")
        #expect(whole.rows[1].facts(of: 2).hasSuffix("~$1.50"))
        let lump = try pane(model(everyMessagePriced: false))
        #expect(lump.rows.allSatisfy { $0.costUSD == nil })
    }

    @Test func aStageIsToldWholeUnderTheSaidOnlyStart() throws {
        let was = NeuralListStart.override
        defer { NeuralListStart.override = was }
        NeuralListStart.override = .said
        var turn = model(everyMessagePriced: true)
        turn.startList()
        #expect(turn.stepList.isSaidOnly)
        let whole = turn.account(answer: "Done.")
        #expect(whole.isNarrowed(by: turn.stepList))
        #expect(whole.scope == nil)
        #expect(!whole.scoped(to: 2...4).isNarrowed(by: turn.stepList))
        let other = try #require(turn.stepList.zoneChips.first { $0.zone != .say && $0.count > 0 })
        turn.browse(.zoneChip(other.zone, solo: false))
        #expect(turn.stepList.isNarrowed)
        #expect(turn.account(answer: nil).scoped(to: 2...4).isNarrowed(by: turn.stepList))
    }

    @Test func aListStartsOnWhatWasSaidUnlessThePersonChoseEverySte() {
        let was = NeuralListStart.override
        defer { NeuralListStart.override = was }
        NeuralListStart.override = .said
        var said = model(everyMessagePriced: true)
        let effects = said.startList()
        #expect(said.stepList.isSaidOnly)
        #expect(!said.stepList.isNarrowed)
        #expect(said.stepList.visibleCount == 5)
        #expect(!effects.isEmpty || said.stepList.isFiltered)
        #expect(said.startList().isEmpty)
        said.browse(.zoneChip(.say, solo: true))
        #expect(!said.stepList.isFiltered)
        said.startList()
        #expect(!said.stepList.isFiltered)
        #expect(said.firstVisibleStep(in: 1...4) == said.steps[0].id)

        NeuralListStart.override = .everything
        var all = model(everyMessagePriced: true)
        all.startList()
        #expect(!all.stepList.isFiltered)
        all.browse(.zoneChip(.say, solo: true))
        #expect(all.stepList.isSaidOnly && all.stepList.isNarrowed)
        #expect(all.firstVisibleStep(in: 2...4) == nil)
        #expect(all.firstVisibleStep(in: 2...5) == all.steps[4].id)
    }
}
