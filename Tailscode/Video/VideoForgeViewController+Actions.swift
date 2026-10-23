import TailscodeCore
import UIKit

extension VideoForgeViewController {
    /// One control, two meanings, and it says which it is: a render out is stopped from the same
    /// place it was started. A renderer that was never set up gets the setup instead of a render,
    /// and a clip waiting to be continued says that is what the press will do.
    func updateRenderButton() {
        let rendering = runner.isRendering
        let continuing = !rendering && runner.endpoint != nil && board.continuing != nil
        let words =
            rendering
            ? ImageGenWords.stopTitle
            : (runner.endpoint == nil
                ? ForgeSetup.title
                : (board.blocker != nil
                    ? board.renderCall : (continuing ? ForgeWords.extendTitle : Localized.text("Render"))))
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.cornerStyle = .large
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        config.image = UIImage(
            systemName: rendering ? "stop.fill" : (continuing ? "forward.end.fill" : ForgeEntryPoint.symbol),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        var title = AttributedString(words)
        title.font = Theme.Font.capped(.caption1, maximum: 14)
        if !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            config.attributedTitle = title
        }
        renderButton.configuration = config
        renderButton.titleLabel?.adjustsFontSizeToFitWidth = true
        renderButton.titleLabel?.minimumScaleFactor = 0.6
        renderButton.isEnabled =
            rendering || runner.endpoint == nil || !(promptView.text ?? "").trimmed().isEmpty
        renderButton.accessibilityLabel = words
    }

    func renderTapped() {
        guard !runner.isRendering else {
            runner.stop()
            return
        }
        guard runner.endpoint != nil else { return openRenderer() }
        guard board.blocker == nil else { return openChecklist() }
        guard board.recipe.isRenderable else {
            promptView.becomeFirstResponder()
            return
        }
        if repeatsKeptClip { runner.pick(.seed, id: "reroll") }
        startRender(board.recipe)
    }

    /// Whether pressing Render would ask for a clip the shelf already holds, word for word and
    /// seed for seed: the same seed on the same words makes the same clip, a few minutes of the
    /// machine's card spent on a copy. Never so for settings taken back on purpose — reusing a
    /// clip's seed is how the same clip is asked for again.
    private var repeatsKeptClip: Bool {
        !seedReused && board.history.contains { $0.isPlayable && $0.recipe == board.recipe }
    }

    private func startRender(_ recipe: ForgeRecipe) {
        view.endEditing(true)
        Theme.Haptics.send()
        sketchImage = nil
        sketchFrame = nil
        beforeEnhance = nil
        seedReused = false
        releaseStage()
        runner.render(recipe)
    }

    /// What the machine can make, as the shared checklist for images and video led by video: the same
    /// one the picture studio and the server screen open. Finishing it is pressing Render.
    func openChecklist() {
        Theme.Haptics.tap()
        MediaSetupGate.present(
            focus: .video, from: self, onFinish: { [weak self] in self?.renderTapped() },
            onChanged: { [weak self] in self?.render(animated: false) })
    }

    func openRenderer() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    func toggleSound() {
        muted.toggle()
        Theme.Haptics.selection()
        player.setMuted(muted)
        updateVerbs()
    }

    /// Opens the clip at the size of the phone. The inline loop is paused underneath for as long as
    /// the system player is up and resumed when it leaves, so a clip that was unmuted is never
    /// heard twice.
    func openStageClip() {
        guard let clip = stageClip else { return }
        Theme.Haptics.tap()
        player.setPlaying(false)
        ClipTheatre.present(clip.url, from: self) { [weak self] in
            guard let self, self.stageClip?.url == clip.url else { return }
            self.player.setPlaying(true)
        }
    }

