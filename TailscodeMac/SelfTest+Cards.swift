import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The card a cut-off turn draws, built as the transcript builds it, in every state it has.
    ///
    /// What is proved here is that the Mac renders Core's answers rather than its own: the sentence
    /// about what never ran, the one about what leaving the card undecided costs, and the two button
    /// titles all have to be the strings Core hands over, character for character. The press states
    /// are proved on the view because that is where the defect was — a press that changed nothing on
    /// screen — and a resumed card is proved to offer nothing, because both of its actions would lie.
    static func checkInterruptedCard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("cut-off card: \(label)") }
            checks += 1
        }
        let context = TranscriptContext()
        context.resumeInterrupted = {}
        context.dismissInterrupted = {}
        func view(_ turn: InterruptedTurn) -> NSView {
            TranscriptRow(key: "interrupted", kind: .interruptedTurn(turn))
                .makeView(context: context)
        }
        func says(_ turn: InterruptedTurn, _ text: String) -> Bool {
            words(in: view(turn)).contains { $0.contains(text) }
        }

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let cutOff = TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started,
            detectedAt: started.addingTimeInterval(200),
            progress: TurnInterruption.Progress(toolCount: 3, lastTool: "Edit"),
            queued: ["and then the mac"])
        guard let waiting = InterruptedTurnReading.read(cutOff) else {
            throw SelfTestFailure("cut-off card: an interrupted turn reads as a card")
        }

        guard let queuedLine = waiting.queuedLine, let cost = waiting.cost else {
            throw SelfTestFailure(
                "cut-off card: an undecided card has both a queued line and a cost to state")
        }
        try expect(says(waiting, waiting.prompt), "the card carries what was asked")
        try expect(
            says(waiting, queuedLine),
            "what never ran is said in Core's sentence, not one retyped here")
        try expect(
            says(waiting, cost),
            "and the card says the session will not carry itself on while it stands")
        let offered = buttons(in: view(waiting))
        try expect(
            offered.map(\.title) == [waiting.resumeTitle, waiting.dismissTitle],
            "an undecided card offers exactly the two actions, in Core's words")
        try expect(offered.allSatisfy(\.isEnabled), "both of which can be pressed")

        let pickingUp = InterruptedTurnReading.pressed(waiting, .pickUp)
        let pressed = buttons(in: view(pickingUp))
        try expect(
            pressed.first?.title == InterruptedTurn.pickingUpTitle,
            "a press renames its own button the instant it lands")
        try expect(
            pressed.allSatisfy { !$0.isEnabled }, "and the card stops taking a second press")
        try expect(
            pickingUp.cost == nil && !says(pickingUp, cost),
            "a decided card stops charging for standing")
        try expect(
            buttons(in: view(InterruptedTurnReading.pressed(waiting, .letGo))).last?.title
                == InterruptedTurn.lettingGoTitle,
            "letting go acknowledges itself the same way")

        let resumed = InterruptedTurnReading.read(
            TurnInterruption(
                turnID: "t1", prompt: "port the toggles", startedAt: started,
                detectedAt: started.addingTimeInterval(200), resumedAt: Date()))
        guard let resumed else {
            throw SelfTestFailure("cut-off card: a resumed turn still draws its card")
        }
        try expect(
            buttons(in: view(resumed)).isEmpty,
            "a turn the server picked back up offers nothing, because both actions would lie")
        try expect(says(resumed, resumed.detail), "and says instead that the work is going again")
        return checks
    }

    /// A note is a quiet line, never a card: the words are Core's own sentence, drawn with no
    /// button under them, and a model this device cannot name yet still reads as something:
    /// Core's own id fallback rather than a blank.
    static func checkTranscriptNote() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("note row: \(label)") }
            checks += 1
        }
        let context = TranscriptContext()
        func view(_ note: TranscriptNote, modelName: @escaping (ModelSelection) -> String? = { _ in nil })
            -> NSView
        {
            context.modelName = modelName
            return TranscriptRow(key: "note", kind: .note(note)).makeView(context: context)
        }

        let finished = TranscriptNote(
            .workFinished("go test ./internal/auth/...", work: .command, outcome: .completed))
        let read = TranscriptNoteReading.read(finished)
        try expect(
            words(in: view(finished)).contains { $0.contains(read.text) },
            "a finished background command reads Core's own sentence")
        try expect(
            buttons(in: view(finished)).isEmpty, "and offers no button, because a note is not a card")

        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
        let switched = TranscriptNote(.model(selection, effort: nil, previous: nil))
        try expect(
            words(in: view(switched)).contains { $0.contains(selection.modelID) },
            "an unnamed model falls back to its id, which Core promises when the catalog cannot name it")
        try expect(
            words(in: view(switched, modelName: { _ in "Sonnet 5" })).contains {
                $0.contains("Sonnet 5")
            }, "and wears the catalog's own name once this device can offer one")
        return checks
    }

    /// The provider-retry card draws exactly what Core wrote: the reason, the attempt line that
    /// carries the countdown, and a remedy button that exists only when the provider actually gave
    /// an address to press. A remedy with words and no link must not draw a dead button.
    static func checkProviderRetryCard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("provider retry card: \(label)") }
            checks += 1
        }
        let context = TranscriptContext()
        func view(_ card: ProviderRetryCard) -> NSView {
            TranscriptRow(key: "retry", kind: .providerRetry(card)).makeView(context: context)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bare = TurnRetry(
            attempt: 2, reason: "The provider is rate-limited.",
            nextAttemptAt: now.addingTimeInterval(75))
        guard let bareCard = ProviderRetryReading.read(bare, now: now) else {
            throw SelfTestFailure("provider retry card: a standing retry reads as a card")
        }
        let bareWords = words(in: view(bareCard))
        try expect(
            bareWords.contains { $0.contains(bareCard.reason) },
            "the provider's own reason is on the card")
        try expect(
            bareWords.contains { $0.contains(bareCard.attemptLine) },
            "the attempt line carries the countdown in Core's own words")
        try expect(buttons(in: view(bareCard)).isEmpty, "and no remedy means no button")

        let remedy = TurnRetry.Remedy(
            title: "Raise your limit", message: "Your plan is out of capacity for today.",
            label: "Manage plan", link: "https://example.com/billing")
        let withLink = TurnRetry(attempt: 3, reason: "Plan exhausted.", remedy: remedy)
        guard let linkedCard = ProviderRetryReading.read(withLink, now: now),
            let coreRemedy = linkedCard.remedy
        else {
            throw SelfTestFailure("provider retry card: a remedy the provider named reads as one")
        }
        try expect(
            buttons(in: view(linkedCard)).map(\.title) == [coreRemedy.label],
            "a remedy with a link draws exactly its own button")

        let noLinkRemedy = TurnRetry.Remedy(
            title: "Raise your limit", message: "Your plan is out of capacity for today.",
            label: "Manage plan")
        let withoutLink = TurnRetry(attempt: 3, reason: "Plan exhausted.", remedy: noLinkRemedy)
        guard let unlinkedCard = ProviderRetryReading.read(withoutLink, now: now) else {
            throw SelfTestFailure("provider retry card: a remedy with no link still reads as one")
        }
        try expect(
            buttons(in: view(unlinkedCard)).isEmpty,
            "a remedy the provider gave no address for draws no button, because it names no press")
        return checks
    }

    /// The revert banner draws Core's own file list and paging line, and the Restore button wears
    /// exactly the two words and the two enabled states Core names.
    static func checkRevertBanner() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("revert banner: \(label)") }
            checks += 1
        }
        let context = TranscriptContext()
        context.restoreRevert = {}
        func view(_ banner: RevertBanner, restoring: Bool) -> NSView {
            TranscriptRow(key: "revert", kind: .revertBanner(banner, restoring: restoring))
                .makeView(context: context)
        }

        let files = (1...9).map {
            SessionRevert.File(
                path: "internal/auth/file\($0).go", change: .modified, additions: $0, deletions: 1)
        }
        let revert = SessionRevert(messageID: "m1", files: files)
        let setAside: [ChatMessage] = [
            ChatMessage(
                id: "m1", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "m1/text", kind: .text("port the toggles"))],
                createdAt: Date())
        ]
        guard let banner = RevertReading.read(revert, setAside: setAside) else {
            throw SelfTestFailure("revert banner: a standing revert reads as a banner")
        }
        let bannerWords = words(in: view(banner, restoring: false))
        try expect(
            bannerWords.contains { $0.contains(banner.title) },
            "the title is Core's own count of what was set aside")
        let paged = banner.files(upTo: 6)
        try expect(paged.shown.count == 6, "six files fit before the banner pages the rest")
        for file in paged.shown {
            try expect(
                bannerWords.contains { $0.contains(file.path) }, "each shown file draws its own path")
        }
        guard let more = paged.more else {
            throw SelfTestFailure("revert banner: nine files page past the limit")
        }
        try expect(
            bannerWords.contains { $0.contains(more) },
            "and the rest collapse into Core's own paging line")

        let idle = buttons(in: view(banner, restoring: false))
        try expect(
            idle.map(\.title) == [banner.restoreTitle],
            "restore reads Core's own title while nothing is running")
        try expect(idle.allSatisfy(\.isEnabled), "and can be pressed")
        let busy = buttons(in: view(banner, restoring: true))
        try expect(
            busy.map(\.title) == [RevertReading.restoringTitle],
            "a press in flight renames the button to Core's own word")
        try expect(busy.allSatisfy { !$0.isEnabled }, "and disables it at once")
        return checks
    }

    /// Every word actually on a built row, so a claim about what a card says is checked against the
    /// pixels rather than against the value that was passed in.
    private static func words(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for child in view.subviews { found += words(in: child) }
        return found
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for child in view.subviews { found += buttons(in: child) }
        return found
    }
}
