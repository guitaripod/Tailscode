import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural glyph on the wire")
struct NeuralGlyphWireTests {
    private func wire(
        _ zones: [Int] = [2, 3, 2, 18, 2, 2], failed: Int? = nil, active: Int? = nil,
        eye: String? = nil
    ) -> NeuralGlyphWire {
        NeuralGlyphWire(zones: zones, failed: failed, active: active, eye: eye)
    }

    @Test("every field after the counts is absent from the JSON until it is set")
    func sparse() throws {
        let data = try JSONEncoder().encode(wire())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["zones"])
    }

    @Test("a state from before the field decodes, and one with keys from later still does")
    func additive() throws {
        let bare = #"{"zones":[1,0,0,2,0,0]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NeuralGlyphWire.self, from: bare)
        #expect(decoded.zones == [1, 0, 0, 2, 0, 0] && decoded.eye == nil && decoded.active == nil)
        let later = #"{"zones":[1,0,0,2,0,0],"eye":"live","future":{"a":1}}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(NeuralGlyphWire.self, from: later).eyeTone == .live)
    }

    @Test("a count list of the wrong length is not a glyph and plans to nothing")
    func invalid() {
        #expect(wire([1, 2, 3]).plan() == nil)
        #expect(wire([1, 2, 3, 4, 5, -1]).plan() == nil)
        #expect(wire([1, 2, 3, 4, 5, 6]).plan() != nil)
        #expect(wire([1, 2, 3]).steps == 0)
    }

    @Test("an unknown or absent eye is quiet")
    func eyes() {
        #expect(wire(eye: nil).eyeTone == .quiet)
        #expect(wire(eye: "violet").eyeTone == .quiet)
        #expect(wire(eye: "danger").eyeTone == .danger)
        #expect(wire(eye: "identity").eyeTone == .identity)
    }

    @Test("a hue is trusted only as seven characters of hex")
    func hues() {
        #expect(NeuralGlyphWire.validHex("#D97757") == "#d97757")
        #expect(NeuralGlyphWire.validHex("d97757") == nil)
        #expect(NeuralGlyphWire.validHex("#d9775") == nil)
        #expect(NeuralGlyphWire.validHex("#zzzzzz") == nil)
        var sent = wire(eye: "identity")
        sent.hue = "#112233"
        sent.hueLight = "#445566"
        #expect(sent.hueHex(dark: true) == "#112233")
        #expect(sent.hueHex(dark: false) == "#445566")
        sent.hueLight = nil
        #expect(sent.hueHex(dark: false) == "#112233")
        sent.hue = "javascript"
        #expect(sent.hueHex(dark: true) == nil)
    }

    @Test("the plan draws what the glyph from steps draws, since both read one set of formulas")
    func planMatchesGlyph() {
        let turn = ReadingFixtures.buildFix()
        let glyph = NeuralGlyph(steps: turn.steps, eyeTone: .quiet, activeZone: .shell)
        let made = NeuralGlyphWire(turn: turn, activity: .usingTool(name: "Bash", kind: .shell))
        let plan = made.plan()
        #expect(plan?.dots.map(\.zone) == glyph.dots.map(\.zone.rawValue))
        #expect(plan?.dots.map(\.radius) == glyph.dots.map(\.radius))
        #expect(plan?.dots.map(\.opacity) == glyph.dots.map(\.opacity))
        #expect(plan?.dots.map(\.center) == glyph.dots.map(\.center))
        #expect(plan?.dots.map { $0.activeRing?.radius } == glyph.dots.map { $0.activeRing?.radius })
    }

    @Test("zone centres are read from one table by the zones and by the plan")
    func centres() {
        for zone in NeuralZone.allCases {
            #expect(zone.center == NeuralGlyphGeometry.zoneCenters[zone.rawValue])
        }
        #expect(NeuralGlyphGeometry.zoneCenters.count == NeuralGlyphGeometry.zoneCount)
    }

    @Test("a turn that ended well wears its model's hue, a failure holds danger and rings its zone")
    func eyeFromTheTurn() throws {
        var turn = ReadingFixtures.buildFix()
        turn.modelID = "claude-fable-1"
        let settled = NeuralGlyphWire(turn: turn, activity: nil)
        #expect(settled.eyeTone == .identity)
        #expect(settled.hueHex(dark: true) != nil && settled.hueHex(dark: false) != nil)
        #expect(settled.active == nil)
        #expect(settled.failed == nil)

        var broken = ReadingFixtures.buildFix(outcome: .failed)
        broken.steps[9].recovered = false
        let failed = NeuralGlyphWire(turn: broken, activity: nil)
        #expect(failed.eyeTone == .danger)
        #expect(failed.active == NeuralZone.shell.rawValue)
        #expect(failed.hasFailure(inZone: NeuralZone.shell.rawValue))
        #expect(!failed.hasFailure(inZone: NeuralZone.sense.rawValue))
    }

    @Test("a settled turn with no model has no identity to wear, so its eye is quiet")
    func unknownModel() {
        let wire = NeuralGlyphWire(turn: ReadingFixtures.buildFix(), activity: nil)
        #expect(wire.eyeTone == .quiet && wire.hue == nil)
    }

    @Test("a turn somebody stopped, or the machine cut off, is neutral and has no face")
    func noFace() {
        let turn = ReadingFixtures.buildFix()
        for ending in [NeuralOutcome.stopped, .interrupted, .answerless] {
            #expect(NeuralGlyphWire(turn: turn, activity: nil, outcome: ending).eyeTone == .quiet)
        }
    }

    @Test("a waiting approval rings the zone of what it waits on, in attention")
    func waiting() {
        var turn = ReadingFixtures.buildFix(outcome: .running)
        turn.steps[8].status = .waitingApproval
        let wire = NeuralGlyphWire(turn: turn, activity: .needsApproval)
        #expect(wire.eyeTone == .attention)
        #expect(wire.active == NeuralZone.shell.rawValue)
    }

    @Test("reads and files carry what the zone counts cannot")
    func census() {
        let wire = NeuralGlyphWire(turn: ReadingFixtures.buildFix(), activity: nil)
        #expect(wire.reads == 3)
        #expect(wire.files == 2)
        #expect(wire.zones == [2, 3, 4, 18, 0, 2])
    }

    @Test("the sentence written from the wire is the one written from the steps")
    func sentenceFromCounts() throws {
        let turn = ReadingFixtures.buildFix()
        let made = NeuralGlyphWire(turn: turn, activity: nil)
        let notice = NoticeWire(
            kind: .done, seconds: 505, tools: 25, added: 5, removed: 2, glyph: made)
        let reading = NoticeWords.reading(notice)
        #expect(reading.summary == NeuralReading.notice(for: turn))
        #expect(
            reading.summary
                == "25 tools in 8m 25s: ran 18 commands, read 3 files, edited 2 files (+5 −2)")
        #expect(reading.touched == "Ran 18 commands, read 3 files, edited 2 files (+5 −2)")
    }

    @Test("a notice with no glyph says nothing it cannot count")
    func noGlyphNoSentence() {
        let reading = NoticeWords.reading(NoticeWire(kind: .done, seconds: 60, tools: 4))
        #expect(reading.summary.isEmpty && reading.touched.isEmpty)
    }

    @Test("the glyph rides a notice through userInfo and is absent from one that has none")
    func inUserInfo() throws {
        let sent = NoticeWire(kind: .done, tools: 3, glyph: wire(eye: "identity"))
        let object = try #require(sent.userInfoValue())
        let back = try #require(NoticeWire(userInfo: [NoticeWire.key: object]))
        #expect(back.glyph == sent.glyph)
        #expect(try #require(NoticeWire(kind: .done).userInfoValue())["glyph"] == nil)
    }

    @Test("a single search or read or delegated task is told in the singular")
    func singular() {
        let counts = NeuralNoticeCounts(
            steps: 4, tools: 4, shell: 1, read: 1, search: 1, edited: 1, delegated: 1)
        #expect(
            NeuralNoticeLine.sentence(counts, seconds: nil)
                == "4 tools: ran 1 command, read 1 file, searched 1 time, edited 1 file, delegated 1 task")
    }
}