    /// Shows a kept clip while a render is out. The stage belongs to the render then, so the clip
    /// opens in the system player over it and the render carries on underneath.
    func peek(_ entry: ForgeEntry) {
        guard entry.isPlayable else {
            if let failure = entry.failure { notice(failure) }
            return
        }
        guard peeking == nil else { return }
        let runner = runner
        peeking = Task { [weak self] in
            let located: Result<URL, Error>
            do {
                located = .success(try await runner.locate(entry))
            } catch {
                located = .failure(error)
            }
            guard let self else { return }
            self.peeking = nil
            switch located {
            case .success(let url):
                guard self.view.window != nil else { return }
                Theme.Haptics.tap()
                ClipTheatre.present(url, from: self)
            case .failure(let error):
                Theme.Haptics.error()
                self.notice(
                    ForgeClient.reason(
                        error, host: (entry.endpoint ?? runner.endpoint)?.host ?? ""))
            }
        }
    }

    func share(_ entry: ForgeEntry) {
        guard !sharing else { return }
        sharing = true
        notice(Localized.text("Fetching…"))
        let runner = runner
        Task { [weak self] in
            let staged: Result<URL, Error>
            do {
                staged = .success(try await runner.export(entry))
            } catch {
                staged = .failure(error)
            }
            guard let self else { return }
            self.sharing = false
            switch staged {
            case .success(let url):
                guard self.view.window != nil else { return }
                ClipExport.share(url, from: self, source: self.verbs)
            case .failure(let error):
                self.notice(
                    ForgeClient.reason(
                        error, host: (entry.endpoint ?? runner.endpoint)?.host ?? ""))
                Theme.Haptics.error()
            }
        }
    }

    /// Starts the next clip where this one ended, and says so: the keyboard is put away first so
    /// the box can take the clip's words, the player is stopped, and the stage, the button and the
    /// start-from slot all name the clip that is being continued. Then the box is focused, because
    /// the words are what changes. A clip that is gone, or that lives on another machine than the
    /// one rendering now, is said to be, rather than started from.
    func continueIt(_ entry: ForgeEntry) {
        guard !runner.isRendering else { return }
        guard !runner.isMissing(entry), board.canContinue(entry) else {
            Theme.Haptics.warning()
            if runner.isMissing(entry) {
                notice(ForgeFailure.missingFile((entry.endpoint ?? runner.endpoint)?.host ?? "").description)
            } else {
                notice(ForgeWords.continueElsewhere(entry.endpoint?.shortName ?? ""))
            }
            return
        }
        Theme.Haptics.selection()
        view.endEditing(true)
        releaseStage()
        beforeEnhance = nil
        runner.extend(entry)
        setPrompt(board.recipe.prompt)
        notice(ForgeWords.continuingNotice(entry))
        promptView.becomeFirstResponder()
    }

    func reuse(_ entry: ForgeEntry) {
        Theme.Haptics.selection()
        view.endEditing(true)
        seedReused = true
        beforeEnhance = nil
        runner.reuse(entry)
        setPrompt(board.recipe.prompt)
    }

    func forget(_ entry: ForgeEntry) {
        Theme.Haptics.warning()
        if stageEntry?.id == entry.id { releaseStage() }
        runner.forget(entry)
    }

    func notice(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor, duration: 3)
    }

    #if DEBUG
        /// Opens the renderer's own screen when asked, and sets a first frame or raises the rewrite
        /// card, so every part of this surface can be photographed without a finger driving it.
        func scrollForVerification() {
            let environment = ProcessInfo.processInfo.environment
            let opening = environment["TAILSCODE_VIDEO_OPEN"]
            if opening == "renderer" || opening == "sweep" || opening == "check" {
                openRenderer()
            }
            if environment["TAILSCODE_VIDEO_FRAME"] != nil {
                runner.start(from: ForgeRunner.stagedPicture())
            }
            if environment["TAILSCODE_VIDEO_CARD"] != nil {
                let words = (promptView.text ?? "").trimmed()
                presentEnhanceOverlay(original: words)
                enhanceOverlay?.render(
                    .ready([
                        EnhancedPrompt(
                            id: 0, label: "qwen3-8b",
                            text:
                                "A slow push-in on a ginger cat asleep on warm terracotta roof tiles in late afternoon light, its flank rising and falling as a soft breeze stirs the fur at its ears. Dust motes drift through the golden air above a skyline of chimneys. Distant rooftop doves coo and a faint church bell rings once.",
                            aspect: nil)
                    ]), original: words)
            }
        }
    #endif
}
