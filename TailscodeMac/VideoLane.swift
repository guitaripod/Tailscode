import AVKit
import AppKit
import ImageIO
import TailscodeCore

/// The Video lane: `ForgeRunner` seen through the seam the shell draws every lane through. The
/// render, its socket and its board stay above the window in the runner — closing the Studio closes
/// a sheet and nothing else — and this owns the stage and the dock it hands over, and answers for
/// everything that is specific to making a clip: which verbs a stage offers, what a shelf tile is,
/// what the machine pill says. The Image lane's pieces are used wherever they are generic: the
/// dock, the pills, the rewrite card, the capsule, the shelf and the machine checklist are
/// the same classes, fed by a different brief.
@MainActor
final class VideoLane: StudioLane {
    let id = StudioLaneID.video
    let runner: ForgeRunner
    let brief: VideoBrief
    private let videoStage = VideoStageView()
    private let videoDock: StudioDockView
    private var watchers: [ObjectIdentifier: LaneWatcher] = [:]
    private var reading: StudioVideoReading
    private var stageEntryID: String?
    private var continuedID: String?
    private var landedID: String?
    private var located: [String: URL] = [:]
    private var asking: Set<String> = []
    private var clipFailures = StudioFailureLedger()
    private var locateFailures = StudioFailureLedger()
    private var saving: Set<String> = []
    private var epoch = 0
    private var sketchImage: CGImage?
    private var sketchFrame: ImageGenPreviewFrame?
    private var sketchTask: Task<Void, Never>?
    private var previews: [String: CGImage] = [:]
    private var previewOrder: [String] = []
    private var previewLoads: Set<String> = []
    private var previewFailures = StudioFailureLedger()
    private var clock: Timer?
    private var wasBusy = false

    var onNotice: ((String) -> Void)?

    private struct LaneWatcher {
        weak var owner: AnyObject?
        let notify: (StudioLaneChange) -> Void
    }

    var stage: NSView & StudioStaging { videoStage }
    var dock: NSView & StudioDocking { videoDock }

