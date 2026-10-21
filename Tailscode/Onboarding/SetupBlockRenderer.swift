import CodingAgentKit
import TailscodeCore
import UIKit

/// Draws the blocks of a `FirstRunPlan` and invents no sentence. A block that did not change keeps
/// its view, so a diagnosis is not announced again and a keystroke never rebuilds the field being
/// typed in; the two views a person types into outlive every plan.
@MainActor
final class SetupBlockRenderer {
    struct Actions {
        var way: (FirstRunPlan.Way.Kind) -> Void
        var paste: (String) -> Void
        var type: (String) -> Void
        var useClipboard: () -> Void
        var selectAgent: (AgentType) -> Void
        var copied: () -> Void
        var share: (String, UIView) -> Void
        var password: (String) -> Void
        var submit: () -> Void
        var fix: (ConnectDiagnosis.Fix) -> Void
        var signIn: () -> Void
        var connectAnyway: () -> Void
        var openTailscale: () -> Void
        var openLink: (String) -> Void
        var reveal: (UIView) -> Void
    }

    private struct Entry {
        let block: FirstRunPlan.Block
        let view: UIView
    }

    let pasteBlock = PasteBlockView()
    let passwordBlock = PasswordBlockView()
    private let actions: Actions
    private var cache: [String: [Entry]] = [:]

    init(actions: Actions) {
        self.actions = actions
        pasteBlock.onPaste = actions.paste
        pasteBlock.onType = actions.type
        pasteBlock.onOffer = actions.useClipboard
        pasteBlock.onSubmit = actions.submit
        passwordBlock.onChange = actions.password
        passwordBlock.onSubmit = actions.submit
    }

    func views(for blocks: [FirstRunPlan.Block], slot: String) -> [UIView] {
        var previous = cache[slot] ?? []
        var next: [Entry] = []
        for block in blocks {
            if let index = previous.firstIndex(where: { $0.block == block }) {
                next.append(previous.remove(at: index))
                continue
            }
            switch block {
            case .paste(let paste):
                pasteBlock.apply(paste)
                previous.removeAll { $0.view === pasteBlock }
                next.append(Entry(block: block, view: pasteBlock))
            case .password(let password):
                passwordBlock.apply(password)
                previous.removeAll { $0.view === passwordBlock }
                next.append(Entry(block: block, view: passwordBlock))
            default:
                next.append(Entry(block: block, view: make(block)))
            }
        }
        cache[slot] = next
        return next.map(\.view)
    }

    private func make(_ block: FirstRunPlan.Block) -> UIView {
        switch block {
        case .note(let text): return SetupLink.label(text)
        case .ways(let ways): return waysView(ways)
        case .paste, .password: return UIView()
        case .agents(let choices): return agentsView(choices)
        case .command(let card): return commandView(card)
        case .waiting(let text): return WaitingLineView(text: text)
        case .diagnosis(let diagnosis): return diagnosisView(diagnosis)
        case .link(let card):
            return LinkCardView(card: card, onConnectAnyway: actions.connectAnyway)
        case .signIn(let card): return signInView(card)
        case .remedy: return remedyView()
        }
    }

    private func waysView(_ ways: [FirstRunPlan.Way]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        for way in ways {
            let row = SetupWayRow(way: way)
            row.addAction(
                UIAction { [actions] _ in
                    Theme.Haptics.tap()
                    actions.way(way.kind)
                }, for: .touchUpInside)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func agentsView(_ choices: [FirstRunPlan.AgentChoice]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        for choice in choices {
            let card = AgentChoiceCard(
                backend: choice.agent, title: choice.title, detail: choice.detail)
            card.isSelected = choice.isSelected
            card.addAction(
                UIAction { [actions] _ in
                    Theme.Haptics.selection()
                    actions.selectAgent(choice.agent)
                }, for: .touchUpInside)
            stack.addArrangedSubview(card)
        }
        return stack
    }

    private func commandView(_ card: FirstRunPlan.CommandCard) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.addArrangedSubview(
            SetupLink.label(card.title, role: .panelLabel, color: Theme.Color.label))
        stack.addArrangedSubview(SetupLink.label(card.detail))
        let block = CommandBlockView(
            command: card.command, copyLabel: card.copyTitle, offersShare: false)
        block.onCopy = actions.copied
        stack.addArrangedSubview(block)
        if let sendTitle = card.sendTitle {
            let send = SetupLink.button(title: sendTitle, symbol: "square.and.arrow.up")
            send.addAction(
                UIAction { [actions, weak send] _ in
                    guard let send else { return }
                    Theme.Haptics.tap()
                    actions.share(card.sharedMessage, send)
                }, for: .touchUpInside)
            stack.addArrangedSubview(send)
        }
        if let note = card.note {
            stack.addArrangedSubview(
                SetupLink.label(note, role: .panelFootnote, color: Theme.Color.secondaryLabel))
        }
        return stack
    }

    private func diagnosisView(_ diagnosis: ConnectDiagnosis) -> UIView {
        let card = DiagnosisCardView()
        card.onAction = { [actions] in actions.fix(diagnosis.fix) }
        card.show(
            diagnosis,
            tint: diagnosis.fix == .revealPassword ? Theme.Color.warning : Theme.Color.danger)
        actions.reveal(card)
        return card
    }

    private func signInView(_ sign: FirstRunPlan.SignInCard) -> UIView {
        let card = DiagnosisCardView()
        card.onAction = { [actions] in actions.signIn() }
        card.show(
            ConnectDiagnosis(
                symbol: "person.crop.circle.badge.exclamationmark", title: sign.title,
                detail: sign.detail, fix: .none, actionTitle: sign.action),
            tint: Theme.Color.warning)
        actions.reveal(card)
        return card
    }

    private func remedyView() -> UIView {
        var openConfig = Theme.Glass.buttonConfiguration()
        openConfig.title = Localized.text("Open Tailscale")
        openConfig.image = UIImage(
            systemName: "arrow.up.forward.app",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        openConfig.imagePadding = Theme.Spacing.xs
        openConfig.baseForegroundColor = Theme.Color.label
        openConfig.contentInsets = NSDirectionalEdgeInsets(
            top: 10, leading: 14, bottom: 10, trailing: 14)
        let open = UIButton(configuration: openConfig)
        open.addAction(
            UIAction { [actions] _ in
                Theme.Haptics.tap()
                actions.openTailscale()
            }, for: .touchUpInside)
        let about = SetupLink.button(title: Localized.text("What is Tailscale?"))
        about.addAction(
            UIAction { [actions] _ in actions.openLink(SetupHandoff.tailscaleDownloadURL) },
            for: .touchUpInside)
        return AdaptiveRow([open, about])
    }
}
