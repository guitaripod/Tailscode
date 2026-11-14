import CodingAgentKit
import Foundation

/// A chat list holding one of every row there is, for a client to draw without a server.
///
/// The list's grammar is a dozen states and no listing shows them all at once: a turn waiting to
/// run a command, one that failed while nobody looked, a machine that went quiet. This is the
/// whole set, read through the same grouping and the same news reading a live listing takes, so
/// a picture of it is a picture of what ships. The chats are the demo world's: nothing in it is
/// anyone's conversation.
public enum ChatListFixture {
    public struct Row: Equatable, Sendable {
        public let model: SessionRowModel
        public let news: ChatRowNews?
        public let section: SessionSection?
    }

    public struct Section: Equatable, Sendable {
        public let heading: SectionHeading
        public let rows: [Row]
    }

    /// What the fixture's rows have in common, read the way a live listing reads it, so no row
    /// names a fact every row shares.
    public static func vocabulary(now: Date = Date()) -> ChatListVocabulary {
        ChatListVocabulary(rows: models(now: now))
    }

    /// What the waiting row stopped to ask, as a client holding the call would know it.
    public static var asks: [String: ApprovalAsk] {
        ["fx-asking": ApprovalAsk(lead: Localized.text("Wants to run"), object: "git push origin release/2.4")]
    }

    /// Why the failed row was missed, as the device's own record of the alert would say.
    public static let missed: [String: MissedActivity.Reason] = ["fx-failed": .turnFailed]

    /// The conversation the fixture treats as open in the window.
    public static let openSessionID = "fx-working"

    /// - Parameter tail: leave out the two sections of the fleet, for a window too short to
    ///   show the list's far end under them.
    public static func sections(
        now: Date = Date(), calendar: Calendar = .current, tail: Bool = false
    ) -> [Section] {
        let all = everySection(now: now, calendar: calendar)
        return tail ? all.filter { $0.heading.total == nil } : all
    }

    private static func everySection(now: Date, calendar: Calendar) -> [Section] {
        return groupIntoListSections(models(now: now), now: now, calendar: calendar).map { section, members in
            Section(
                heading: SectionHeading(section: section, items: members.map(ChatListItem.chat)),
                rows: members.map { model in
                    Row(
                        model: model,
                        news: ChatRowNews.reading(
                            for: model, ask: asks[model.entry.session.id],
                            missed: missed[model.entry.session.id]),
                        section: section.board)
                })
        }
    }

    public static func models(now: Date = Date()) -> [SessionRowModel] {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        func entry(
            _ id: String, _ title: String, project: String, on machine: String, model: String,
            effort: String, ago: TimeInterval, said: String? = nil, carrying: BackgroundWork? = nil
        ) -> SessionEntry {
            SessionEntry(
                profileID: machine, profileName: machine, host: machine, backendType: .claudeCode,
                session: AgentSession(
                    id: id, agentType: .claudeCode, title: title, directory: "/Users/demo/dev/\(project)",
                    createdAt: now.addingTimeInterval(-ago - 20 * minute),
                    updatedAt: now.addingTimeInterval(-ago), model: model, reasoningEffort: effort,
                    backgroundWork: carrying, lastWords: said))
        }
        func row(
            _ entry: SessionEntry, unread: Bool = false, saved: Bool = false, pinned: Bool = false,
            presence: SessionPresence = .unobserved, unreachable: Bool = false
        ) -> SessionRowModel {
            SessionRowModel(
                entry: entry, unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
                presence: presence, observedAt: now.addingTimeInterval(-40 * minute), now: now)
        }
        return [
            row(
                entry(
                    "fx-asking", "Cut the 2.4 release branch", project: "pulse-server", on: "studio",
                    model: "claude-opus-5", effort: "xhigh", ago: 3 * minute),
                presence: .awaitingApproval),
            row(
                entry(
                    openSessionID, "Fix the flaky WebSocket reconnect test", project: "pulse-server",
                    on: "studio", model: "claude-opus-5", effort: "ultracode", ago: 12),
                presence: .running("Running swift test --filter Reconnect")),
            row(
                entry(
                    "fx-carrying", "Backtest the pricing model", project: "acme-pricing",
                    on: "workshop", model: "claude-opus-5", effort: "high", ago: 4 * minute,
                    carrying: BackgroundWork(
                        tasks: 1, task: "cargo test --release", since: now.addingTimeInterval(-4 * minute))),
                pinned: true),
            row(
                entry(
                    "fx-pinned", "Dark mode for the settings screen", project: "pulse-ios", on: "studio",
                    model: "claude-opus-5", effort: "ultracode", ago: 54 * minute,
                    said:
                        "Dark mode is in for Settings: every row reads from the palette now, and the two hard-coded greys are gone."),
                unread: true, pinned: true),
            row(
                entry(
                    "fx-saved-1", "Migrate CI to self-hosted runners", project: "pulse-infra",
                    on: "studio", model: "claude-opus-5", effort: "ultracode", ago: 6 * day),
                saved: true),
            row(
                entry(
                    "fx-saved-2", "Hunt the memory leak in ImagePipeline", project: "acme-ios",
                    on: "workshop", model: "claude-opus-5", effort: "xhigh", ago: 19 * day),
                saved: true),
            row(
                entry(
                    "fx-said", "Redesign the composer and its send button", project: "pulse-ios",
                    on: "studio", model: "claude-opus-5", effort: "ultracode", ago: 41 * minute,
                    said: "Three directions are on the board; the docked one keeps Send under the thumb."),
                unread: true),
            row(
                entry(
                    "fx-read-1", "Write the v2.3 release notes", project: "acme-api", on: "studio",
                    model: "claude-fable-5", effort: "ultracode", ago: hour)),
            row(
                entry(
                    "fx-failed", "Ship the pricing page A/B test", project: "acme-web", on: "studio",
                    model: "claude-opus-5", effort: "high", ago: hour + 4 * minute),
                unread: true, presence: .failed),
            row(
                entry(
                    "fx-mute", "Explain the auth token refresh flow", project: "pulse-server",
                    on: "studio", model: "claude-opus-5", effort: "xhigh", ago: hour + 20 * minute),
                unread: true),
            row(
                entry(
                    "fx-read-2", "Refactor the auth module to async/await", project: "acme-api",
                    on: "studio", model: "claude-opus-5", effort: "ultracode", ago: 2 * hour)),
            row(
                entry(
                    "fx-away", "What is eating my GPU memory?", project: "demo", on: "workshop",
                    model: "claude-sonnet-5", effort: "high", ago: 3 * hour),
                unreachable: true),
            row(
                entry(
                    "fx-yesterday", "Add the jitter bound test", project: "acme-api", on: "studio",
                    model: "claude-opus-5", effort: "xhigh", ago: 26 * hour)),
            row(
                entry(
                    "fx-week", "Benchmark the new tokenizer", project: "acme-ml", on: "workshop",
                    model: "claude-opus-5", effort: "high", ago: 4 * day)),
        ]
    }
}
