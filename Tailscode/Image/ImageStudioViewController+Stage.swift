import TailscodeCore
import UIKit

extension ImageStudioViewController {
    /// The whole stage as one value. A kept picture whose original is not here yet shows its tile
    /// while the bytes come, and asks for them once.
    private func stageState() -> StudioStageState {
        var state = StudioStageState()
        let exhibit = studio.exhibit
        var image: UIImage?
        var thumbnail: UIImage?
        var ratio: CGFloat?
        switch exhibit {
        case .made(let picture):
            image = studio.image(of: picture)
        case .kept(let item):
            image = studio.image(of: item)
            thumbnail = library.cachedThumbnail(of: item)
            if let facts = library.facts(of: item), let width = facts.width, let height = facts.height,
                width > 0
            {
                ratio = CGFloat(height) / CGFloat(width)
            }
            if image == nil { fetchOriginal(of: item) }
            library.describe(item)
        case nil:
            break
        }
        let held = image ?? thumbnail
        if let shown = held, shown.size.width > 0 {
            ratio = ratio ?? shown.size.height / shown.size.width
            if let image, image.size.width > 0 { ratio = image.size.height / image.size.width }
        }
        let paint = expectedRatio()
        switch slot.phase {
        case .painting:
            state.picture = held
            state.sketch = studio.sketch
            state.ratio = paint
            state.face = studio.sketch == nil ? .waiting : .painting
            state.sentence = slot.waitingLine(since: studio.startedAt, progress: studio.progress)
            state.activity = .working
            state.tone = .live
            if state.face == .painting {
                state.sketchCaption = ImageGenPreviewWords.caption(studio.progress)
                if let stage = studio.progress?.stage, stage == .decoding || stage == .saving {
                    state.dim = 0.25
                }
            } else {
                state.dim = held == nil ? 0 : 0.6
            }
            state.bar = studio.progress?.bar.map { [$0] } ?? []
            state.spoken = state.sentence
        case .failed(let prompt, let reason):
            let stopped = reason == ImageGenWords.stoppedNotice
            state.ratio = ratio ?? paint
            state.sentence = reason
            if stopped {
                state.face = .stopped
                state.picture = held
                state.tone = .attention
                state.dim = 0.45
                state.spoken = reason
            } else {
                state.face = .failed
                state.tone = .danger
                state.caption = prompt
                state.remedy = failureRemedy()
                state.spoken = [reason, prompt].filter { !$0.isEmpty }.joined(separator: ", ")
            }
        case .asking, .composing:
            if let exhibit, held != nil {
                state.face = .finished
                state.picture = held
                state.ratio = ratio ?? paint
                state.isOpenable = image != nil
                switch exhibit {
                case .made(let picture):
                    state.caption = ImageGenFacts.caption(for: picture)
                    state.facts = ImageGenFacts.line(for: picture)
                    state.spoken = [state.caption, state.facts].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                case .kept(let item):
                    let facts = library.facts(of: item)
                    state.caption = facts.map { ImageGenFacts.caption(for: $0) }
                    state.facts = facts.map { ImageGenFacts.line(for: $0) }
                    state.spoken = [
                        state.caption, state.facts, facts == nil ? nil : ImageGenWords.keptNote,
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                }
            } else {
                state.face = .empty
                state.ratio = 0.7
                state.emptyTitle = ImageGenWords.emptyTitle
                state.emptyBody = library.isEmpty ? ImageGenWords.emptyBody : ImageGenWords.stageEmptyKept
                state.starters = ImageGenBrief.examples.prefix(4).map { StudioStarter(title: $0.title) }
                state.behind = library.items.first.flatMap { library.cachedThumbnail(of: $0) }
                state.spoken = [state.emptyTitle, state.emptyBody].compactMap { $0 }.joined(separator: ", ")
                if !studio.door.isOpen {
                    state.emptyTitle = ImageGenEntryPoint.tooltip(configured: false)
                    state.emptyBody = ImageGenWords.emptyBody
                    state.starters = []
                    state.behind = nil
                    state.remedy = ForgeSetup.title
                    state.spoken = [state.emptyTitle, state.emptyBody].compactMap { $0 }.joined(separator: ", ")
                }
            }
        }
        return state
    }

    /// The rectangle the render will land in, decided before it starts: the shape asked for, or —
    /// when a reference is held and both editors take their size from it — the reference's own.
    private func expectedRatio() -> CGFloat {
        if !slot.aspectApplies, let reference = slot.references.first {
            if let known = referenceRatios[reference.path] { return known }
            let source = reference.kept.flatMap { library.cachedThumbnail(of: $0) }
                ?? UIImage(contentsOfFile: reference.path)
            if let source, source.size.width > 0 {
                let ratio = source.size.height / source.size.width
                referenceRatios[reference.path] = ratio
                return ratio
            }
        }
        let pixels = slot.aspect.pixels
        return CGFloat(pixels.height) / CGFloat(max(pixels.width, 1))
    }

    private func failureRemedy() -> String {
        if let reading = StudioMachineReading.image(studio.door), reading.cannotPaint {
            return Localized.text("See what is missing")
        }
        return String(localized: "Try again")
    }

    func remedyTapped() {
        guard studio.door.isOpen else {
            presentSetup()
            return
        }
        if let reading = StudioMachineReading.image(studio.door), reading.cannotPaint {
            presentMachine()
            return
        }
        guard let words = slot.activePrompt, !words.isEmpty else { return }
        Theme.Haptics.send()
        studio.submit(prompt: words)
    }

    func useStarter(_ index: Int) {
        let examples = ImageGenBrief.examples
        guard examples.indices.contains(index) else { return }
        let example = examples[index]
        Theme.Haptics.tap()
        studio.choose(aspect: example.aspect)
        setPrompt(example.prompt)
        studio.rememberDraft(example.prompt)
        updateChips()
        promptView.becomeFirstResponder()
    }

    private func fetchOriginal(of item: ImageGenLibraryItem) {
        guard loadingOriginal != item.id else { return }
        loadingOriginal = item.id
        Task { [weak self] in
            _ = await self?.studio.payload(of: item)
            guard let self else { return }
            if self.loadingOriginal == item.id { self.loadingOriginal = nil }
            self.renderStage()
            self.updateVerbs()
        }
    }

    func actions(for exhibit: ImageExhibit) -> [ImageGenAction] {
        switch exhibit {
        case .made:
            return ImageGenAction.offered(kept: false, hasWords: true, sharing: true, tapOpens: true)
                .filter { $0 != .discard }
        case .kept(let item):
            let words = library.facts(of: item)?.recipe?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ImageGenAction.offered(
                kept: true, hasWords: !(words ?? "").isEmpty, sharing: true, tapOpens: true)
        }
    }

    @objc func studioDidChange() {
        let landed = wasPainting && !studio.isPainting && slot.failure == nil
        wasPainting = studio.isPainting
        render(animated: true)
        if landed { announceLanding() }
    }

    @objc func progressDidChange() {
        renderStage()
        var snapshot = stripSource.snapshot()
        if snapshot.indexOfItem(.job) != nil {
            snapshot.reconfigureItems([.job])
            stripSource.apply(snapshot, animatingDifferences: false)
        }
    }

    @objc func libraryDidChange() {
        render(animated: true)
    }

    @objc func itemDidChange(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String else { return }
        var snapshot = stripSource.snapshot()
        if snapshot.indexOfItem(.tile(id)) != nil {
            snapshot.reconfigureItems([.tile(id)])
            stripSource.apply(snapshot, animatingDifferences: false)
        }
        if studio.exhibit?.libraryID == id {
            renderStage()
            updateVerbs()
        }
    }

    func render(animated: Bool) {
        renderStage()
        updateVerbs()
        applyStrip(animated: animated)
        updateChips()
        updateRenderButton()
        updatePlaceholder()
        updateEnhance()
        updateChrome()
        runClock()
    }

    private func renderStage() {
        stage.apply(stageState())
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a screen that keeps a timer alive over a settled state spends frames on
    /// nothing.
    private func runClock() {
        guard studio.isPainting else {
            clock?.cancel()
            clock = nil
            return
        }
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.renderStage()
            }
        }
    }
}
