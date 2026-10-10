import AppKit
import CodingAgentKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// The Image lane: `MacImageStudio` seen through the seam the shell draws every lane through. It
/// owns the stage and the dock it hands over and answers for everything that is specific to making a
/// picture — which verbs a stage offers, what a shelf tile is, what the machine pill says — and
/// nothing else. A pane in the grid builds its own lane over a studio of its own, so the panel's
/// picture and a pane's never share a prompt.
@MainActor
final class ImageLane: StudioLane {
    let id = StudioLaneID.image
    let studio: MacImageStudio
    private let imageStage: StudioStageView
    private let imageDock: StudioDockView
    private var watchers: [ObjectIdentifier: LaneWatcher] = [:]
    private var popover: NSPopover?

    var onNotice: ((String) -> Void)?

    private struct LaneWatcher {
        weak var owner: AnyObject?
        let notify: (StudioLaneChange) -> Void
    }

    var stage: NSView & StudioStaging { imageStage }
    var dock: NSView & StudioDocking { imageDock }

    init(studio: MacImageStudio) {
        self.studio = studio
        imageStage = StudioStageView(studio: studio)
        imageDock = StudioDockView(studio: studio)
        imageStage.onVerb = { [weak self] action in self?.performOnStage(action) }
        imageStage.onStarter = { [weak self] example in self?.take(example) }
        imageStage.onRemedy = { [weak self] remedy in self?.remedy(remedy) }
        imageStage.onDrop = { [weak self] drop in self?.drop(drop) }
        imageStage.onOpen = { [weak self] in self?.performOnStage(.open) }
        imageDock.onNotice = { [weak self] line in self?.onNotice?(line) }
        imageDock.onOpenMachine = { [weak self] anchor in self?.presentMachine(from: anchor) }
        studio.watch(self) { [weak self] change in self?.studioChanged(change) }
    }

    isolated deinit { studio.unwatch(self) }

