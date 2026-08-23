#if DEBUG
import CodingAgentKit
import TailscodeCore
import UIKit

/// DEBUG-only harness for looking at the cut-off turn's card without a bridge that has to be
/// killed mid-answer to produce one. Launched via `--interrupted-preview`, it stacks the card in
/// every state it can be in — undecided, each press in flight, and picked back up — plus the
/// sentence a refused press is reported in, so the whole surface can be screenshot from a
/// simulator. The buttons are live: pressing one proves the acknowledgement is immediate.
@MainActor
final class InterruptedTurnPreviewViewController: UIViewController {
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

        guard let waiting = InterruptedTurnReading.read(Self.record) else { return }
        add("undecided — press either button", card(waiting))
        add("pick it back up, in flight", card(InterruptedTurnReading.pressed(waiting, .pickUp)))
        add("let it go, in flight", card(InterruptedTurnReading.pressed(waiting, .letGo)))
        if let resumed = InterruptedTurnReading.read(Self.resumedRecord) {
            add("the server says it took it", card(resumed))
        }
        add("what a refused press reports", refusal())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let args = CommandLine.arguments
        if args.contains("--interrupted-preview-press") { pressTheUndecidedCard() }
        if args.contains("--interrupted-preview-tail") { scrollToTail() }
    }

    /// Presses the live card the way a finger would, so what is screenshot is the acknowledgement
    /// the cell actually draws rather than a card composed in this state to begin with.
    private func pressTheUndecidedCard() {
        guard let cell = stack.arrangedSubviews.compactMap({ $0 as? InterruptedTurnCell }).first,
            let button = Self.firstButton(in: cell)
        else { return }
        button.sendActions(for: .touchUpInside)
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        for child in view.subviews {
            if let button = child as? UIButton { return button }
            if let found = firstButton(in: child) { return found }
        }
        return nil
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

    /// A cell drawn outside a collection view, which needs its content pinned to it by hand — a
    /// cell's own height otherwise comes from a layout that is not here to give it one.
    private func card(_ turn: InterruptedTurn) -> UIView {
        let cell = InterruptedTurnCell(frame: .zero)
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.contentView.topAnchor.constraint(equalTo: cell.topAnchor),
            cell.contentView.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            cell.contentView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            cell.contentView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        cell.configure(turn, onResume: {}, onDismiss: {})
        return cell
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

    /// The refused press as the chat reports it, drawn in the same toast the chat uses, so two
    /// whole sentences are seen wrapping rather than assumed to.
    private func refusal() -> UIView {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        let toast = ToastView(
            message: InterruptedTurnReading.refusal(
                for: AgentError.http(status: 409, body: Self.conflict)))
        toast.flash(in: holder, above: holder.bottomAnchor, duration: 6_000)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 120)
        ])
        return holder
    }

    private static let started = Date().addingTimeInterval(-940)
    private static let detected = Date().addingTimeInterval(-180)

    private static let record = TurnInterruption(
        turnID: "preview", prompt: "port the toggles to the settings screen",
        startedAt: started, detectedAt: detected,
        progress: TurnInterruption.Progress(
            toolCount: 7, lastTool: "Edit",
            filesTouched: [
                "/Users/demo/dev/pulse-ios/Theme.swift", "/Users/demo/dev/pulse-ios/Row.swift",
            ],
            commands: ["swift build"], partialAnswer: "I have started by moving the two switches"),
        queued: ["and then the mac"])

    private static let resumedRecord = TurnInterruption(
        turnID: "preview", prompt: "port the toggles to the settings screen",
        startedAt: started, detectedAt: detected,
        progress: record.progress, queued: record.queued, resumedAt: Date())

    private static let conflict = """
        {"error":"Nothing to pick up — no turn in this session was interrupted.",\
        "reason":"nothing_interrupted","interruption":null}
        """
}
#endif
