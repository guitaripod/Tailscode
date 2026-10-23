import TailscodeCore
import UIKit

extension VideoForgeViewController {
    private func stageState() -> StudioStageState {
        let job = board.job
        var state = StudioStageState()
        state.glyph = "film"
        let size = job.isBusy ? job.recipe.size : board.recipe.size
        state.ratio = CGFloat(size.height) / CGFloat(max(size.width, 1))
        if job.isBusy {
            let working = job.phase.activity
            state.activity = working
            state.tone = job.phase.tone
            state.sketch = sketchImage
            state.face = sketchImage == nil ? .waiting : .painting
            var parts: [String] = []
            if case .running = job.phase, !job.isCollecting {
                parts.append(job.detail)
            } else {
                parts.append(job.subtitle)
            }
            if let spent = job.spent() { parts.append(spent) }
            state.sentence = parts.joined(separator: " · ")
            if state.face == .painting {
                state.sketchCaption = ForgeWords.sketchCaption(job)
                if job.isCollecting { state.dim = 0.25 }
            }
            state.bar = lineFractions()
            state.spoken = state.sentence
            return state
        }
        if let entry = stageEntry {
            state.ratio = CGFloat(entry.recipe.size.height) / CGFloat(max(entry.recipe.size.width, 1))
            guard entry.isPlayable else {
                state.face = .failed
                state.tone = .danger
                state.sentence = entry.failure
                state.caption = entry.title
                state.spoken = [entry.failure, entry.title].compactMap { $0 }.joined(separator: ", ")
                return state
            }
            if stageClip != nil {
                state.face = .finished
                state.overlayVisible = true
                state.isOpenable = true
                state.caption = entry.title
                state.facts = entry.recipe.summary
                state.spoken = [entry.title, entry.recipe.summary].joined(separator: ", ")
                state.sketch = nil
            } else if let failure = stageFailure {
                state.face = .failed
                state.tone = .danger
                state.sentence = failure
                state.caption = entry.title
                if !runner.isMissing(entry) { state.remedy = String(localized: "Try again") }
                state.spoken = [failure, entry.title].joined(separator: ", ")
            } else {
                state.face = .waiting
                state.sentence = Localized.text("Checking…")
                state.activity = .connecting
                state.sketch = sketchImage
                state.dim = 0.25
                state.spoken = state.sentence
            }
            return state
        }
        switch job.phase {
        case .failed(let reason):
            state.face = .failed
            state.tone = .danger
            state.sentence = reason
            state.caption = job.recipe.prompt
            state.remedy = failureRemedy()
            state.spoken = [reason, job.recipe.prompt].filter { !$0.isEmpty }.joined(separator: ", ")
        case .cancelled:
            state.face = .stopped
            state.tone = .attention
            state.sentence = job.subtitle
            state.spoken = job.subtitle
        case .drafting, .submitting, .queued, .running, .done:
            state.face = .empty
            state.emptyTitle = board.prompt
            state.emptyBody = ForgeBoard.notice
            state.spoken = [board.prompt, ForgeBoard.notice].joined(separator: ", ")
            if runner.endpoint == nil {
                state.emptyTitle = ForgeEntryPoint.tooltip(configured: false)
                state.remedy = ForgeSetup.title
                state.spoken = state.emptyTitle
            } else if let entry = board.continuing {
                state.emptyTitle = ForgeWords.continuingTitle(entry)
                state.emptyBody = ForgeWords.continuingBody
                state.remedy = ForgeWords.continuingFreshTitle
                state.behind = picture(of: entry, endFrame: false)
                state.spoken = [state.emptyTitle, state.emptyBody].compactMap { $0 }.joined(separator: ", ")
            }
        }
        return state
    }

    /// The picture of a clip that is already held, and one asked for when it is not: the first
    /// frame, or the last when a continuation is about to open on it. Asked for once per clip per
    /// screen, and the screen is redrawn only when something arrived, so a machine that cannot
    /// give one is not asked again on every frame the socket sends.
    func picture(of entry: ForgeEntry, endFrame: Bool) -> UIImage? {
        guard !runner.isMissing(entry), let asset = entry.asset,
            let endpoint = entry.endpoint ?? runner.endpoint, let url = asset.url(on: endpoint),
            let key = ClipPosters.key(entry, fallback: runner.endpoint)
        else { return nil }
        let wanted = endFrame ? ClipPosters.endKey(key) : key
        if let held = ClipPosters.cached(wanted) { return held }
        if framesAsked.insert(wanted).inserted {
            Task { [weak self] in
                let image =
                    endFrame
                    ? await ClipPosters.endFrame(of: url, key: key)
                    : await ClipPosters.poster(of: url, key: key)
                guard image != nil, let self else { return }
                self.updateStartFrom()
                self.renderStage()
            }
        }
        return endFrame ? ClipPosters.cached(key) : nil
    }

    private var jobFailed: Bool {
        if case .failed = board.job.phase { return true }
        return false
    }

    private func failureRemedy() -> String {
        if let reading = StudioMachineReading.forge(board), reading.cannotPaint {
            return Localized.text("See what is missing")
        }
        return String(localized: "Try again")
    }

