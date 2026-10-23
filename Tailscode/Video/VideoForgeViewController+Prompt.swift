import TailscodeCore
import UIKit

extension VideoForgeViewController {
    func syncPrompt() {
        let words = board.recipe.prompt
        if !promptView.isFirstResponder, promptView.text != words {
            beforeEnhance = nil
            setPrompt(words)
        } else {
            updatePlaceholder()
        }
    }

    func setPrompt(_ words: String) {
        promptView.text = words
        updatePlaceholder()
        updateRenderButton()
        grow()
    }

    private func updatePlaceholder() {
        let visible = !(promptView.text ?? "").isEmpty
        clearButton.isUserInteractionEnabled = visible
        if clearButton.alpha != (visible ? 1 : 0) {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
                self.clearButton.alpha = visible ? 1 : 0
            }
        }
        placeholder.isHidden = visible
        placeholder.attributedText = NSAttributedString(
            string: board.prompt,
            attributes: Theme.Ramp.attributes(.composer, color: Theme.Color.tertiaryLabel))
        promptView.isEditable = !board.isBusy
        promptView.alpha = board.isBusy ? 0.6 : 1
    }

    func clearPrompt() {
        Theme.Haptics.tap()
        enhanceOverlay?.requestDismiss()
        beforeEnhance = nil
        setPrompt("")
        runner.describe("")
        promptView.becomeFirstResponder()
    }

    func grow() {
        guard promptView.bounds.width > 0, !growing else { return }
        growing = true
        defer { growing = false }
        let width = promptView.bounds.width
        var height = promptHeight.constant
        for _ in 0..<3 {
            flow(around: height)
            let fitted = promptView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            let next = min(max(Self.promptMinimum, fitted.height), Self.promptMaximum)
            guard abs(next - height) > 0.5 else { break }
            height = next
        }
        flow(around: height)
        guard abs(height - promptHeight.constant) > 0.5 else { return }
        promptHeight.constant = height
        view.setNeedsLayout()
    }

    private func flow(around height: CGFloat) {
        let control = enhanceControl.size
        let inset = promptView.textContainerInset
        let width = promptView.bounds.width
        let rect = CGRect(
            x: width - Self.enhanceMargin - control.width - 4 - inset.left,
            y: height - Self.enhanceMargin - control.height - 1 - inset.top,
            width: control.width + 40, height: control.height + 200)
        promptView.textContainer.exclusionPaths = [UIBezierPath(rect: rect)]
    }

    func updateEnhance() {
        enhanceControl.apply(
            busy: runner.enhancing, undoing: beforeEnhance != nil, enabled: !board.isBusy,
            helper: runner.helper)
    }

    /// Press once to have the words written out as the caption of the clip, press again to get your
    /// own sentence back. Nothing is rendered on the person's behalf.
    func enhancePressed() {
        Theme.Haptics.tap()
        if let original = beforeEnhance {
            setPrompt(original)
            runner.describe(original)
            beforeEnhance = nil
            updateEnhance()
            return
        }
        let brief = (promptView.text ?? "").trimmed()
        guard !brief.isEmpty, !runner.enhancing else { return }
        runner.enhance(brief) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let written):
                self.beforeEnhance = brief
                self.runner.followWriter(aspect: written.1)
                self.setPrompt(written.0)
                self.runner.describe(written.0)
                if let helper = self.runner.helper {
                    self.notice(ImageGenWords.enhancedNotice(helper))
                }
                Theme.Haptics.success()
            case .failure(let failure):
                self.notice(self.runner.helper == nil ? ImageGenWords.enhanceMissing : failure.reason)
                Theme.Haptics.warning()
            }
            self.updateEnhance()
        }
        updateEnhance()
    }

    /// Holding the button that renders offers the words written out first — the same card the
    /// image studio and the chat's hold-Send use, answered by the helper on the machine with the
    /// card. Nothing is replaced until the card is taken, and taking it leaves the undo behind.
    @objc func renderHeld(_ gesture: UILongPressGestureRecognizer) {
        let words = (promptView.text ?? "").trimmed()
        guard gesture.state == .began, !runner.isRendering, !words.isEmpty else { return }
        Theme.Haptics.tap()
        enhancement.requestNow(for: words)
        presentEnhanceOverlay(original: words)
    }

    func presentEnhanceOverlay(original: String) {
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: dock.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let origin = renderButton.convert(
            CGPoint(x: renderButton.bounds.midX, y: renderButton.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
    }
}

extension VideoForgeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        enhanceOverlay?.requestDismiss()
        runner.describe(textView.text ?? "")
        updatePlaceholder()
        updateRenderButton()
        grow()
    }
}

extension VideoForgeViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        let before = (promptView.text ?? "").trimmed()
        Theme.Haptics.success()
        overlay.requestDismiss()
        runner.followWriter(aspect: prompt.aspect)
        setPrompt(prompt.text)
        runner.describe(prompt.text)
        beforeEnhance = before
        if let helper = runner.helper { notice(ImageGenWords.enhancedNotice(helper)) }
        updateEnhance()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
    }
}
