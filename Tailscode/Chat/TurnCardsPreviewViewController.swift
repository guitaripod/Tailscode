#if DEBUG
import CodingAgentKit
import TailscodeCore
import UIKit

/// DEBUG-only harness for the three cards this build added beside the interrupted-turn card, none
/// of which need a live bridge to look at: a turn waiting on its provider, a conversation wound
/// back, and the quiet notes the server writes between turns. Launched via `--turn-cards-preview`,
/// it stacks every state each card can be in so the whole surface can be screenshot from a
/// simulator, labelled the way `InterruptedTurnPreviewViewController` labels its own states.
@MainActor
final class TurnCardsPreviewViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background

        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        add("retry, with a remedy and link", retryCard(Self.retryWithRemedy))
        add("retry, no remedy offered", retryCard(Self.retryWithoutRemedy))
        add("retry, a long multi-line reason", retryCard(Self.retryLongReason))
        add("retry, no attempt scheduled yet", retryCard(Self.retryUnscheduled))
        add("revert, two files put back", revertCard(Self.revertTwoFiles, setAside: Self.setAsideTwo))
        add("revert, no files changed", revertCard(Self.revertNoFiles, setAside: Self.setAsideOne))
        add(
            "revert, nine files, so \"more\" shows",
            revertCard(Self.revertNineFiles, setAside: Self.setAsideTwo))
        add(
            "revert, restoring",
            revertCard(Self.revertTwoFiles, setAside: Self.setAsideTwo, restoring: true))
        add("note, quiet tone, background work", noteCard(Self.workFinishedNote))
        add("note, quiet tone, model switch", noteCard(Self.modelSwitchNote))
        add("note, attention tone", noteCard(Self.resumedNote))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if CommandLine.arguments.contains("--turn-cards-preview-tail") { scrollToTail() }
    }

    private func scrollToTail() {
        view.layoutIfNeeded()
        let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    private func add(_ caption: String, _ view: UIView) {
        stack.addArrangedSubview(label(caption))
        stack.addArrangedSubview(view)
        stack.setCustomSpacing(Theme.Spacing.l, after: view)
    }

    private func label(_ text: String) -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.rowNote)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.text = text.uppercased()
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            label.leadingAnchor.constraint(
                equalTo: holder.leadingAnchor, constant: Theme.Spacing.l),
            label.trailingAnchor.constraint(
                equalTo: holder.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return holder
    }

    /// A cell drawn outside a collection view needs its content pinned to it by hand, the same way
    /// the interrupted-turn preview hosts its own cell.
    private func host(_ cell: UICollectionViewCell) -> UIView {
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.contentView.topAnchor.constraint(equalTo: cell.topAnchor),
            cell.contentView.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            cell.contentView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            cell.contentView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        return cell
    }

    private func retryCard(_ retry: TurnRetry) -> UIView {
        let cell = ProviderRetryCell(frame: .zero)
        cell.configure(retry) { url in UIApplication.shared.open(url) }
        return host(cell)
    }

    private func revertCard(_ revert: SessionRevert, setAside: [ChatMessage], restoring: Bool = false)
        -> UIView
    {
        let cell = RevertBannerCell(frame: .zero)
        guard let banner = RevertReading.read(revert, setAside: setAside) else { return host(cell) }
        cell.configure(banner, restoring: restoring) {}
        return host(cell)
    }

    private func noteCard(_ note: TranscriptNote) -> UIView {
        let cell = TranscriptNoteCell(frame: .zero)
        cell.configure(TranscriptNoteReading.read(note, modelName: Self.previewModelName))
        return host(cell)
    }

    private static func previewModelName(_ selection: ModelSelection) -> String? {
        switch selection.modelID {
        case "sonnet": return "Sonnet 5"
        case "gpt-5.1-codex": return "GPT-5.1 Codex"
        default: return nil
        }
    }

    private static let retryWithRemedy = TurnRetry(
        attempt: 3, reason: "You have exceeded your current quota. Please check your plan and billing details.",
        nextAttemptAt: Date().addingTimeInterval(75),
        remedy: TurnRetry.Remedy(
            title: "Add credit", message: "Raise your spending limit to keep going without a wait.",
            label: "Manage billing", link: "https://console.example.com/billing"))

    private static let retryWithoutRemedy = TurnRetry(
        attempt: 1, reason: "The model is temporarily overloaded.",
        nextAttemptAt: Date().addingTimeInterval(12))

    private static let retryLongReason = TurnRetry(
        attempt: 5,
        reason: """
            The upstream provider returned a 503 while the model was warming a new region. This can \
            happen after a deploy on their side and usually clears within a few minutes; the server \
            will keep asking on the schedule below without anyone having to do anything about it.
            """,
        nextAttemptAt: Date().addingTimeInterval(190))

    private static let retryUnscheduled = TurnRetry(
        attempt: 2, reason: "Rate limited by the provider.", nextAttemptAt: nil)

    private static func files(_ count: Int) -> [SessionRevert.File] {
        let changes: [SessionRevert.File.Change] = [.modified, .added, .deleted]
        return (0..<count).map { index in
            SessionRevert.File(
                path: "internal/auth/file\(index).go",
                change: changes[index % changes.count],
                additions: 4 + index, deletions: index)
        }
    }

    private static let revertTwoFiles = SessionRevert(
        messageID: "preview-two",
        files: [
            SessionRevert.File(
                path: "internal/auth/session.go", change: .modified, additions: 122, deletions: 47),
            SessionRevert.File(
                path: "internal/auth/token.go", change: .modified, additions: 18, deletions: 9),
        ])

    private static let revertNoFiles = SessionRevert(messageID: "preview-zero", files: [])

    private static let revertNineFiles = SessionRevert(messageID: "preview-nine", files: files(9))

    private static let setAsideOne = [userMessage("port the toggles to the settings screen")]
    private static let setAsideTwo = [
        userMessage("Refactor the auth module to async/await and add a test."),
        assistantMessage("I moved session.go and token.go over and added the missing test."),
    ]

    private static func userMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            id: "preview-user", role: .user, agentType: .openCode,
            parts: [MessagePart(id: "preview-user/text", kind: .text(text))],
            createdAt: Date().addingTimeInterval(-300))
    }

    private static func assistantMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            id: "preview-assistant", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "preview-assistant/text", kind: .text(text))],
            createdAt: Date().addingTimeInterval(-200))
    }

    private static let workFinishedNote = TranscriptNote(
        .workFinished("go test ./internal/auth/...", work: .command, outcome: .completed))

    private static let modelSwitchNote = TranscriptNote(
        .model(
            ModelSelection(providerID: "anthropic", modelID: "gpt-5.1-codex"), effort: "high",
            previous: ModelSelection(providerID: "anthropic", modelID: "sonnet")))

    private static let resumedNote = TranscriptNote(.resumedAfterRestart)
}
#endif
