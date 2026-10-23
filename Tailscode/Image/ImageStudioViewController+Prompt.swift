import TailscodeCore
import UIKit

extension ImageStudioViewController {
    func layoutStartFrom() {
        startFromRing.frame = startFrom.bounds
        startFromRing.path = UIBezierPath(
            roundedRect: startFrom.bounds.insetBy(dx: 1, dy: 1), cornerRadius: Theme.Radius.control
        ).cgPath
        startFromRing.strokeColor = Theme.Color.separator.cgColor
    }

    func updateStartFrom() {
        let holding = slot.references.last
        let count = slot.references.count
        let thumb = holding.flatMap { reference -> UIImage? in
            if let kept = reference.kept, let tile = library.cachedThumbnail(of: kept) { return tile }
            guard let data = FileManager.default.contents(atPath: reference.path),
                let image = UIImage(data: data)
            else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        }
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .fixed
        config.background.cornerRadius = Theme.Radius.control
        config.background.backgroundColor = Theme.Color.codeBackground
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        if let thumb {
            config.background.image = thumb
            config.background.imageContentMode = .scaleAspectFill
            config.image = nil
            config.title = nil
            if count > 1 {
                var badge = AttributedString("\(count)")
                badge.font = Theme.Ramp.font(.badge)
                badge.foregroundColor = Theme.Color.onAccent
                config.attributedTitle = badge
                config.background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.3)
            }
        } else {
            config.image = UIImage(
                systemName: "photo.badge.plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            var caption = AttributedString(ForgeField.frame.label)
            caption.font = Theme.Font.capped(.caption2, maximum: 11)
            config.attributedTitle = caption
            config.baseForegroundColor = Theme.Color.secondaryLabel
        }
        startFrom.configuration = config
        startFromRing.isHidden = thumb != nil
        startFrom.isEnabled = !slot.isBusy
        startFrom.titleLabel?.adjustsFontSizeToFitWidth = true
        startFrom.titleLabel?.minimumScaleFactor = 0.6
        startFrom.menu = intake.menu(references: slot.references)
        startFrom.accessibilityLabel = holding.map(ImageGenWords.referenceHint) ?? ImageGenWords.attachTitle
        startFrom.accessibilityHint = count == 0 ? nil : ImageGenWords.attachMoreHint
    }

    func updateEnhance() {
        enhanceControl.apply(
            busy: studio.enhancing, undoing: beforeEnhance != nil,
            enabled: !slot.isBusy, helper: studio.helper)
    }

