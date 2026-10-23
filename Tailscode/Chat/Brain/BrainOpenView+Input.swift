import TailscodeCore
import UIKit

extension BrainOpenView {
    /// Three rotors walk the head's steps: the notes the agent said, the errors it hit (fixed and
    /// failed), and every step, each landing on the step's own node and selecting it.
    func installRotors() {
        func rotor(_ name: String, _ keep: @escaping (NeuralStepList.Row) -> Bool) -> UIAccessibilityCustomRotor {
            UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
                guard let self, let model = self.browseModel else { return nil }
                let rows = model.stepList.visibleRows.filter(keep)
                guard !rows.isEmpty else { return nil }
                let current = self.stage.stepID(of: predicate.currentItem.targetElement)
                    ?? model.pinnedStep
                let at = current.flatMap { id in model.stepList.row(id: id)?.index } ?? -1
                let forward = predicate.searchDirection == .next
                let next = forward
                    ? rows.first { $0.index > at } ?? rows.first
                    : rows.last { $0.index < at } ?? rows.last
                guard let next, let element = self.stage.element(forStep: next.id) else { return nil }
                self.browse(.click(next.id, double: false))
                return UIAccessibilityCustomRotorItemResult(targetElement: element, targetRange: nil)
            }
        }
        accessibilityCustomRotors = [
            rotor(Localized.text("Said")) { $0.isSaid },
            rotor(Localized.text("Errors")) { $0.verdict == .fixed || $0.verdict == .failed || $0.verdict == .tryingAgain },
            rotor(Localized.text("Steps")) { _ in true },
        ]
    }

    /// A hardware key as the reducer reads it.
    static func map(_ key: UIKey) -> (key: NeuralBrowse.Key, modifiers: NeuralBrowse.Modifiers)? {
        var modifiers: NeuralBrowse.Modifiers = []
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        switch key.keyCode {
        case .keyboardUpArrow: return (.up, modifiers)
        case .keyboardDownArrow: return (.down, modifiers)
        case .keyboardLeftArrow: return (.left, modifiers)
        case .keyboardRightArrow: return (.right, modifiers)
        case .keyboardPageUp: return (.pageUp, modifiers)
        case .keyboardPageDown: return (.pageDown, modifiers)
        case .keyboardHome: return (.home, modifiers)
        case .keyboardEnd: return (.end, modifiers)
        case .keyboardReturnOrEnter, .keypadEnter: return (.enter, modifiers)
        case .keyboardSpacebar: return (.space, modifiers)
        case .keyboardEscape: return (.escape, modifiers)
        case .keyboardTab: return (.tab, modifiers)
        default:
            guard let character = key.characters.first, key.characters.count == 1 else { return nil }
            return (.character(character), modifiers)
        }
    }

    /// Opens the account in a sheet over the transcript, at a step when there is one. The phone's
    /// open Megatron holds no scroller of its own: this is where a long account is read.
    func presentReader(focus: String?) {
        guard metrics.isPhone, reader == nil, let controller = nearestViewController(),
            controller.presentedViewController == nil
        else { return }
        let sheet = BrainReaderViewController(account: account, focus: focus ?? browseModel?.pinnedStep)
        sheet.onLayout = { [weak self] width in self?.configureReader(width: width) }
        sheet.onDismiss = { [weak self] in self?.readerDismissed() }
        reader = sheet
        controller.present(sheet, animated: true)
    }

    /// The account is set for the sheet's own width, which is its page rather than the row's.
    private func configureReader(width: Double) {
        guard let store else { return }
        let sheetMetrics = NeuralStageMetrics.make(
            width: min(width, NeuralStageMetrics.splitBreakpoint - 1), density: metrics.density,
            input: .touch, zonesWithSteps: max(browseModel?.stepList.zoneChips.count ?? 6, 1))
        account.configure(metrics: sheetMetrics)
        lastFilterKey = ""
        account.refresh(prompt: store.promptText(for: turnID), answer: store.answerText(for: turnID))
    }

    private func readerDismissed() {
        reader = nil
        madeAccount?.removeFromSuperview()
    }

    /// The sheet goes with the row that opened it: a turn closed, a cell reused.
    func dismissReader() {
        guard let reader else { return }
        self.reader = nil
        reader.dismiss(animated: false)
        madeAccount?.removeFromSuperview()
    }

    func showLegend() {
        guard legend == nil, let controller = nearestViewController() else { return }
        let page = BrainLegendViewController()
        page.onDismiss = { [weak self] in
            self?.legend = nil
            self?.store?.mutate(self?.turnID ?? "") { $0.setBrowseLegend(false) }
        }
        page.modalPresentationStyle = .popover
        if let popover = page.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
            popover.delegate = page
        }
        legend = page
        controller.present(page, animated: true)
    }

    func hideLegend() {
        legend?.dismiss(animated: true)
        legend = nil
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
