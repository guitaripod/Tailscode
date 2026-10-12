import CodingAgentKit
import TailscodeCore
import UIKit

/// A transcript cell that takes the air above it from the data source rather than choosing it, so
/// the whole of a row's vertical rhythm is one decision in `ChatSpacing`.
@MainActor
protocol RowGapCell: AnyObject {
    var gapAbove: CGFloat { get set }
}

/// The one place that decides how much air a transcript row gets above it. A row is classified
/// once, `ChatMetrics.gap(from:to:)` answers for the pair, and the data source hands the number to
/// the cell, so no cell names a gap of its own and a density change is a rebuild rather than an
/// edit to twenty constraints.
enum ChatSpacing {
    /// The margin above the first row of a transcript. It is the list's edge, not the air between
    /// two rows, so it is not a function of any pair.
    static let edgeMargin = Theme.Spacing.xs

    /// What a drawn row is, for the purpose of the space around it. Cards that keep a plate —
    /// tables, subagent and workflow cards, boards, a failed turn, the answerless turn — take the code
    /// gap, because the metrics give a block that air and a flat line next to a plate needs more
    /// than two points.
    static func rowClass(of row: ChatRow) -> ChatRowClass {
        switch row.content {
        case .text:
            return row.role == .user ? .prompt : .prose
        case .file:
            return row.role == .user ? .prompt : .furniture
        case .code, .table, .tableDraft, .subagent, .workflow, .taskBoard, .designBoard, .failed,
            .answerless:
            return .code
        case .activity, .subagentGroup, .timestamp, .responseStats:
            return .furniture
        case .compaction, .note:
            return .seam
        case .image, .pictures:
            return .picture
        case .linkRail:
            return .rail
        }
    }

    /// The air above a row whose predecessor is `previous`. A picture a person sent sits close to
    /// the words it was sent with, so a prompt's own pictures take the strip gap rather than the
    /// turn gap the pair would otherwise earn. A time stamp is the header of the turn after it: a
    /// turn's gap above, and the nearly-touching gap of two flat lines below.
    static func gap(
        from previous: ChatRowClass?, to next: ChatRowClass, sameSend: Bool, metrics: ChatMetrics,
        previousIsStamp: Bool = false, nextIsStamp: Bool = false
    ) -> CGFloat {
        guard previous != nil else { return edgeMargin }
        if nextIsStamp { return CGFloat(metrics.turnGap) }
        if previousIsStamp { return CGFloat(metrics.furnitureGap) }
        if sameSend, previous == .picture || next == .picture {
            return CGFloat(metrics.pictureStripGap)
        }
        return CGFloat(metrics.gap(from: previous, to: next))
    }

