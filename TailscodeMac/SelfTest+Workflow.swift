import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The workflow card's own mark, which is the whole of what a reader saw go wrong: a ring still
    /// turning over a run that ended long ago. Proved without a window, because what a mark is doing
    /// is a state it wears rather than an animation to watch — and a screenshot could never tell a
    /// settled ring from a sweep caught mid-frame anyway.
    /// A month spent mostly on the owner's own GPU: the window must put the section about it
    /// directly under the number, ahead of the daily chart, with its tiles and its codenamed rows;
    /// a month spent mostly on hosted models must keep the money first and put the section after
    /// the models.
    static func checkLocalWorkLayout() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("local work case failed: \(label)") }
            checks += 1
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        func report(local: Int, hosted: Int) -> UsageAnalyticsReport {
            let localTokens = SessionSpendReport.Tokens(input: local * 8 / 10, output: local * 2 / 10)
            let hostedTokens = SessionSpendReport.Tokens(output: hosted)
            let total = SessionSpendReport.Tokens(
                input: localTokens.input, output: localTokens.output + hostedTokens.output)
            return UsageAnalyticsReport(
                since: Date(timeIntervalSinceNow: -30 * 86400), generatedAt: Date(), days: 30,
                totals: UsageAnalyticsReport.Totals(
                    costUSD: 3.2, tokens: total, sessions: 8, activeDays: 1),
                daily: [
                    UsageAnalyticsReport.Day(
                        day: formatter.string(from: Date()), costUSD: 3.2, tokens: total,
                        sessions: 8)
                ],
                models: [
                    SessionSpendReport.ModelShare(
                        model: "llama-server/qwen3-coder-30b-a3b", turns: 0, tokens: localTokens,
                        costUSD: 0),
                    SessionSpendReport.ModelShare(
                        model: "claude-opus-5", turns: 0, tokens: hostedTokens, costUSD: 3.2),
                ],
                coverage: .sessionTotals)
        }
        let names = ["llama-server/qwen3-coder-30b-a3b": "Bolt"]
        func positions(_ analytics: UsageAnalytics) -> (hero: Int, local: Int, daily: Int, models: Int, texts: [String]) {
            let controller = AnalyticsWindowController { _ in nil }
            let texts = controller.texts(laying: analytics)
            func first(_ word: String) -> Int { texts.firstIndex(of: word) ?? Int.max }
            return (
                first(analytics.headline), first("On your own machine"),
                first(analytics.window.chartTitle), first("Models"), texts
            )
        }
        guard
            let led = UsageAnalytics(
                servers: [("homelab", report(local: 9_000_000, hosted: 1_000_000))],
                modelNames: names),
            let mixed = UsageAnalytics(
                servers: [("homelab", report(local: 1_000_000, hosted: 9_000_000))],
                modelNames: names)
        else { throw SelfTestFailure("the local-led fixture produced no analytics") }
        let ledAt = positions(led)
        try expect(led.isLocalLed, "nine tenths of the work on a local door is local-led")
        try expect(ledAt.hero < ledAt.local, "the section sits under the number")
        try expect(ledAt.local < ledAt.daily, "and ahead of the daily chart")
        try expect(ledAt.local < ledAt.models, "and ahead of the models")
        try expect(ledAt.models < ledAt.daily, "with the models moved up beside it")
        try expect(!led.headline.contains("$"), "the number is the work rather than the bill")
        try expect(ledAt.texts.contains("Bolt"), "a model wears the name the catalog gave it")
        for stat in led.localWork?.stats ?? [] {
            try expect(ledAt.texts.contains(stat.value), "the tile for \(stat.label) is drawn")
        }
        try expect(
            led.hostedLine.map { ledAt.texts.contains($0) } == true,
            "the bill is one line under the number")
        let mixedAt = positions(mixed)
        try expect(!mixed.isLocalLed && mixed.headline.contains("$"), "a hosted-led month keeps the money")
        try expect(mixedAt.local != Int.max, "and still gains the section")
        try expect(mixedAt.daily < mixedAt.models, "the chart stays above the models")
        try expect(mixedAt.models < mixedAt.local, "and the section follows the models")
        return checks
    }

    static func checkWorkflowCard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("workflow card case failed: \(label)") }
            checks += 1
        }
        let call = ToolCall(
            id: "call-1", name: "Workflow", status: .completed,
            output: "Workflow launched in background. Task ID: task-1")
        let context = TranscriptContext()
        func mark(of state: WorkflowRun.State?) throws -> ActivityMarkLabel {
            context.workflowRuns = state.map {
                [call.id: WorkflowRun(id: call.id, name: "kaytetty-best", state: $0)]
            } ?? [:]
            let view = WorkflowCardView.make(call, key: "wf", context: context)
            guard let label = markLabel(in: view) else {
                throw SelfTestFailure("workflow card case failed: the header wears a live mark")
            }
            return label
        }

        try expect(try mark(of: .running).icon?.motion == .turning, "a live run turns")
        try expect(try mark(of: .launching).icon == .openWork, "and so does one still launching")
        for ending in [WorkflowRun.State.finished, .stopped("stopped"), .failed("broke")] {
            try expect(
                try mark(of: ending).icon?.motion == .still, "an ending holds perfectly still")
        }
        try expect(
            try mark(of: .finished).stringValue == ActivityIcon.finished.glyph,
            "and shows the ending's own glyph rather than the frame the sweep died on")
        try expect(
            try mark(of: .stopped("stopped")).icon?.tone == .quiet,
            "a run that was stopped is not blamed for a fault")
        try expect(try mark(of: nil).icon == .idle, "a call whose run has not landed has not started")

        context.workflowRuns = [call.id: WorkflowRun(id: call.id, name: "n", state: .running)]
        let card = WorkflowCardView.make(call, key: "wf", context: context)
        context.workflowRuns = [call.id: WorkflowRun(id: call.id, name: "n", state: .finished)]
        try expect(
            WorkflowCardView.restate(card, call: call, context: context),
            "the once-a-second tick restates the card in place")
        try expect(
            markLabel(in: card)?.icon == .finished,
            "and the ending reaches the mark without a rebuild")

        let plan = (0..<4).map { WorkflowPhase(index: $0, title: "phase \($0)") }
        let sweeping = WorkflowAgent(
            id: "a", title: "hunt", isActive: true, isCompleted: false, currentTool: "WebFetch",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        context.expanded.set("wf", open: true)
        func drawn(_ state: WorkflowRun.State) -> NSView {
            context.workflowRuns = [
                call.id: WorkflowRun(
                    id: call.id, name: "kaytetty-best", phases: plan, agents: [sweeping],
                    state: state)
            ]
            return WorkflowCardView.make(call, key: "wf", context: context)
        }
        func rail(_ state: WorkflowRun.State) throws -> [NSTextField] {
            let marks = phaseMarks(in: drawn(state))
            guard marks.count == plan.count else {
                throw SelfTestFailure(
                    "workflow card case failed: the rail draws every phase the script declares")
            }
            return marks
        }
        func reads(_ reading: WorkflowPhaseStanding, on marks: [NSTextField]) -> Bool {
            marks.allSatisfy {
                $0.stringValue.hasSuffix(reading.glyph)
                    && light(of: $0.textColor) == light(of: reading.tone.color)
            }
        }

        try expect(
            reads(.planned, on: try rail(.running)),
            "a live run's rail is the plan it is, because where it has got to is recorded nowhere")
        try expect(
            reads(.done, on: try rail(.finished)),
            "only a run that reported a completion has its declared phases behind it")
        for ending in [WorkflowRun.State.stopped("stopped"), .failed("broke")] {
            try expect(
                reads(.unfinished, on: try rail(ending)),
                "and a run that was killed or broke draws the plan as the plan it stayed")
        }
        try expect(
            try rail(.stopped("stopped")).allSatisfy {
                !$0.stringValue.hasSuffix(WorkflowPhaseStanding.done.glyph)
                    && light(of: $0.textColor) != light(of: WorkflowPhaseStanding.done.tone.color)
            },
            "claiming neither the mark nor the colour of a run that got all the way through")

        func agentMark(_ state: WorkflowRun.State) throws -> ActivityBadgeView {
            guard let badge = agentBadge(in: drawn(state)) else {
                throw SelfTestFailure(
                    "workflow card case failed: a run draws a mark for every agent under it")
            }
            return badge
        }
        try expect(
            try agentMark(.running).icon == .openWork, "an agent out on its errand turns")
        for ending in [WorkflowRun.State.finished, .stopped("stopped"), .failed("broke")] {
            try expect(
                try agentMark(ending).icon?.motion == .still,
                "and settles the moment the run is over, whatever its own record still claims")
        }

        func agentRow(_ state: WorkflowRun.State) -> String {
            WorkflowCardView.agentReading(of: drawn(state))
        }
        try expect(
            agentRow(.running).hasSuffix(":\(sweeping.currentTool ?? "")"),
            "an agent the mark shows as out names the tool it is holding")
        for ending in [WorkflowRun.State.finished, .stopped("stopped"), .failed("broke")] {
            try expect(
                agentRow(ending).hasSuffix(":still:"),
                "and the caption goes with the mark, so a row under an ended run names no tool")
        }
        try expect(
            systemIndicator(in: drawn(.running)) == nil,
            "with nothing on the card AppKit spins at a rate this app cannot read")

        let began = Date(timeIntervalSince1970: 1_700_000_000)
        let over = began.addingTimeInterval(252)
        let week = over.addingTimeInterval(604_800)
        let errand = WorkflowAgent(
            id: "a", title: "hunt", isActive: true, isCompleted: false, startedAt: began,
            updatedAt: over.addingTimeInterval(1_800))
        func clock(_ state: WorkflowRun.State, ending: Date?, read now: Date) -> String {
            context.workflowRuns = [
                call.id: WorkflowRun(
                    id: call.id, name: "kaytetty-best", agents: [errand], state: state,
                    startedAt: began, finishedAt: ending)
            ]
            context.workflowNow = now
            return WorkflowCardView.agentClockReading(
                of: WorkflowCardView.make(call, key: "wf", context: context))
        }
        try expect(
            clock(.running, ending: nil, read: over) == "clocks=" + WorkflowRun.duration(252),
            "an agent still out under a run that is going is timed to the reader's clock")
        try expect(
            clock(.running, ending: nil, read: week) != clock(.running, ending: nil, read: over),
            "which is what makes it a clock while the run is still going")
        for ending in [WorkflowRun.State.finished, .stopped("stopped"), .failed("broke")] {
            try expect(
                clock(ending, ending: over, read: over) == "clocks="
                    + WorkflowRun.duration(252),
                "an ended run credits its rows with the errand they ran, not the sidecar's own"
                    + " half hour past it")
            try expect(
                clock(ending, ending: over, read: week) == clock(ending, ending: over, read: over),
                "and a card reopened a week later reads the same, because the clock stopped"
                    + " with the run")
        }
        return checks
    }

    /// What a colour actually resolves to, because a themed token is minted on every read: a
    /// dynamic `NSColor` answers a question rather than holding an answer, and two of them are
    /// never equal to one another. A claim about a colour is therefore made about the light it
    /// comes out as under the appearance being drawn in.
    private static func light(of color: NSColor?) -> [CGFloat] {
        guard let sRGB = color?.usingColorSpace(.sRGB) else { return [] }
        return [sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent, sRGB.alphaComponent]
    }

    /// Every phase marker in a card: the rule-and-block labels the rail is drawn out of, found by
    /// the rule they open with rather than by reaching into the card's private shape.
    private static func phaseMarks(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField,
            label.stringValue.hasPrefix("├") || label.stringValue.hasPrefix("└")
        {
            found.append(label)
        }
        for child in view.subviews { found += phaseMarks(in: child) }
        return found
    }

    static func agentBadge(in view: NSView) -> ActivityBadgeView? {
        if let badge = view as? ActivityBadgeView { return badge }
        for child in view.subviews {
            if let found = agentBadge(in: child) { return found }
        }
        return nil
    }

    static func systemIndicator(in view: NSView) -> NSProgressIndicator? {
        if let indicator = view as? NSProgressIndicator { return indicator }
        for child in view.subviews {
            if let found = systemIndicator(in: child) { return found }
        }
        return nil
    }
}