    /// Press once to have the brief written out, press again to get your own sentence back.
    func enhancePressed() {
        Theme.Haptics.tap()
        if let original = beforeEnhance {
            setPrompt(original)
            studio.rememberDraft(original)
            beforeEnhance = nil
            updateEnhance()
            return
        }
        let brief = (promptView.text ?? "").trimmed()
        guard !brief.isEmpty, !studio.enhancing else { return }
        studio.enhance(brief) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let written):
                self.beforeEnhance = brief
                self.studio.followWriter(aspect: written.1)
                self.setPrompt(written.0)
                self.studio.rememberDraft(written.0)
                if let helper = self.studio.helper {
                    self.notice(ImageGenWords.enhancedNotice(helper))
                }
                Theme.Haptics.success()
            case .failure(let failure):
                self.notice(
                    self.studio.helper == nil ? ImageGenWords.enhanceMissing : failure.reason)
                Theme.Haptics.warning()
            }
            self.updateEnhance()
            self.updateChips()
        }
        updateEnhance()
    }

    /// A small box for the avoid list, because a phone has nowhere to keep a second field open
    /// under the composer without taking the picture's room.
    func presentAvoid() {
        let alert = UIAlertController(
            title: ImageGenWords.avoidTitle, message: ImageGenWords.avoidHint,
            preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.slot.negative
            field.placeholder = ImageGenWords.avoidPlaceholder
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: ImageGenWords.cancelTitle, style: .cancel))
        alert.addAction(
            UIAlertAction(title: ImageGenWords.applyTitle, style: .default) { [weak self] _ in
                let words = alert.textFields?.first?.text ?? ""
                self?.studio.setNegative(words)
                self?.updateChips()
            })
        present(alert, animated: true)
    }

    /// One control, two meanings, and it says which it is: a render out is stopped from the same
    /// place it was started, because a person who wants it to end should not have to find another
    /// button to end it with.
    func updateRenderButton() {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.cornerStyle = .large
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        config.image = UIImage(
            systemName: studio.isPainting ? "stop.fill" : ImageGenEntryPoint.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        var title = AttributedString(
            studio.isPainting ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode))
        title.font = Theme.Font.capped(.caption1, maximum: 14)
        if !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            config.attributedTitle = title
        }
        renderButton.configuration = config
        renderButton.titleLabel?.adjustsFontSizeToFitWidth = true
        renderButton.titleLabel?.minimumScaleFactor = 0.6
        renderButton.isEnabled =
            studio.isPainting || !(promptView.text ?? "").trimmed().isEmpty
        renderButton.accessibilityLabel = studio.isPainting
            ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode)
    }

    /// A long brief is minutes of typing or a whole rewrite, and emptying it by selecting and
    /// deleting is a fight with a loupe. The mark sits inside the box where the words are, is
    /// there only while there is something to clear, and leaves the keyboard up so the next
    /// brief starts at once.
    func configureClearButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        config.baseForegroundColor = Theme.Color.tertiaryLabel
        clearButton.configuration = config
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.accessibilityLabel = String(localized: "Clear")
        clearButton.alpha = 0
        clearButton.isUserInteractionEnabled = false
        clearButton.addAction(UIAction { [weak self] _ in self?.clearPrompt() }, for: .touchUpInside)
    }

    private func clearPrompt() {
        Theme.Haptics.tap()
        enhanceOverlay?.requestDismiss()
        beforeEnhance = nil
        setPrompt("")
        studio.rememberDraft("")
        updateChips()
        updateEnhance()
        promptView.becomeFirstResponder()
    }

    private func updateClearButton() {
        let visible = !(promptView.text ?? "").isEmpty
        clearButton.isUserInteractionEnabled = visible
        guard clearButton.alpha != (visible ? 1 : 0) else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
            self.clearButton.alpha = visible ? 1 : 0
        }
    }

    func updatePlaceholder() {
        updateClearButton()
        placeholder.isHidden = !(promptView.text ?? "").isEmpty
        placeholder.attributedText = NSAttributedString(
            string: slot.hint,
            attributes: Theme.Ramp.attributes(.composer, color: Theme.Color.tertiaryLabel))
    }

    /// Words put in the box by anything other than a keystroke still owe the box its own three
    /// answers: whether the hint is still showing, whether the render control is live, and how
    /// tall the box has to be to hold them.
    func setPrompt(_ words: String) {
        promptView.text = words
        updatePlaceholder()
        updateRenderButton()
        grow()
    }

    /// The box is as tall as what is in it, from two lines to six, after which it scrolls — a
    /// prompt worth two sentences must not be typed into a slot that shows one line of it. The
    /// Enhance control sits over its trailing foot, and the words flow around it rather than under.
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

    /// Keeps the words out of the rectangle the Enhance control covers at a given box height.
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

    static let enhanceMargin: CGFloat = 5

    /// Holding the button that makes the picture offers the brief written out first — the chat's
    /// hold-Send, answered by the machine that paints rather than by a coding model. Nothing is
    /// replaced until the card is taken, and taking it leaves the undo behind.
    @objc func renderHeld(_ gesture: UILongPressGestureRecognizer) {
        let words = (promptView.text ?? "").trimmed()
        guard gesture.state == .began, !studio.isPainting, !words.isEmpty else { return }
        Theme.Haptics.tap()
        enhancement.requestNow(for: words)
        presentEnhanceOverlay(original: words)
    }

    private func presentEnhanceOverlay(original: String) {
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

extension ImageStudioViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        enhanceOverlay?.requestDismiss()
        updatePlaceholder()
        updateRenderButton()
        updateChrome()
        updateChips()
        grow()
    }
}

extension ImageStudioViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        let before = (promptView.text ?? "").trimmed()
        Theme.Haptics.success()
        overlay.requestDismiss()
        studio.followWriter(aspect: prompt.aspect)
        setPrompt(prompt.text)
        studio.rememberDraft(prompt.text)
        beforeEnhance = before
        if let helper = studio.helper { notice(ImageGenWords.enhancedNotice(helper)) }
        updateChips()
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