    func watch(_ owner: AnyObject, _ block: @escaping (StudioLaneChange) -> Void) {
        watchers[ObjectIdentifier(owner)] = LaneWatcher(owner: owner, notify: block)
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func studioChanged(_ change: MacImageStudio.Change) {
        let lane: StudioLaneChange
        switch change {
        case .state: lane = .everything
        case .progress: lane = .progress
        case .sketch: lane = .sketch
        case .rewrite:
            imageDock.rewriteChanged()
            return
        case .shelf(let id): lane = id.map { .tile($0) } ?? .shelf
        }
        imageStage.studioChanged(lane)
        imageDock.studioChanged(lane)
        watchers = watchers.filter { $0.value.owner != nil }
        for watcher in watchers.values { watcher.notify(lane) }
    }

    func prepare() {
        guard !studio.isStaged else { return }
        studio.adoptDoor()
        studio.checkMachine()
        studio.library.refresh()
    }

    var shelf: [StudioShelfItem] {
        let slot = studio.slot
        let job: StudioShelfMerge.Job? =
            slot.isBusy ? StudioShelfMerge.Job(words: slot.activePrompt ?? "", startedAt: studio.startedAt) : nil
        let library = studio.library
        return StudioShelfMerge.merge(
            job: job, session: slot.pictures, machine: library.items,
            facts: { library.facts(of: $0) })
    }

    var selectedTile: String? {
        studio.isPainting ? StudioShelfMerge.jobID : studio.exhibit?.id
    }

    var shelfNote: String? { studio.library.failure }

    var machine: StudioMachineFact {
        let sighting = studio.sighting
        let door = ImageGenDoor(endpoint: studio.endpoint, inherited: studio.door.inherited, sighting: sighting)
        var parts: [String] = [door.line ?? ImageGenMachineWords.summary(sighting)]
        if let version = sighting?.version, door.line == nil {
            parts = [studio.engineBlocked == nil ? Self.readyWord(studio) : parts[0]]
            parts.append("\(ImageGenMachineWords.versionLabel) \(version)")
        }
        let canPaint = sighting == nil || sighting?.available(studio.slot.engine) == true
        let tone: ActivityTone?
        if studio.isPainting {
            tone = .live
        } else if sighting == nil || sighting?.reachable == false {
            tone = .quiet
        } else if !canPaint {
            tone = .danger
        } else {
            tone = door.tone ?? .live
        }
        return StudioMachineFact(
            name: studio.endpoint.shortName, line: parts.joined(separator: "  ·  "), tone: tone,
            canPaint: canPaint, isWorking: studio.isPainting)
    }

    private static func readyWord(_ studio: MacImageStudio) -> String {
        guard let sighting = studio.sighting else { return ImageGenMachineWords.neverChecked }
        let ready = sighting.readyEngines
        if ready.count == ImageGenEngine.allCases.count {
            return Localized.text("%@ ready", studio.slot.engine.label)
        }
        return ImageGenMachineWords.summary(sighting)
    }

    var queueCount: Int { studio.queueCount }

    var jobSketch: CGImage? { studio.sketch }

    var jobBadge: String? {
        guard let progress = studio.progress, let step = progress.step, let steps = progress.steps, steps > 0 else {
            return nil
        }
        return "\(min(step, steps))/\(steps)"
    }

    var jobFraction: Double? { studio.progress?.bar }

    func offers(_ key: StudioKey) -> Bool {
        let slot = studio.slot
        let hasWords = !imageDock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch key {
        case .generate: return !slot.isBusy && hasWords
        case .stop: return slot.isBusy || studio.draft != nil
        case .enhance: return !slot.isBusy && !studio.enhancing && hasWords
        case .again:
            guard !slot.isBusy, let exhibit = studio.exhibit else { return false }
            return imageStage.showsPicture && studio.hasWords(exhibit)
        case .save, .open, .editThis, .copy: return imageStage.showsPicture
        case .previousTile, .nextTile: return shelf.contains { !$0.isJob }
        case .imageLane, .videoLane: return false
        }
    }

    func perform(_ key: StudioKey) {
        switch key {
        case .generate: imageDock.submit()
        case .stop: imageDock.stopOrDismiss()
        case .enhance: imageDock.startEnhance()
        case .again: studio.again()
        case .save: performOnStage(.save)
        case .open: performOnStage(.open)
        case .editThis: performOnStage(.reference)
        case .copy: performOnStage(.copy)
        case .previousTile: walk(-1)
        case .nextTile: walk(1)
        case .imageLane, .videoLane: break
        }
    }

    private func walk(_ step: Int) {
        let items = shelf
        let current = studio.isPainting ? nil : studio.exhibit?.id
        guard let next = StudioShelfMerge.neighbour(of: current, step: step, in: items) else { return }
        select(tile: next)
    }

    func select(tile id: String) {
        guard id != StudioShelfMerge.jobID, let exhibit = exhibit(for: id) else { return }
        studio.show(exhibit)
    }

    private func exhibit(for id: String) -> StudioExhibit? {
        if let made = studio.slot.pictures.first(where: { ($0.remoteName ?? $0.path) == id }) {
            return .made(made)
        }
        if let item = studio.library.item(named: id) { return .kept(item) }
        return nil
    }

    func tileThumbnail(_ item: StudioShelfItem) async -> NSImage? {
        if let made = studio.slot.pictures.first(where: { ($0.remoteName ?? $0.path) == item.id }) {
            let path = made.path
            let image = await Task.detached(priority: .userInitiated) {
                FileManager.default.contents(atPath: path).flatMap {
                    MacImageLibrary.downsample($0, longestSide: MacImageLibrary.tileSide)
                }
            }.value
            return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        guard let kept = studio.library.item(named: item.id) else { return nil }
        studio.library.describe(kept)
        return await studio.library.thumbnail(of: kept)
    }

    func tileFileName(_ item: StudioShelfItem) -> String {
        guard let exhibit = exhibit(for: item.id) else { return item.id }
        return studio.fileName(of: exhibit)
    }

    func tileFile(_ item: StudioShelfItem) async -> StudioDragFile? {
        guard let exhibit = exhibit(for: item.id), let data = await studio.bytes(of: exhibit) else { return nil }
        return StudioDragFile(name: studio.fileName(of: exhibit), data: data)
    }

    func tileVerbs(for item: StudioShelfItem) -> [StudioTileVerb] {
        guard let exhibit = exhibit(for: item.id) else { return [] }
        var verbs: [StudioTileVerb] = [.putOnStage]
        verbs += ImageGenAction.offered(
            kept: exhibit.isKept, hasWords: studio.hasWords(exhibit), sharing: true, tapOpens: false
        ).map { .action($0) }
        return verbs
    }

    func tileTooltip(_ item: StudioShelfItem) -> String {
        if item.isJob { return item.words }
        var parts: [String] = []
        if !item.words.isEmpty { parts.append(item.words.ellipsized(to: 80)) }
        var detail: [String] = []
        if let date = item.madeAt { detail.append(ImageGenLibraryWords.ago(date)) }
        if let bytes = item.bytes { detail.append(ImageGenFacts.size(bytes)) }
        if !detail.isEmpty { parts.append(detail.joined(separator: " · ")) }
        parts.append(Localized.text("Drag out to save"))
        return parts.joined(separator: "\n")
    }

    func perform(_ verb: StudioTileVerb, on item: StudioShelfItem) {
        guard let exhibit = exhibit(for: item.id) else { return }
        switch verb {
        case .putOnStage: studio.show(exhibit)
        case .action(let action): perform(action, on: exhibit)
        }
    }

    private func performOnStage(_ action: ImageGenAction) {
        guard let exhibit = studio.exhibit else { return }
        perform(action, on: exhibit)
    }

    private func perform(_ action: ImageGenAction, on exhibit: StudioExhibit) {
        switch action {
        case .save: save(exhibit)
        case .share: share(exhibit)
        case .copy: copy(exhibit)
        case .open: open(exhibit)
        case .again:
            studio.show(exhibit)
            studio.again()
        case .reference:
            switch exhibit {
            case .made(let picture):
                studio.hold(ImageGenReference(path: picture.path, kept: picture.kept))
            case .kept(let item):
                studio.hold(kept: item)
            }
            MacHaptics.shared.play(.selection)
            imageDock.focusWords()
        case .discard:
            guard case .made(let picture) = exhibit else { return }
            MacDialogs.confirm(
                on: imageStage.window, title: ImageGenAction.discard.title,
                body: Localized.text(
                    "The file stays where it was written. This only takes the picture off the stage and the shelf."),
                confirmLabel: ImageGenAction.discard.title
            ) { [weak self] in
                self?.studio.discard(picture.path)
                self?.onNotice?(ImageGenWords.discardNotice)
            }
        case .stage:
            studio.show(exhibit)
        }
    }

    private func save(_ exhibit: StudioExhibit) {
        Task { [weak self] in
            guard let self, let data = await self.studio.bytes(of: exhibit) else { return }
            let name = self.studio.fileName(of: exhibit)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
                panel.allowedContentTypes = [type]
            }
            panel.canCreateDirectories = true
            let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url else { return }
                    if (try? data.write(to: url, options: .atomic)) != nil {
                        self?.onNotice?(ImageGenWords.savedNotice(path: url.path))
                    } else {
                        self?.onNotice?(Localized.text("Could not write %@", url.path))
                    }
                }
            }
            if let window = self.imageStage.window {
                panel.beginSheetModal(for: window, completionHandler: write)
            } else {
                write(panel.runModal())
            }
        }
    }

    private func share(_ exhibit: StudioExhibit) {
        Task { [weak self] in
            guard let self, let url = await self.shareableURL(exhibit) else { return }
            let picker = NSSharingServicePicker(items: [url])
            let stage = self.imageStage
            let rect = NSRect(x: stage.bounds.midX - 1, y: stage.bounds.maxY - 80, width: 2, height: 2)
            picker.show(relativeTo: rect, of: stage, preferredEdge: .minY)
        }
    }

    private func shareableURL(_ exhibit: StudioExhibit) async -> URL? {
        switch exhibit {
        case .made(let picture):
            return URL(fileURLWithPath: picture.path)
        case .kept(let item):
            guard await studio.library.original(of: item) != nil,
                let path = studio.library.originalPath(of: item)
            else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func copy(_ exhibit: StudioExhibit) {
        Task { [weak self] in
            guard let self, let data = await self.studio.bytes(of: exhibit) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if ImageGenLibraryItem(filename: self.studio.fileName(of: exhibit)).kind == .png {
                pasteboard.setData(data, forType: .png)
            } else if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
            self.onNotice?(ImageGenWords.copiedNotice)
        }
    }

    private func open(_ exhibit: StudioExhibit) {
        var items: [ImageViewer.Item] = studio.slot.pictures.map {
            ImageViewer.Item(
                key: Self.viewerKey($0.remoteName ?? $0.path), name: studio.fileName(of: .made($0)),
                reference: FileReference(path: $0.path))
        }
        if case .kept(let item) = exhibit {
            items.insert(
                ImageViewer.Item(
                    key: Self.viewerKey(item.id), name: studio.fileName(of: exhibit),
                    reference: FileReference(path: item.id)), at: 0)
        }
        let studio = self.studio
        ImageViewer.present(
            items: items, startKey: Self.viewerKey(exhibit.id), host: imageStage.window,
            fetch: { [weak studio] reference, key in
                guard let studio else { return }
                Task { @MainActor in
                    let id = String(key.dropFirst(Self.viewerPrefix.count))
                    let data: Data?
                    if let made = studio.slot.pictures.first(where: { ($0.remoteName ?? $0.path) == id }) {
                        data = FileManager.default.contents(atPath: made.path)
                    } else if let item = studio.library.item(named: id) {
                        data = await studio.library.original(of: item)
                    } else {
                        data = nil
                    }
                    guard let data else { return }
                    let decoded = await Task.detached { ImageStore.decode(data) }.value
                    guard let decoded else { return }
                    ImageStore.shared.store(decoded, forKey: key)
                }
            },
            toast: { [weak self] line in self?.onNotice?(line) })
    }

    private static let viewerPrefix = "studio:"

    private static func viewerKey(_ id: String) -> String { viewerPrefix + id }

    /// A starter is the first half of a sentence: its words land in the box with the caret at their
    /// end and the shape it was written for is taken, and nothing is sent.
    private func take(_ example: ImageGenBrief.Example) {
        imageDock.take(brief: example.prompt)
        studio.follow(aspect: example.aspect)
        if example.id == "cutout", studio.slot.cutoutApplies { studio.setCutout(true) }
    }

    private func remedy(_ remedy: StudioRemedy) {
        switch remedy {
        case .retry:
            let words = studio.slot.promptDraft
            if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            studio.submit(prompt: words)
        case .wake:
            studio.checkMachine(force: true)
        case .useEngine(let engine):
            studio.choose(engine: engine)
            let words = studio.slot.promptDraft
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { studio.submit(prompt: words) }
        case .machine:
            presentMachine(from: imageStage)
        }
    }

    private func drop(_ drop: StudioDrop) {
        StudioDrop.hold(drop, in: studio) { [weak self] held in
            guard held else { return }
            self?.imageDock.focusWords()
        }
    }

    func presentMachine(from anchor: NSView) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = StudioMachineSheet(studio: studio)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = pop
    }
}