    func remedyTapped() {
        guard runner.endpoint != nil else { return openRenderer() }
        if let entry = stageEntry, stageFailure != nil { return showOnStage(entry) }
        if board.continuing != nil, !runner.isRendering, !jobFailed {
            Theme.Haptics.selection()
            return runner.start(from: nil)
        }
        if let reading = StudioMachineReading.forge(board), reading.cannotPaint {
            return openChecklist()
        }
        renderTapped()
    }

    @objc func boardDidChange() {
        render(animated: true)
    }

    func render(animated: Bool) {
        let rendering = runner.isRendering
        let landed = wasRendering && !rendering
        wasRendering = rendering
        adoptSketch()
        syncStage()
        renderStage()
        updateVerbs()
        applyStrip(animated: animated)
        updateChips()
        updateRenderButton()
        syncPrompt()
        updateEnhance()
        updateChrome()
        runClock()
        acknowledgeFailureIfShown()
        if landed, case .done = board.job.phase { announceLanding() }
    }

    /// The render broke and the card saying why is on the stage in front of the person, so the way
    /// in to video can stop wearing it. A surface that is built but not yet on screen has shown
    /// nobody anything, and a failure that belongs to a clip's file is not the render's.
    func acknowledgeFailureIfShown() {
        guard jobFailed, stageEntry == nil, view.window != nil else { return }
        runner.acknowledgeFailure()
    }

    private func renderStage() {
        stage.apply(stageState())
        if stageClip == nil { player.clear() }
    }

    /// The machine's sketch, decoded away from the main thread and only if it is still the newest
    /// when it is ready. A render that sends none leaves the stage on the phase's own face.
    private func adoptSketch() {
        let job = board.job
        guard job.isBusy else {
            if stageClip != nil || job.isFinished { decoding?.cancel() }
            return
        }
        guard let frame = job.sketch, frame != sketchFrame else { return }
        sketchFrame = frame
        decoding?.cancel()
        decoding = Task { [weak self] in
            let image = await Task.detached { StudioSketch.decode(frame) }.value
            guard let self, !Task.isCancelled, self.sketchFrame == frame, let image else { return }
            self.sketchImage = image
            self.renderStage()
            var snapshot = self.stripSource.snapshot()
            if snapshot.indexOfItem(.job) != nil {
                snapshot.reconfigureItems([.job])
                self.stripSource.apply(snapshot, animatingDifferences: false, completion: nil)
            }
        }
    }

    /// Which clip is on the stage: the one a render just delivered, the first time this screen
    /// sees it, until somebody puts another there; nothing while a render is out, because the
    /// render is what the stage is for. A clip is presented once however many times the screen is
    /// opened, and one that landed while the screen was closed is presented the first time it shows.
    private func syncStage() {
        let job = board.job
        if job.isBusy {
            if stageEntry != nil || stageClip != nil || locating != nil { releaseStage() }
            if case .submitting = job.phase, sketchImage != nil, sketchFrame == nil || job.sketch == nil {
                sketchImage = nil
                sketchFrame = nil
            }
            return
        }
        guard let asset = runner.unpresented,
            let entry = board.history.first(where: { $0.asset == asset })
        else { return }
        runner.present(asset)
        putOnStage(entry)
    }

    /// Takes the stage off whatever it was on, and every answer still on its way back with it: the
    /// player is cleared, not merely hidden, because a clip left running under the sketch of the
    /// next one keeps its sound on.
    func releaseStage() {
        stageTicket += 1
        locating?.cancel()
        locating = nil
        revealed = nil
        stageEntry = nil
        stageClip = nil
        stageFailure = nil
        player.clear()
    }

    func showOnStage(_ entry: ForgeEntry) {
        putOnStage(entry)
        renderStage()
        updateVerbs()
        applyStrip(animated: false)
    }

    /// A clip is the stage's from the moment it is asked for. The renderer is asked whether the
    /// file is still there, and the answer is believed only while the clip it was asked about is
    /// still the one on the stage.
    private func putOnStage(_ entry: ForgeEntry) {
        releaseStage()
        stageEntry = entry
        guard entry.isPlayable else { return }
        let ticket = stageTicket
        let runner = runner
        locating = Task { [weak self] in
            let located: Result<URL, Error>
            do {
                located = .success(try await runner.locate(entry))
            } catch {
                located = .failure(error)
            }
            guard let self, !Task.isCancelled, self.stageTicket == ticket, let asset = entry.asset
            else { return }
            switch located {
            case .success(let url):
                self.stageClip = (asset, url)
                self.player.show(url)
                self.player.setMuted(self.muted)
            case .failure(let error):
                let host = (entry.endpoint ?? self.runner.endpoint)?.host ?? ""
                self.stageFailure = ForgeClient.reason(error, host: host)
            }
            self.locating = nil
            self.renderStage()
            self.updateVerbs()
            self.applyStrip(animated: false)
        }
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does.
    private func runClock() {
        guard runner.isRendering else {
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