@Suite("Neural glyph on the Lock Screen")
struct LiveActivityGlyphTests {
    private static func state(_ messages: [ChatMessage], _ status: BackendStatus) -> ConversationState {
        ConversationState(
            messages: messages, status: status, connection: .live, hasLoadedTranscript: true)
    }

    private static var turn: [ChatMessage] {
        NeuralDemo.buildFix(answer: true)
    }

    @Test("a running turn's card carries a live eye and counts of what it has done")
    func live() throws {
        let running = Self.state(NeuralDemo.buildFix(answer: false), .running)
        let reading = LiveActivityReading.live(in: running)
        let glyph = try #require(reading.glyph)
        #expect(glyph.eyeTone == .live)
        #expect(glyph.isDrawable && glyph.steps > 0)
    }

    @Test("a finished turn's card wears the settled eye and no ring")
    func settled() throws {
        let ended = Self.state(Self.turn, .idle)
        let glyph = try #require(LiveActivityReading.settled(from: ended).glyph)
        #expect(glyph.active == nil)
        #expect(glyph.eyeTone != .live && glyph.eyeTone != .danger)
    }

    @Test("only the latest turn is counted, however long the conversation behind it")
    func latestTurnOnly() throws {
        let both = Self.state(NeuralDemo.conversation(), .idle)
        let last = Self.state(NeuralDemo.turn(prefix: "b-", origin: 1_792_003_600), .idle)
        let a = try #require(LiveActivityReading.settled(from: both).glyph)
        let b = try #require(LiveActivityReading.settled(from: last).glyph)
        #expect(a.zones == b.zones)
    }

    @Test("a conversation with nobody answering has no glyph to draw")
    func noTurn() {
        let user = NeuralDemo.buildFix().first { $0.role == .user }.map { [$0] } ?? []
        #expect(LiveActivityReading.live(in: Self.state(user, .running)).glyph == nil)
    }

    @Test("a failed ending holds danger whatever the message said")
    func failedEnding() throws {
        let ended = Self.state(Self.turn, .idle)
        let glyph = try #require(
            LiveActivityReading.glyph(in: ended, activity: nil, ending: .failed))
        #expect(glyph.eyeTone == .danger)
    }
}
