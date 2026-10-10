import AVKit
import AppKit
import ImageIO
import TailscodeCore

/// The Video lane: `ForgeRunner` seen through the seam the shell draws every lane through. The
/// render, its socket and its board stay above the window in the runner — closing the Studio closes
/// a panel and nothing else — and this owns the stage and the dock it hands over, and answers for
/// everything that is specific to making a clip: which verbs a stage offers, what a shelf tile is,
/// what the machine pill says. The Image lane's pieces are used wherever they are generic: the
/// dock, the pills, the rewrite card, the capsule, the shelf and the machine's popover frame are
/// the same classes, fed by a different brief.
@MainActor
final class VideoLane: StudioLane {
    let id = StudioLaneID.video
    let runner: ForgeRunner
    let brief: VideoBrief
    private let videoStage = VideoStageView()
    private let videoDock: StudioDockView
    private var watchers: [ObjectIdentifier: LaneWatcher] = [:]
    private var popover: NSPopover?
    private var reading: StudioVideoReading
    private var stageEntryID: String?
    private var lastAsset: ForgeAsset?
    private var located: [String: URL] = [:]
    private var asking: Set<String> = []
    private var clipFailures: [String: String] = [:]
    private var sketchImage: CGImage?
    private var sketchFrame: ImageGenPreviewFrame?
    private var sketchTask: Task<Void, Never>?
    private var previews: [String: CGImage] = [:]
    private var previewOrder: [String] = []
    private var previewLoads: Set<String> = []
    private var previewFailures: Set<String> = []
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
        videoStage.onClipFailed = { [weak self] sentence in self?.clipFailed(sentence) }
        videoStage.onPlaybackChanged = { [weak self] in self?.emit(.everything) }
        videoStage.onWindowChange = { [weak self] in self?.syncClock() }
        videoDock.onNotice = { [weak self] line in self?.onNotice?(line) }
        videoDock.onOpenMachine = { [weak self] anchor in self?.presentMachine(from: anchor) }
        brief.onSetup = { [weak self] in self?.openSetup() }
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
        syncSketch()
        syncClock()
        emit(.everything)
    }

    /// A state staged by hand: the clip chosen on the stage, if any, and nothing the machine said.
    func stageForDemo(entryID: String?) {
        stageEntryID = entryID
        lastAsset = board.job.asset
        syncSketch()
        located = [:]
        clipFailures = [:]
        previewFailures = []
        previews = [:]
        emit(.everything)
    }

    private func emit(_ change: StudioLaneChange) {
        videoStage.apply(stageModel(), change: change)
        videoDock.studioChanged(change)
        watchers = watchers.filter { $0.value.owner != nil }
        for watcher in watchers.values { watcher.notify(change) }
    }

    /// The forge moved. What a surface owes the change is decided by what moved: a sketch is one
    /// layer, a step is one line and one bar, anything else is the whole picture — and the words a
    /// person is typing are in none of them.
    private func runnerChanged() {
        let job = board.job
        syncSketch()
        adoptLanded(job)
        let next = StudioVideoReading(board: board, missing: runner.missing)
        if next.shape.endpoint != reading.shape.endpoint {
            located = [:]
            clipFailures = [:]
            previewFailures = []
        }
        let change = next.change(from: reading, sketchMoved: false)
        reading = next
        let busy = job.isBusy
        let moved = busy != wasBusy
        wasBusy = busy
        if moved { noteEnding(job) }
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

    /// A render that landed becomes the clip on stage, found by the file it made, because the
    /// receipt's identity is the machine's prompt id and this surface only knows the asset.
    private func adoptLanded(_ job: ForgeJob) {
        guard let asset = job.asset else { return }
        guard asset != lastAsset else { return }
        lastAsset = asset
        if let entry = history.first(where: { $0.asset == asset }) { stageEntryID = entry.id }
    }

    private func noteEnding(_ job: ForgeJob) {
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
        if runner.isMissing(entry) { return .unavailable(ForgeFailure.missingFile(host).description) }
        if let failure = clipFailures[entry.id] { return .unavailable(failure) }
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
            hasWords: board.recipe.isRenderable, remedy: remedy())
    }

    private func stageModel() -> VideoStageModel {
        let job = board.job
        let entry = exhibit
        let state = self.state
        var model = VideoStageModel()
        model.state = state
        if let entry, state == .done || isUnavailable(state), !job.isBusy, !isJobOutcome(job) {
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
            isHistory: entry != nil)
        let spent = job.spent()
        switch state {
        case .empty:
            model.invitationTitle =
                board.endpoint == nil
                ? ForgeEntryPoint.tooltip(configured: false) : brief.wordsPlaceholder
            model.invitationBody = ForgeBoard.notice
            model.needsRenderer = board.endpoint == nil
            model.spoken = model.invitationTitle
        case .drafting:
            model.caption = board.recipe.frame?.detail ?? ""
            model.spoken = [model.caption, board.recipe.prompt].filter { !$0.isEmpty }.joined(separator: ", ")
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
                if job.asset == entry.asset, let spent { parts.append(spent) }
                model.caption = parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                model.spoken = entry.title
                model.landed = StudioStageWords.clipLanded(words: entry.recipe.prompt)
            }
        case .failed(let reason, _):
            let words = isJobOutcome(job) ? job.recipe.prompt : (entry?.recipe.prompt ?? "")
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

    private func isJobOutcome(_ job: ForgeJob) -> Bool {
        switch job.phase {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func size(for state: StudioVideoState, entry: ForgeEntry?) -> ForgeSize {
        let job = board.job
        if job.isBusy || isJobOutcome(job) { return job.recipe.size }
        switch state {
        case .done, .failed: return entry?.recipe.size ?? board.recipe.size
        default: return board.recipe.size
        }
    }

    private func hold(for entry: ForgeEntry) -> VideoClipHold? {
        guard let url = located[entry.id] else { return nil }
        return VideoClipHold(id: entry.id, url: url)
    }

    /// The renderer is asked where a clip is before a player is pointed at it, once: the file may
    /// have been cleaned up, and a player reports that in words about nothing a person can act on.
    private func ensureLocated(_ entry: ForgeEntry) {
        guard let asset = entry.asset, located[entry.id] == nil, clipFailures[entry.id] == nil,
            !runner.isMissing(entry), !asking.contains(entry.id)
        else { return }
        asking.insert(entry.id)
        let host = self.host
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(asset, entryID: entry.id)
                self.located[entry.id] = url
            } catch ForgeFailure.missingFile {
            } catch {
                self.clipFailures[entry.id] = ForgeClient.reason(error, host: host)
            }
            self.asking.remove(entry.id)
            self.emit(.everything)
        }
    }

    private func clipFailed(_ sentence: String) {
        guard let entry = exhibit else { return }
        clipFailures[entry.id] = sentence
        emit(.everything)
    }

    private func heldImage(for state: StudioVideoState, entry: ForgeEntry?) -> CGImage? {
        switch state {
        case .drafting:
            return startPreview() ?? posterImage(of: entry)
        case .done:
            return posterImage(of: entry)
        case .failed:
            if let entry, board.job.phase != .cancelled, !isJobOutcome(board.job) {
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
        guard let entry, let asset = entry.asset else { return nil }
        let key = MacClipPosters.key(for: asset, host: board.endpoint?.host)
        if let image = MacClipPosters.cached(key) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        loadPreview(id: "poster:" + key) { [runner] in
            await MacClipPosters.poster(for: asset, entryID: entry.id, via: runner)?
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
        case .clipEnd(let asset):
            return posterImage(of: history.first { $0.asset == asset })
        }
    }

    private func loadPreview(id: String, _ load: @escaping @MainActor () async -> CGImage?) {
        guard previews[id] == nil, !previewFailures.contains(id), previewLoads.insert(id).inserted else {
            return
        }
        Task { [weak self] in
            let image = await load()
            guard let self else { return }
            self.previewLoads.remove(id)
            guard let image else {
                self.previewFailures.insert(id)
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
        board.isBusy ? StudioShelfMerge.jobID : exhibit?.id
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
        case .editThis: return showing && entry?.isPlayable == true
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
        let current = board.isBusy ? nil : exhibit?.id
        guard let next = StudioShelfMerge.neighbour(of: current, step: step, in: items) else { return }
        select(tile: next)
    }

    func select(tile id: String) {
        guard id != StudioShelfMerge.jobID, history.contains(where: { $0.id == id }) else { return }
        runner.settle()
        videoStage.pausePlayback()
        stageEntryID = id
        emit(.everything)
    }

    func tileThumbnail(_ item: StudioShelfItem) async -> NSImage? {
        guard let entry = history.first(where: { $0.id == item.id }), let asset = entry.asset,
            !runner.isMissing(entry)
        else { return nil }
        return await MacClipPosters.poster(for: asset, entryID: entry.id, via: runner)
    }

    func tileFileName(_ item: StudioShelfItem) -> String {
        history.first(where: { $0.id == item.id }).map(StudioClipName.fileName(for:)) ?? item.id
    }

    func tileFile(_ item: StudioShelfItem) async -> StudioDragFile? {
        guard let entry = history.first(where: { $0.id == item.id }), let data = await bytes(of: entry) else {
            return nil
        }
        return StudioDragFile(name: StudioClipName.fileName(for: entry), data: data)
    }

    func tileVerbs(for item: StudioShelfItem) -> [StudioTileVerb] {
        guard let entry = history.first(where: { $0.id == item.id }) else { return [] }
        guard entry.isPlayable, !runner.isMissing(entry) else {
            return [
                .putOnStage, .verb(reuseVerb), .verb(StudioStageVerb(ImageGenAction.discard)),
            ]
        }
        var verbs: [StudioTileVerb] = [.putOnStage]
        for verb in StudioVideoVerbs.offered(
            state: .done, hasWords: entry.recipe.isRenderable, playing: false, isHistory: true)
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

    /// The next clip opens where this one ended: the last frame becomes Start from, the words come
    /// back to be edited into what happens next, and the clip being continued stays on stage until
    /// the next one lands.
    private func continueFrom(_ entry: ForgeEntry) {
        guard entry.isPlayable, !board.isBusy else { return }
        videoStage.pausePlayback()
        runner.extend(entry)
        MacHaptics.shared.play(.selection)
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
        guard let asset = entry.asset, let client = runner.renderer(for: asset) else { return nil }
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
        let url = folder.appendingPathComponent("\(entry.id)-\(StudioClipName.fileName(for: entry))")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = await bytes(of: entry) else { return nil }
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    private func save(_ entry: ForgeEntry) {
        Task { [weak self] in
            guard let self, let data = await self.bytes(of: entry) else { return }
            StudioFiles.save(
                data: data, name: StudioClipName.fileName(for: entry), window: self.videoStage.window
            ) { [weak self] line in self?.onNotice?(line) }
        }
    }

    private func share(_ entry: ForgeEntry) {
        Task { [weak self] in
            guard let self, let url = await self.localCopy(of: entry) else { return }
            StudioFiles.share(url, from: self.videoStage)
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

    /// Open full size: the clip in a window of its own, sized to its shape, with the system's own
    /// controls — the Studio's stage keeps its room, and a second look at a clip is not a reason to
    /// give up the first.
    private func open(_ entry: ForgeEntry) {
        guard let asset = entry.asset else { return }
        videoStage.pausePlayback()
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(asset, entryID: entry.id)
                VideoTheatre.present(
                    url: url, title: entry.title, size: entry.recipe.size, near: self.videoStage.window)
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
            runner.probe()
        case .machine:
            if board.endpoint == nil { openSetup() } else { presentMachine(from: videoStage) }
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
        popover?.close()
        guard let window = videoStage.window else { return }
        ForgeSetupSheet.present(on: window) { [weak self] in
            ForgeRunner.shared.pointAtStoredRenderer()
            self?.emit(.everything)
        }
    }

    func presentMachine(from anchor: NSView) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = StudioVideoMachineSheet(runner: runner) { [weak self] in self?.openSetup() }
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = pop
    }

    /// Puts a picture the Image lane handed over where the next clip starts from, and says so on the
    /// dock the way a hand putting it there would.
    func start(from request: StudioAnimateRequest) {
        runner.settle()
        runner.start(from: request.frame, width: request.width, height: request.height)
        videoDock.focusWords()
    }
}

/// What the machine pill opens in the Video lane: the renderer, whether it answers, the model it
/// renders with and when it was last looked at — read off the same board the pill reads, so the
/// two can never disagree — and the two things a person does here, look again and set up another.
@MainActor
final class StudioVideoMachineSheet: NSViewController {
    private let runner: ForgeRunner
    private let onSetup: () -> Void
    private let heading = StudioTheme.label(.panelTitle, color: MacTheme.Color.label)
    private let address = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private let summary = StudioTheme.label(.panelLabel, color: MacTheme.Color.label, lines: 4)
    private let dot = NSImageView()
    private let modelLabel = StudioTheme.label(.rowTitle, color: MacTheme.Color.secondaryLabel)
    private let modelValue = StudioTheme.label(.rowDetail, color: MacTheme.Color.label)
    private let modelNote = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 2)
    private let note = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 3)
    private let check = NSButton(title: "", target: nil, action: nil)
    private let change = NSButton(title: "", target: nil, action: nil)

    private static let width: CGFloat = 400
    private static let pad: CGFloat = 18

    init(runner: ForgeRunner, onSetup: @escaping () -> Void) {
        self.runner = runner
        self.onSetup = onSetup
        super.init(nibName: nil, bundle: nil)
        runner.watch(self) { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { runner.unwatch(self) }

    override func loadView() {
        let root = StudioFlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 260))
        for view in [heading, address, summary, dot, modelLabel, modelValue, modelNote, note, check, change] as [NSView] {
            root.addSubview(view)
        }
        check.bezelStyle = .rounded
        check.target = self
        check.action = #selector(checkPressed)
        change.bezelStyle = .rounded
        change.target = self
        change.action = #selector(changePressed)
        dot.imageScaling = .scaleProportionallyDown
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        runner.probeIfUnchecked()
    }

    func reload() {
        guard isViewLoaded else { return }
        let board = runner.board
        let reading = StudioMachineReading.forge(board)
        heading.stringValue = reading?.name ?? ForgeField.endpoint.label
        address.stringValue = board.endpoint.map { "\($0.host):\($0.port)" } ?? ForgeBoard.heading
        summary.stringValue = reading?.fact ?? board.value(of: .endpoint)
        let ready = reading?.tone == .live
        let blocked = reading?.cannotPaint == true
        dot.image = StudioTheme.symbol(
            ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 20)
        dot.contentTintColor =
            ready ? MacTheme.Color.success : (blocked ? MacTheme.Color.danger : MacTheme.Color.tertiaryLabel)
        modelLabel.stringValue = ForgeBoard.heading
        modelValue.stringValue = ForgeModel.label
        modelNote.stringValue = ForgeModel.detail
        note.stringValue = ForgeBoard.notice
        check.title = board.isChecking ? Localized.text("Checking…") : ImageGenMachineWords.checkAgain
        check.isEnabled = !board.isChecking && board.endpoint != nil
        change.title = board.endpoint == nil ? ForgeSetup.title : ImageGenMachineWords.change
        layoutAll()
    }

    private func layoutAll() {
        let pad = Self.pad
        let width = Self.width - 2 * pad
        func wrapped(_ field: NSTextField) -> CGFloat {
            ceil(field.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height) + 2
        }
        var y = pad
        heading.frame = NSRect(x: pad, y: y, width: width - 30, height: 22)
        dot.frame = NSRect(x: Self.width - pad - 24, y: y - 1, width: 24, height: 24)
        y += 22
        address.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22
        let summaryHeight = wrapped(summary)
        summary.frame = NSRect(x: pad, y: y, width: width, height: summaryHeight)
        y += summaryHeight + 14
        modelLabel.frame = NSRect(x: pad, y: y, width: 120, height: 18)
        modelValue.frame = NSRect(x: pad + 120, y: y, width: width - 120, height: 18)
        modelValue.alignment = .right
        y += 22
        let modelHeight = wrapped(modelNote)
        modelNote.frame = NSRect(x: pad, y: y, width: width, height: modelHeight)
        y += modelHeight + 10
        let noteHeight = wrapped(note)
        note.frame = NSRect(x: pad, y: y, width: width, height: noteHeight)
        y += noteHeight + 14
        check.frame = NSRect(x: pad, y: y, width: 130, height: 28)
        change.frame = NSRect(x: pad + 138, y: y, width: 190, height: 28)
        y += 28 + pad
        if abs(y - view.frame.height) > 0.5 {
            preferredContentSize = NSSize(width: Self.width, height: y)
            view.frame.size.height = y
        }
    }

    @objc private func checkPressed() { runner.probe() }

    @objc private func changePressed() {
        let setup = onSetup
        view.window?.close()
        setup()
    }
}

/// A plain view that lays out from its top edge, for a popover that is read down the page.
final class StudioFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A clip at full size in a window of its own, with the system's own controls: sized to the clip's
/// shape and no larger than most of the screen, one per clip, and let go of when it closes.
@MainActor
final class VideoTheatre: NSObject, NSWindowDelegate {
    private static var open: [VideoTheatre] = []

    private let window: NSWindow
    private let player: AVPlayer

    static func present(url: URL, title: String, size: ForgeSize, near host: NSWindow?) {
        if let held = open.first(where: { ($0.player.currentItem?.asset as? AVURLAsset)?.url == url }) {
            held.window.makeKeyAndOrderFront(nil)
            return
        }
        let made = VideoTheatre(url: url, title: title, size: size, near: host)
        open.append(made)
        made.window.makeKeyAndOrderFront(nil)
        made.player.play()
    }

    private init(url: URL, title: String, size: ForgeSize, near host: NSWindow?) {
        player = AVPlayer(url: url)
        let visible = (host?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let ratio = CGFloat(size.width) / CGFloat(max(size.height, 1))
        var width = min(CGFloat(size.width), visible.width * 0.85)
        var height = width / ratio
        if height > visible.height * 0.85 {
            height = visible.height * 0.85
            width = height * ratio
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(480, width), height: max(270, height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentAspectRatio = NSSize(width: size.width, height: size.height)
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        window.contentView = view
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        Self.open.removeAll { $0 === self }
    }
}