    #if DEBUG
        /// Checks the claims the layout leans on and answers what failed, empty when all hold.
        /// Run by `TAILSCODE_SELFTEST_CHAT=1`, because this client has no test target and every
        /// number here is the compact design's.
        @MainActor
        static func selfCheck() -> [String] {
            var failures: [String] = []
            func expect(_ condition: Bool, _ what: String) {
                if !condition { failures.append(what) }
            }
            let compact = ChatMetrics.metrics(for: .compact, input: .touch)
            func row(_ content: ChatRow.Content, _ role: MessageRole = .assistant) -> ChatRow {
                ChatRow(id: "x", messageID: "m", role: role, content: content)
            }
            let call = ToolCall(id: "t", name: "Read", status: .completed)
            let file = FileReference(mime: "image/png", filename: "a.png")
            let expectations: [(ChatRow, ChatRowClass)] = [
                (row(.text("hi"), .user), .prompt),
                (row(.text("hi")), .prose),
                (row(.code(CodeBlock(language: nil, source: ""))), .code),
                (row(.activity([.tool(call)])), .furniture),
                (row(.timestamp("")), .furniture),
                (row(.image(file)), .picture),
                (row(.pictures([file, file])), .picture),
                (row(.linkRail(LinkRailRun(addresses: ["https://a.example"]))), .rail),
                (row(.file(file), .user), .prompt),
                (row(.file(file)), .furniture),
            ]
            for (sample, expected) in expectations {
                expect(rowClass(of: sample) == expected, "class of \(sample.content) is \(expected)")
            }
            func gap(_ a: ChatRowClass?, _ b: ChatRowClass, sameSend: Bool = false) -> CGFloat {
                Self.gap(from: a, to: b, sameSend: sameSend, metrics: compact)
            }
            expect(gap(nil, .prose) == edgeMargin, "the first row sits at the list's edge")
            expect(gap(.prose, .prose) == 8, "paragraph to paragraph is 8")
            expect(gap(.prose, .furniture) == 4, "prose to a flat line is 4")
            expect(gap(.furniture, .prose) == 4, "a flat line to prose is 4")
            expect(gap(.furniture, .furniture) == 2, "two flat lines nearly touch")
            expect(gap(.prose, .rail) == 4 && gap(.rail, .furniture) == 2, "a rail is a flat line")
            expect(gap(.prose, .code) == 6 && gap(.code, .prose) == 6, "code is 6 either way")
            expect(gap(.prose, .prompt) == 16, "a prompt starts a turn, 16 above it")
            expect(gap(.prompt, .prose) == 8, "a prompt is the heading of its answer, 8 below it")
            expect(
                Self.gap(from: .prose, to: .furniture, sameSend: false, metrics: compact, nextIsStamp: true) == 16
                    && Self.gap(
                        from: .furniture, to: .prompt, sameSend: false, metrics: compact,
                        previousIsStamp: true) == 2,
                "a stamp heads the next turn: 16 above, 2 below")
            let tired = SubagentCard(
                agentID: "a", title: "t", agentType: nil, isActive: false, isCompleted: true,
                updatedAt: Date(), expanded: false, isLoading: false, steps: [], report: nil)
            expect(
                ChatRowBuilder.dockable([tired]).isEmpty
                    && ChatRowBuilder.dockable([tired, SubagentCard(
                        agentID: "b", title: "t", agentType: nil, isActive: true,
                        isCompleted: false, updatedAt: Date(), expanded: false, isLoading: false,
                        steps: [], report: nil)]).count == 1,
                "only an agent that is out may dock under the last message")
            let claimedActive = SubagentSummary(
                id: "s", title: "t", updatedAt: Date(), isActive: true)
            let finishedAgent = SubagentSummary(
                id: "f", title: "t", updatedAt: Date(), isCompleted: true)
            let overTurn = SubagentPresence(agents: [claimedActive, finishedAgent], hold: .over(at: nil))
            let openTurn = SubagentPresence(agents: [claimedActive, finishedAgent], hold: .going)
            expect(overTurn.liveCount == 0, "under a turn that is over, no agent is out")
            expect(
                openTurn.liveCount == 1 && openTurn.dockable(among: [claimedActive, finishedAgent]).count == 1,
                "under an open turn only the active unfinished agent is out and dockable")
            func card(_ id: String, active: Bool, done: Bool) -> SubagentCard {
                SubagentCard(
                    agentID: id, title: id, agentType: nil, isActive: active, isCompleted: done,
                    updatedAt: Date(), expanded: false, isLoading: false, steps: [], report: nil)
            }
            let docked = ChatRowBuilder.makeRows(
                from: [],
                agents: ChatViewController.SubagentPlacement(
                    unattached: [card("done", active: false, done: true), card("live", active: true, done: false)]))
            expect(
                docked.map(\.id) == ["agent:live"],
                "the docked rows are the live agent only, got \(docked.map(\.id))")
            let onlyFinished = ChatRowBuilder.makeRows(
                from: [],
                agents: ChatViewController.SubagentPlacement(
                    unattached: [card("done", active: false, done: true)]))
            expect(onlyFinished.isEmpty, "a finished unattached agent docks nothing")
            expect(
                JumpReading.read(rowsNow: 40, rowsAtDeparture: 30, needsYou: false).label == Localized.text("New below")
                    && JumpReading.read(rowsNow: 40, rowsAtDeparture: 30, needsYou: true).label
                        == "Needs you"
                    && JumpReading.read(rowsNow: 30, rowsAtDeparture: 30, needsYou: false).label == nil
                    && JumpReading.read(rowsNow: 40, rowsAtDeparture: nil, needsYou: false).label == nil,
                "the jump control says needs-you first, then how many rows arrived, else nothing")
            expect(gap(.picture, .picture) == 8, "a strip's gutter is 8")
            expect(gap(.prompt, .picture, sameSend: true) == 6, "a prompt's own picture is close")
            expect(gap(.prompt, .picture) == 8, "a picture after a prompt of another send is its answer")
            expect(
                LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: true, turnIsOpen: true),
                "a run followed by furniture settles")
            expect(
                !LinkRailPolicy.isSettled(lastRowIsLive: true, followedByFurniture: true, turnIsOpen: true),
                "the live row never settles")
            expect(
                !LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: true),
                "an open turn's tail run waits")
            expect(
                LinkRailPolicy.isSettled(lastRowIsLive: false, followedByFurniture: false, turnIsOpen: false),
                "a finished turn's tail run settles")
            let strip = PictureStripLayout.layout(
                aspects: [1.0, 1.0, 1.0], width: 370, metrics: compact)
            expect(strip.lineCount == 2 && strip.height == 368, "three squares wrap to two lines of 180")
            return failures
        }
    #endif
}

extension TextBubbleCell: RowGapCell {}
extension PermissionCell: RowGapCell {}
extension CodeBlockCell: RowGapCell {}
extension ActivityGroupCell: RowGapCell {}
extension ThinkingCell: RowGapCell {}
extension QuestionCell: RowGapCell {}
extension PendingSendCell: RowGapCell {}
extension ImageBubbleCell: RowGapCell {}
extension TableCell: RowGapCell {}
extension TableDraftCell: RowGapCell {}
extension ResponseStatsCell: RowGapCell {}
extension DesignBoardCell: RowGapCell {}
extension SubagentGroupCell: RowGapCell {}
extension SubagentCardCell: RowGapCell {}
extension TaskBoardCell: RowGapCell {}
extension WorkflowCardCell: RowGapCell {}
extension AnswerlessTurnCell: RowGapCell {}
extension FailedTurnCell: RowGapCell {}
extension InterruptedTurnCell: RowGapCell {}
extension ProviderRetryCell: RowGapCell {}
extension RevertBannerCell: RowGapCell {}
extension CompactionCell: RowGapCell {}
extension TranscriptNoteCell: RowGapCell {}
extension LinkRailCell: RowGapCell {}
extension PictureStripCell: RowGapCell {}