    init(runner: ForgeRunner) {
        self.runner = runner
        brief = VideoBrief(runner: runner)
        videoDock = StudioDockView(brief: brief)
        reading = StudioVideoReading(board: runner.board, missing: runner.missing)
        videoStage.onVerb = { [weak self] verb in self?.performOnStage(verb) }
        videoStage.onRemedy = { [weak self] remedy in self?.remedy(remedy) }
        videoStage.onDrop = { [weak self] drop in self?.drop(drop) }
        videoStage.onOpen = { [weak self] in self?.performOnStage("open") }
        videoStage.onSetup = { [weak self] in self?.openSetup() }
        videoStage.onClipFailed = { [weak self] id, sentence in self?.clipFailed(id, sentence) }
        videoStage.onStartFresh = { [weak self] in self?.startFresh() }
        videoStage.onPlaybackChanged = { [weak self] in self?.playbackChanged() }
        videoStage.onWindowChange = { [weak self] in self?.windowChanged() }
        videoDock.onNotice = { [weak self] line in self?.onNotice?(line) }
        videoDock.onOpenMachine = { [weak self] anchor in self?.presentMachine(from: anchor) }
        brief.onSetup = { [weak self] in self?.openSetup() }
        brief.onChecklist = { [weak self] in self?.openChecklist() }
        brief.onRender = { [weak self] in self?.releaseStage() }
        brief.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .rewrite: self.videoDock.rewriteChanged()
            case .state: self.emit(.everything)
            }
        }
        runner.watch(self) { [weak self] in self?.runnerChanged() }
        wasBusy = runner.isRendering
    }

    isolated deinit {
        runner.unwatch(self)
        clock?.invalidate()
        sketchTask?.cancel()
    }

    func watch(_ owner: AnyObject, _ block: @escaping (StudioLaneChange) -> Void) {
        watchers[ObjectIdentifier(owner)] = LaneWatcher(owner: owner, notify: block)
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private var board: ForgeBoard { runner.board }

    private var history: [ForgeEntry] { board.history }

    private var host: String { board.endpoint?.host ?? "" }

    func prepare() {
        runner.prepare()
        runner.probeIfUnchecked()
        if !runner.isDemo { brief.library.refresh() }
        adoptLanded(board.job)
        syncSketch()
        syncClock()
        emit(.everything)
    }

    /// A state staged by hand: the clip chosen on the stage, if any, and nothing the machine said.
    func stageForDemo(entryID: String?, continuing: Bool = false) {
        stageEntryID = entryID
        continuedID = continuing ? entryID : nil
        landedID = board.job.asset == nil ? nil : board.job.promptID
        syncSketch()
        machineChanged()
        emit(.everything)
    }

    private func emit(_ change: StudioLaneChange) {
        videoStage.apply(stageModel(), change: change)
        noteFailureShown()
        videoDock.studioChanged(change)
        watchers = watchers.filter { $0.value.owner != nil }
        for watcher in watchers.values { watcher.notify(change) }
    }

    /// The card for a render that failed is on the stage, which is what reading it means: the
    /// toolbar's light stays on until this, and a clip that cannot be played is not that failure.
    private func noteFailureShown() {
        guard videoStage.window != nil, StudioVideoSelection.isOutcome(board.job),
            case .failed = state
        else { return }
        runner.acknowledgeFailure()
    }

    /// The forge moved. What a surface owes the change is decided by what moved: a sketch is one
    /// layer, a step is one line and one bar, anything else is the whole picture — and the words a
    /// person is typing are in none of them.
    private func runnerChanged() {
        let job = board.job
        syncSketch()
        adoptLanded(job)
        let next = StudioVideoReading(board: board, missing: runner.missing)
        if next.shape.endpoint != reading.shape.endpoint { machineChanged() }
        if board.continuing == nil { continuedID = nil }
        let change = next.change(from: reading, sketchMoved: false)
        reading = next
        let busy = job.isBusy
        let moved = busy != wasBusy
        wasBusy = busy
        if moved {
            if busy { releaseStage() }
            noteEnding(job)
        }
        if let change {
            emit(moved ? .everything : change)
        }
        syncClock()
    }

    /// The machine's newest sketch, decoded off the main actor; and let go of when no render is out,
    /// because a sketch outlives its render only for as long as the stage needs to fade it.
    private func syncSketch() {
        let job = board.job
        if !job.isBusy {
            sketchImage = nil
            sketchFrame = nil
            sketchTask?.cancel()
        } else if let frame = job.sketch, frame != sketchFrame {
            decode(frame)
        }
    }

    private func decode(_ frame: ImageGenPreviewFrame) {
        sketchFrame = frame
        sketchTask?.cancel()
        sketchTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                MacImageLibrary.downsample(frame.bytes, longestSide: 1024)
            }.value
            guard let self, !Task.isCancelled, self.sketchFrame == frame, let image else { return }
            self.sketchImage = image
            self.emit(.sketch)
        }
    }

    /// A render that landed becomes the clip on stage, found by the machine's id for the job — two
    /// machines can both have written `forge_00007.mp4` — and only once its receipt is on the
    /// shelf: a landing that cannot find its clip is looked for again on the next change.
    private func adoptLanded(_ job: ForgeJob) {
        guard let id = job.promptID, id != landedID,
            let entry = StudioVideoSelection.landed(job: job, history: history)
        else { return }
        landedID = id
        stageEntryID = entry.id
        continuedID = nil
    }

    /// Pressing Render takes the stage off whatever clip it was on, and stops it: a clip left running
    /// under the next one's sketch keeps its sound on.
    private func releaseStage() {
        videoStage.pausePlayback()
        stageEntryID = nil
        continuedID = nil
    }

    /// The machine renders go to, or the machine a clip was found on, changed: everything learnt
    /// about where a file is, and every answer still on its way back, belongs to the one left.
    private func machineChanged() {
        epoch += 1
        located = [:]
        asking = []
        clipFailures.forget()
        locateFailures.forget()
        previewFailures.forget()
        previews = [:]
        previewOrder = []
        previewLoads = []
    }

    private func windowChanged() {
        syncClock()
        guard videoStage.window != nil,
            runner.unpresented != nil || StudioVideoSelection.isOutcome(board.job)
        else { return }
        emit(.everything)
    }

    /// The stage started or stopped a clip. A landed clip that is playing has been put in front of
    /// somebody, and is not put in front of them again the next time the Studio opens.
    private func playbackChanged() {
        if videoStage.isPlaying, let entry = exhibit, entry.id == board.job.promptID, let asset = entry.asset {
            runner.present(asset)
        }
        emit(.everything)
    }

    private func startFresh() {
        continuedID = nil
        runner.start(from: nil)
        videoDock.focusWords()
    }

    private func noteEnding(_ job: ForgeJob) {
        guard videoStage.window != nil else { return }
        switch job.phase {
        case .done:
            MacHaptics.shared.play(.received)
        case .failed:
            MacHaptics.shared.play(.error)
        default:
            break
        }
    }

    /// The elapsed time on the stage's caption and the shelf's job tile moves once a second while a
    /// render is out, on a timer of its own rather than the machine's frames, which pause for as
    /// long as a pass takes to load.
    private func syncClock() {
        guard board.isBusy, videoStage.window != nil else {
            clock?.invalidate()
            clock = nil
            return
        }
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.progress) }
        }
        clock?.tolerance = 0.2
    }

    /// What the lane is holding, in one line, for the headless driver.
    var driveState: String {
        "state=\(state) verbs=\(videoStage.model.verbs.map(\.id)) playing=\(videoStage.isPlaying) "
            + "tiles=\(shelf.count) selected=\(selectedTile ?? "-") stage=\(exhibit?.id ?? "-") "
            + "clip=\(videoStage.model.clip?.id ?? "-") sketch=\(sketchImage != nil) "
            + "size=\(videoStage.model.size.label) rect=\(videoStage.currentPictureRect) stage=\(videoStage.frame)"
    }

    var exhibit: ForgeEntry? {
        stageEntryID.flatMap { id in history.first { $0.id == id } }
    }

    private func clipSource(for entry: ForgeEntry?) -> StudioClipSource? {
        guard let entry else { return nil }
        guard entry.asset != nil else {
            return .unavailable(entry.failure ?? ForgeFailure.noOutput(host).description)
        }
        if runner.isMissing(entry) {
            return .unavailable(ForgeFailure.missingFile(entry.endpoint?.host ?? host).description)
        }
        if let failure = clipFailures.sentence(for: entry.id) { return .unavailable(failure) }
        if let failure = locateFailures.sentence(for: entry.id) { return .unreachable(failure) }
        return .playable
    }

    private func remedy() -> StudioRemedy {
        guard board.endpoint != nil else { return .machine }
        if StudioMachineReading.forge(board)?.cannotPaint == true { return .wake }
        return .retry
    }

    private var state: StudioVideoState {
        StudioVideoState.read(
            job: board.job, clip: clipSource(for: exhibit), hasStart: board.recipe.frame != nil,
            hasWords: board.recipe.isRenderable, remedy: remedy(), continuing: continuation != nil)
    }

    /// The clip the stage is holding back from playing because the next one opens on its end: the
    /// one Continue it was pressed on, for as long as the board still starts from it and nothing
    /// else has been put on the stage over it. A clip chosen from the shelf is a clip to watch, even
    /// when it is the one the draft starts from.
    private var continuation: ForgeEntry? {
        guard let id = continuedID, !board.isBusy, !StudioVideoSelection.isOutcome(board.job),
            let entry = exhibit, entry.id == id, let leading = board.continuing,
            leading.asset == entry.asset, leading.endpoint == entry.endpoint
        else { return nil }
        return entry
    }

    private func stageModel() -> VideoStageModel {
        let job = board.job
        let entry = exhibit
        let state = self.state
        var model = VideoStageModel()
        model.state = state
        if let entry, state == .done || isUnavailable(state), !job.isBusy, !StudioVideoSelection.isOutcome(job) {
            ensureLocated(entry)
        }
        model.clip = state == .done ? entry.flatMap { hold(for: $0) } : nil
        model.size = size(for: state, entry: entry)
        model.segments = StudioProgressLine.segments(job: job)
        model.sketchCaption = ForgeWords.sketchCaption(job)
        model.sketch = job.isBusy ? sketchImage : nil
        model.held = heldImage(for: state, entry: entry)
        let playing = videoStage.isPlaying && state == .done
        model.verbs = StudioVideoVerbs.offered(
            state: state, hasWords: entry?.recipe.isRenderable ?? false, playing: playing,
            isHistory: entry != nil, canContinue: entry.map(board.canContinue) ?? false)
        model.arriving =
            state == .done && videoStage.window != nil && runner.unpresented != nil
            && entry?.id == job.promptID
        let spent = job.spent()
        switch state {
        case .empty:
            model.heldIsBackdrop = true
            model.invitationTitle =
                board.endpoint == nil
                ? ForgeEntryPoint.tooltip(configured: false) : brief.wordsPlaceholder
            model.invitationBody = ForgeBoard.notice
            model.needsRenderer = board.endpoint == nil
            model.spoken = model.invitationTitle
        case .drafting:
            model.caption = board.recipe.frame?.detail ?? ""
            model.spoken = [model.caption, board.recipe.prompt].filter { !$0.isEmpty }.joined(separator: ", ")
            if board.recipe.frame == nil {
                model.heldIsBackdrop = true
                model.invitationTitle = brief.wordsPlaceholder
                model.invitationBody = ForgeBoard.notice
            }
        case .waiting(let line):
            model.sentence = line
            model.caption = spent ?? ""
            model.spoken = line
        case .working(let line), .painting(let line), .finishing(let line):
            model.sentence = line
            model.caption = [line, spent].compactMap { $0 }.joined(separator: "  ·  ")
            model.spoken = line
        case .done:
            if let entry {
                var parts = [entry.recipe.prompt.ellipsized(to: 60), entry.recipe.summary]
                if job.promptID == entry.id, let spent { parts.append(spent) }
                model.caption = parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                model.spoken = entry.title
                model.landed = StudioStageWords.clipLanded(words: entry.recipe.prompt)
            }
        case .continuing:
            model.caption = board.recipe.frame?.detail ?? ""
            model.spoken = ForgeWords.continuingTitle(entry)
            model.continuationTitle = ForgeWords.continuingTitle(entry)
            model.continuationBody = ForgeWords.continuingBody
            model.continuationAction = ForgeWords.continuingFreshTitle
        case .failed(let reason, _):
            let words = StudioVideoSelection.isOutcome(job) ? job.recipe.prompt : (entry?.recipe.prompt ?? "")
            model.caption = words.ellipsized(to: 60)
            model.spoken = reason
        case .stopped:
            model.caption = job.subtitle
            model.spoken = job.subtitle
        }
        return model
    }

    private func isUnavailable(_ state: StudioVideoState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func size(for state: StudioVideoState, entry: ForgeEntry?) -> ForgeSize {
        let job = board.job
        if job.isBusy || StudioVideoSelection.isOutcome(job) { return job.recipe.size }
        switch state {
        case .done, .failed: return entry?.recipe.size ?? board.recipe.size
        default: return board.recipe.size
        }
    }

    private func hold(for entry: ForgeEntry) -> VideoClipHold? {
        guard let url = located[entry.id] else { return nil }
        return VideoClipHold(id: entry.id, url: url)
    }

    /// The machine is asked where a clip is before a player is pointed at it, once: the file may
    /// have been cleaned up, and a player reports that in words about nothing a person can act on.
    /// The machine asked is the one that wrote the clip, and an answer that arrives after the machine
    /// in force has changed is about a question nobody is asking any more.
    private func ensureLocated(_ entry: ForgeEntry) {
        guard entry.asset != nil, located[entry.id] == nil, !clipFailures.holds(entry.id),
            !locateFailures.holds(entry.id), !runner.isMissing(entry), !asking.contains(entry.id)
        else { return }
        asking.insert(entry.id)
        let born = epoch
        let host = entry.endpoint?.host ?? self.host
        Task { [weak self] in
            guard let self else { return }
            var url: URL?
            var failure: String?
            do {
                url = try await self.runner.locate(entry)
            } catch ForgeFailure.missingFile {
            } catch {
                failure = ForgeClient.reason(error, host: host)
            }
            guard self.epoch == born else { return }
            self.asking.remove(entry.id)
            if let url { self.located[entry.id] = url }
            if let failure { self.locateFailures.note(entry.id, sentence: failure) }
            self.emit(.everything)
        }
    }

    /// The player could not play a clip, for the clip it was asked to play: by the time it says so
    /// the stage may be on another. The address is let go of too, so the next try asks the machine
    /// again rather than being pointed at the same dead one.
    private func clipFailed(_ id: String, _ sentence: String) {
        located[id] = nil
        clipFailures.note(id, sentence: sentence)
        if let entry = history.first(where: { $0.id == id }), let asset = entry.asset,
            id == board.job.promptID
        {
            runner.present(asset)
        }
        emit(.everything)
    }

    private func heldImage(for state: StudioVideoState, entry: ForgeEntry?) -> CGImage? {
        switch state {
        case .drafting:
            if board.recipe.frame == nil { return newestPoster() }
            return startPreview()
        case .done, .continuing:
            return posterImage(of: entry)
        case .failed:
            if let entry, board.job.phase != .cancelled, !StudioVideoSelection.isOutcome(board.job) {
                return posterImage(of: entry)
            }
            return startPreview() ?? newestPoster()
        case .waiting, .working, .painting, .finishing, .stopped:
            return startPreview() ?? posterImage(of: exhibit) ?? newestPoster()
        case .empty:
            return newestPoster()
        }
    }

    private func posterImage(of entry: ForgeEntry?) -> CGImage? {
        guard let entry, entry.asset != nil else { return nil }
        let key = MacClipPosters.key(for: entry, on: board.endpoint)
        if let image = MacClipPosters.cached(key) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        loadPreview(id: "poster:" + key) { [runner] in
            await MacClipPosters.poster(for: entry, via: runner)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    private func newestPoster() -> CGImage? {
        posterImage(of: history.first(where: \.isPlayable))
    }

    /// What the next clip starts from, as the stage can show it: the picture itself where there is
    /// one, or the poster of the clip it continues. Decoded off the main actor, once, to a size the
    /// stage can use — the picture on disk is not touched.
    private func startPreview() -> CGImage? {
        guard let frame = board.recipe.frame else { return nil }
        switch frame {
        case .file(let path):
            let key = "file:" + path
            if let image = previews[key] { return image }
            loadPreview(id: key) {
                await Task.detached {
                    FileManager.default.contents(atPath: path).flatMap { MacImageStudio.stageBitmap($0) }
                }.value
            }
            return nil
        case .kept(let name):
            let key = "kept:" + name
            if let image = previews[key] { return image }
            let library = brief.library
            guard let item = library.items.first(where: { $0.annotatedName == name }) else { return nil }
            loadPreview(id: key) {
                guard let data = await library.original(of: item) else { return nil }
                return await Task.detached { MacImageStudio.stageBitmap(data) }.value
            }
            return nil
        case .clipEnd:
            return posterImage(of: board.continuing)
        }
    }

    private func loadPreview(id: String, _ load: @escaping @MainActor () async -> CGImage?) {
        guard previews[id] == nil, !previewFailures.holds(id), previewLoads.insert(id).inserted else {
            return
        }
        let born = epoch
        Task { [weak self] in
            let image = await load()
            guard let self, self.epoch == born else { return }
            self.previewLoads.remove(id)
            guard let image else {
                self.previewFailures.note(id)
                return
            }
            if id.hasPrefix("file:") || id.hasPrefix("kept:") {
                self.previews[id] = image
                self.previewOrder.append(id)
                if self.previewOrder.count > 6 { self.previews[self.previewOrder.removeFirst()] = nil }
            }
            self.emit(.everything)
        }
    }

    var shelf: [StudioShelfItem] {
        let job = board.job
        let busy: StudioClipShelf.Job? =
            job.isBusy ? StudioClipShelf.Job(words: job.recipe.prompt, startedAt: job.startedAt) : nil
        return StudioClipShelf.merge(job: busy, history: history, missing: runner.missing)
    }

    var selectedTile: String? {
        StudioVideoSelection.shelfID(staged: exhibit?.id, job: board.job)
    }

    var shelfTitle: String { Localized.text("Clips") }

    var shelfNote: String? {
        history.isEmpty && !board.isBusy ? Localized.text("Nothing rendered yet") : nil
    }

    var dismissNote: String? { ForgeSurface.dismissNote(rendering: runner.isRendering) }

    var machine: StudioMachineFact {
        guard let reading = StudioMachineReading.forge(board) else {
            return StudioMachineFact(
                name: ForgeField.endpoint.label, line: board.value(of: .endpoint), tone: .attention,
                canPaint: true, isWorking: false)
        }
        var line = reading.fact
        if reading.tone == .live { line += "  ·  " + ForgeModel.label }
        return StudioMachineFact(
            name: reading.name, line: line, tone: board.isBusy ? .live : reading.tone,
            canPaint: !reading.cannotPaint, isWorking: board.isBusy)
    }

    var queueCount: Int {
        if case .queued(let ahead) = board.job.phase { return ahead + 1 }
        return board.isBusy ? 1 : 0
    }

    var jobSketch: CGImage? { board.job.isBusy ? sketchImage : nil }

    var jobBadge: String? {
        let job = board.job
        if let passes = job.passSegments, let index = passes.firstIndex(where: \.isCurrent) {
            return "\(index + 1)/\(passes.count) · \(Int((passes[index].fraction * 100).rounded()))%"
        }
        return job.badge
    }

    var jobFraction: Double? { board.job.fraction }

    private var hasWords: Bool {
        !videoDock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func offers(_ key: StudioKey) -> Bool {
        let busy = board.isBusy
        let entry = exhibit
        let showing = videoStage.showsClip
        switch key {
        case .generate: return !busy && hasWords
        case .stop: return busy || brief.draft != nil
        case .enhance: return !busy && !brief.enhancing && hasWords
        case .again: return !busy && showing && entry?.recipe.isRenderable == true
        case .save, .open, .copy: return showing
        case .editThis: return showing && !busy && entry.map(board.canContinue) == true
        case .previousTile, .nextTile: return shelf.contains { !$0.isJob }
        case .imageLane, .videoLane: return false
        }
    }

    func perform(_ key: StudioKey) {
        switch key {
        case .generate: videoDock.submit()
        case .stop: videoDock.stopOrDismiss()
        case .enhance: videoDock.startEnhance()
        case .again: performOnStage("again")
        case .save: performOnStage("save")
        case .open: performOnStage("play")
        case .editThis: performOnStage("continue")
        case .copy: performOnStage("copy")
        case .previousTile: walk(-1)
        case .nextTile: walk(1)
        case .imageLane, .videoLane: break
        }
    }

    private func walk(_ step: Int) {
        let items = shelf
        let current = selectedTile == StudioShelfMerge.jobID ? nil : selectedTile
        guard let next = StudioShelfMerge.neighbour(of: current, step: step, in: items) else { return }
        select(tile: next)
    }

    func select(tile id: String) {
        guard id != StudioShelfMerge.jobID, history.contains(where: { $0.id == id }) else { return }
        if StudioVideoSelection.isOutcome(board.job) { runner.settle() }
        videoStage.pausePlayback()
        stageEntryID = id
        continuedID = nil
        emit(.everything)
    }

    func tileThumbnail(_ item: StudioShelfItem) async -> NSImage? {
        guard let entry = history.first(where: { $0.id == item.id }), entry.asset != nil,
            !runner.isMissing(entry)
        else { return nil }
        return await MacClipPosters.poster(for: entry, via: runner)
    }

    func tileFileName(_ item: StudioShelfItem) -> String {
        history.first(where: { $0.id == item.id })?.fileName ?? item.id
    }

    func tileFile(_ item: StudioShelfItem) async -> StudioDragFile? {
        guard let entry = history.first(where: { $0.id == item.id }), let data = await bytes(of: entry) else {
            return nil
        }
        return StudioDragFile(name: entry.fileName, data: data)
    }

    func tileVerbs(for item: StudioShelfItem) -> [StudioTileVerb] {
        guard let entry = history.first(where: { $0.id == item.id }) else { return [] }
        guard entry.isPlayable, !runner.isMissing(entry) else {
            return [
                .putOnStage, .verb(reuseVerb), .verb(StudioStageVerb(ImageGenAction.discard)),
            ]
        }
        var verbs: [StudioTileVerb] = [.putOnStage]
        let busy = board.isBusy
        for verb in StudioVideoVerbs.offered(
            state: .done, hasWords: entry.recipe.isRenderable && !busy, playing: false, isHistory: true,
            canContinue: board.canContinue(entry) && !busy)
        where verb.id != "play" {
            verbs.append(verb.id == "open" ? .open : .verb(verb))
        }
        return verbs
    }

    private var reuseVerb: StudioStageVerb {
        StudioStageVerb(
            id: "reuse", title: StudioRemedy.reuse.title, hint: ForgeWords.frameHint,
            symbol: "arrow.uturn.backward")
    }

    func tileTooltip(_ item: StudioShelfItem) -> String {
        if item.isJob { return item.words }
        guard let entry = history.first(where: { $0.id == item.id }) else { return item.words }
        var parts: [String] = []
        if !item.words.isEmpty { parts.append(item.words.ellipsized(to: 80)) }
        if runner.isMissing(entry) {
            parts.append(ForgeFailure.missingFile(host).description)
        } else if let failure = entry.failure {
            parts.append(failure)
        } else {
            parts.append(
                [ImageGenLibraryWords.ago(entry.finishedAt), entry.recipe.size.label].joined(separator: " · "))
            parts.append(Localized.text("Drag out to save"))
        }
        return parts.joined(separator: "\n")
    }

    func perform(_ verb: StudioTileVerb, on item: StudioShelfItem) {
        guard let entry = history.first(where: { $0.id == item.id }) else { return }
        switch verb {
        case .putOnStage: select(tile: entry.id)
        case .open: open(entry)
        case .verb(let face): perform(face.id, on: entry)
        case .action: break
        }
    }

    #if DEBUG
        /// What the stage's Open full size does, for a headless run that has no hand to press the verb.
        func openFullSize() {
            guard let entry = exhibit else { return }
            open(entry)
        }
    #endif

    private func performOnStage(_ verb: StudioStageVerb) {
        performOnStage(verb.id)
    }

    private func performOnStage(_ id: String) {
        guard let entry = exhibit else { return }
        perform(id, on: entry)
    }

    private func perform(_ id: String, on entry: ForgeEntry) {
        switch id {
        case "play":
            if entry.id != exhibit?.id { select(tile: entry.id) }
            videoStage.togglePlayback()
        case "save": save(entry)
        case "share": share(entry)
        case "copy": copy(entry)
        case "open": open(entry)
        case "again": again(entry)
        case "continue": continueFrom(entry)
        case "discard": discard(entry)
        case "reuse": reuse(entry)
        default: break
        }
    }

    /// The same words again with a fresh seed — the one thing a person wants after a clip that was
    /// nearly right.
    private func again(_ entry: ForgeEntry) {
        guard !board.isBusy else { return }
        runner.reuse(entry)
        runner.pick(.seed, id: "reroll")
        videoDock.take(brief: board.recipe.prompt)
        brief.submit(prompt: board.recipe.prompt)
    }

    /// The next clip opens where this one ended: the clip is put on the stage first, wherever Continue
    /// it was pressed from, and the stage says what it is now waiting for — the clip's poster held
    /// dimmed behind a card that names it — while the words come back to be edited into what happens
    /// next and the caret goes to them. A clip on another machine cannot be continued from here, and
    /// the line says which machine has it.
    private func continueFrom(_ entry: ForgeEntry) {
        guard entry.isPlayable, !board.isBusy else { return }
        guard board.canContinue(entry) else {
            onNotice?(ForgeWords.continueElsewhere(entry.endpoint?.shortName ?? host))
            return
        }
        videoStage.pausePlayback()
        stageEntryID = entry.id
        continuedID = entry.id
        runner.extend(entry)
        MacHaptics.shared.play(.selection)
        onNotice?(ForgeWords.continuingNotice(entry))
        videoDock.take(brief: board.recipe.prompt)
    }

    private func reuse(_ entry: ForgeEntry) {
        runner.reuse(entry)
        videoDock.take(brief: entry.recipe.prompt)
    }

    private func discard(_ entry: ForgeEntry) {
        MacDialogs.confirm(
            on: videoStage.window, title: ImageGenAction.discard.title,
            body: Localized.text(
                "The clip stays on the machine. This only takes it off the stage and the shelf."),
            confirmLabel: ImageGenAction.discard.title
        ) { [weak self] in
            guard let self else { return }
            if self.stageEntryID == entry.id { self.stageEntryID = nil }
            self.runner.forget(entry)
            self.onNotice?(Localized.text("Clip let go of"))
        }
    }

    private func bytes(of entry: ForgeEntry) async -> Data? {
        guard let asset = entry.asset, let client = runner.client(for: entry) else { return nil }
        do {
            return try await client.fetch(asset)
        } catch {
            onNotice?(ForgeClient.reason(error, host: client.endpoint.host))
            return nil
        }
    }

    /// The clip as a file on this Mac, for the share sheet and the pasteboard, which take files and
    /// not bytes. Written once, under the name the words make, to a folder the system may empty.
    private func localCopy(of entry: ForgeEntry) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tailscode-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(entry.id)-\(entry.fileName)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = await bytes(of: entry) else { return nil }
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// The clip's bytes from the machine that wrote them, into a file of the person's choosing. A
    /// clip is minutes of video over a tailnet, so the press is answered at once with what is
    /// happening, and a second press on the same clip while it is coming is not a second download.
    private func save(_ entry: ForgeEntry, report: (@MainActor (String) -> Void)? = nil) {
        guard saving.insert(entry.id).inserted else { return }
        let say: @MainActor (String) -> Void = { [weak self] line in
            if let report { report(line) } else { self?.onNotice?(line) }
        }
        say(Localized.text("Fetching…"))
        Task { [weak self] in
            guard let self else { return }
            let data = await self.bytes(of: entry)
            self.saving.remove(entry.id)
            guard let data else { return }
            StudioFiles.save(
                data: data, name: entry.fileName, window: self.videoStage.window, report: say)
        }
    }

    private func share(_ entry: ForgeEntry, from anchor: NSView? = nil) {
        Task { [weak self] in
            guard let self, let url = await self.localCopy(of: entry) else { return }
            StudioFiles.share(url, from: anchor ?? self.videoStage)
        }
    }

    private func copy(_ entry: ForgeEntry) {
        Task { [weak self] in
            guard let self, let url = await self.localCopy(of: entry) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            self.onNotice?(Localized.text("Clip copied"))
        }
    }

    /// Open full size: the clip in the viewer's sheet, stacked on the Studio, with the system's own
    /// controls — the Studio's stage keeps its room, and a second look at a clip is not a reason to
    /// give up the first.
    private func open(_ entry: ForgeEntry) {
        guard entry.asset != nil else { return }
        videoStage.pausePlayback()
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(entry)
                MediaViewer.shared.play(
                    clip: url, title: entry.title, host: self.videoStage.window,
                    save: { [weak self] report in self?.save(entry, report: report) },
                    share: { [weak self] anchor in self?.share(entry, from: anchor) })
            } catch {
                self.onNotice?(ForgeClient.reason(error, host: self.host))
            }
        }
    }

    private func remedy(_ remedy: StudioRemedy) {
        switch remedy {
        case .retry:
            brief.submit(prompt: board.recipe.prompt)
        case .wake:
            clipFailures.forget()
            locateFailures.forget()
            runner.probe()
            emit(.everything)
        case .machine:
            if board.endpoint == nil { openSetup() } else { openChecklist() }
        case .reuse:
            if let entry = exhibit { reuse(entry) }
        case .useEngine:
            break
        }
    }

    private func drop(_ drop: StudioDrop) {
        brief.hold(drop: drop) { [weak self] held in
            guard held else { return }
            self?.videoDock.focusWords()
        }
    }

    /// The machine's setup, opened over the Studio — the same flow adding a server opens — and the
    /// renderer it settles on is taken up by the runner, which outlives this surface.
    func openSetup() {
        guard let window = videoStage.window else { return }
        ForgeSetupSheet.present(on: window) { [weak self] in
            ForgeRunner.shared.pointAtStoredRenderer()
            self?.emit(.everything)
        }
    }

    /// What the machine can make, as the shared checklist for images and video led by video: the same
    /// one the picture lane and the servers window open. Finishing it is pressing Render.
    func openChecklist() {
        MediaSetupGate.present(
            endpoint: board.endpoint, focus: .video, on: videoStage.window,
            onFinish: { [weak self] in self?.brief.submit(prompt: self?.board.recipe.prompt ?? "") },
            onChanged: { [weak self] in self?.emit(.everything) })
    }

    func presentMachine(from anchor: NSView) {
        openChecklist()
    }

    /// Puts a picture the Image lane handed over where the next clip starts from, and says so on the
    /// dock the way a hand putting it there would.
    func start(from request: StudioAnimateRequest) {
        runner.settle()
        runner.start(from: request.frame, width: request.width, height: request.height)
        videoDock.focusWords()
    }
}
