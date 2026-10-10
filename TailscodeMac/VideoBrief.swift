import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// A clip's brief, as the dock edits it: `ForgeRunner`'s board seen through the seam the dock draws
/// every lane's brief through. The words, the pills and the start-from picture are the board's own —
/// the runner above the window is what holds them — and this adds the three things the board does
/// not: the helper that writes the caption, the machine's gallery a first frame can be picked from,
/// and what a drop means. Nothing here decides a word; every sentence is Core's.
@MainActor
final class VideoBrief: StudioBriefing {
    enum Change: Equatable {
        case state
        case rewrite
    }

    let runner: ForgeRunner
    var noticeHandler: ((String) -> Void)?
    var onSetup: (() -> Void)?
    var onChange: ((Change) -> Void)?

    private(set) var draft: ImageGenRewriteDraft?
    private(set) var helperServers: [ImageGenHelperServer] = []
    private(set) var surveying = false
    private let rewriter = ImageGenRewriter()
    private var gallery: MacImageLibrary
    private var galleryEndpoint: ImageGenEndpoint
    private var galleryWatchers: [ObjectIdentifier: GalleryWatcher] = [:]

    private struct GalleryWatcher {
        weak var owner: AnyObject?
        let notify: @MainActor () -> Void
    }

    init(runner: ForgeRunner) {
        self.runner = runner
        let endpoint = Self.galleryEndpoint(for: runner)
        galleryEndpoint = endpoint
        gallery = MacImageLibrary(endpoint: endpoint)
        wireGallery()
    }

    private static func galleryEndpoint(for runner: ForgeRunner) -> ImageGenEndpoint {
        runner.endpoint.map { ImageGenEndpoint(sharing: $0) } ?? ImageGenEndpoint(host: "127.0.0.1")
    }

    private var board: ForgeBoard { runner.board }

    var wordsPlaceholder: String { Localized.text("Describe a clip, or drop a picture to start it from") }

    var goTitle: String { Localized.text("Render") }

    var draftWords: String { board.recipe.prompt }

    var isBusy: Bool { runner.isRendering }

    var estimateLine: String { StudioVideoChips.estimate(board: board) }

    var startEmptyTitle: String { ForgeField.frame.label }

    var startEmptyHint: String { ForgeWords.frameHint }

    /// The machine's pictures, which is where a first frame can come from without anything
    /// travelling. One ComfyUI holds both model sets, so it is the same folder the Image lane shows
    /// when the Studio is pointed at the same machine; it follows the renderer when that moves.
    var library: MacImageLibrary {
        let wanted = Self.galleryEndpoint(for: runner)
        if wanted != galleryEndpoint {
            gallery.cancel()
            gallery.onChange = nil
            galleryEndpoint = wanted
            gallery = MacImageLibrary(endpoint: wanted)
            wireGallery()
        }
        return gallery
    }

    private func wireGallery() {
        gallery.onChange = { [weak self] _ in
            guard let self else { return }
            self.galleryWatchers = self.galleryWatchers.filter { $0.value.owner != nil }
            for watcher in self.galleryWatchers.values { watcher.notify() }
        }
    }

    func watchLibrary(_ owner: AnyObject, _ block: @escaping @MainActor () -> Void) {
        galleryWatchers[ObjectIdentifier(owner)] = GalleryWatcher(owner: owner, notify: block)
    }

    func unwatchLibrary(_ owner: AnyObject) {
        galleryWatchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    var startHold: StudioStartHold? {
        guard let frame = board.recipe.frame else { return nil }
        let runner = self.runner
        let gallery = library
        switch frame {
        case .file(let path):
            return StudioStartHold(
                id: "file:" + path, name: frame.label, tooltip: frame.detail,
                thumbnail: {
                    await Task.detached {
                        FileManager.default.contents(atPath: path).flatMap {
                            MacImageLibrary.downsample($0, longestSide: 160)
                        }
                    }.value
                })
        case .kept(let name):
            return StudioStartHold(
                id: "kept:" + name, name: frame.label, tooltip: frame.detail,
                thumbnail: {
                    guard let item = gallery.items.first(where: { $0.annotatedName == name }),
                        let image = await gallery.thumbnail(of: item)
                    else { return nil }
                    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                })
        case .clipEnd(let asset):
            return StudioStartHold(
                id: "clip:" + asset.annotatedName, name: frame.label, tooltip: frame.detail,
                thumbnail: {
                    guard let image = await MacClipPosters.poster(for: asset, via: runner) else {
                        return nil
                    }
                    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                })
        }
    }

    func rememberDraft(_ words: String) {
        runner.describe(words)
    }

    /// One render of what the board holds. The board's own `begin` answers *play* once a clip has
    /// landed, which is right for a row and wrong for the button that renders: this asks for the
    /// next clip from what is in the boxes, and says where to go when there is no machine to ask.
    func submit(prompt: String) {
        runner.describe(prompt)
        guard runner.endpoint != nil else {
            onSetup?()
            return
        }
        guard board.recipe.isRenderable, !runner.isRendering else { return }
        MacHaptics.shared.play(.send)
        runner.start(board.recipe)
    }

    func stop() {
        runner.stop()
    }

    var helper: ImageGenHelper? { ImageGenStore.helper() }

    var enhancing: Bool { draft?.isWriting == true }

    func enhance(_ brief: String, instruction: String?) {
        let words = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !enhancing else { return }
        let previous = instruction == nil ? nil : draft?.written
        let context = ForgeRewriteContext(
            recipe: board.recipe, sizeChosen: board.sizeChosen, instruction: instruction,
            previous: previous)
        let near = runner.endpoint.map { ImageGenEndpoint(sharing: $0) }
        rewriter.start(
            brief: words, ask: context.ask(words), filed: helper, near: near,
            onHelper: { found in
                Task { @MainActor in ImageGenStore.remember(helper: found) }
            },
            onChange: { [weak self] draft in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let draft else {
                        self.draft = nil
                        self.onChange?(.state)
                        self.noticeHandler?(ImageGenRewriteWords.noneFoundTitle)
                        return
                    }
                    let growing = self.draft?.isWriting == true && draft.isWriting
                    self.draft = draft
                    self.onChange?(growing ? .rewrite : .state)
                }
            })
        draft = nil
        onChange?(.rewrite)
    }

    func dismissRewrite() {
        rewriter.cancel()
        draft = nil
        onChange?(.state)
    }

    /// Takes the shape a writer asked for when taking its words. A clip that continues another has
    /// that clip's own shape, and a size somebody chose by hand is kept — the board decides both.
    func followWriter(aspect: ImageGenAspect?) {
        guard let aspect, board.recipe.frame?.isClipEnd != true else { return }
        runner.follow(size: ForgeSize.following(aspect))
    }

    func surveyHelpers() {
        guard !surveying else { return }
        surveying = true
        onChange?(.state)
        let near = runner.endpoint.map { ImageGenEndpoint(sharing: $0) }
        Task { [weak self] in
            let servers = await Task.detached { await ImageGenHelperFinder.survey(near: near) }.value
            guard let self else { return }
            self.surveying = false
            self.helperServers = servers
            if let found = ImageGenHelperFinder.preferred(across: servers),
                self.helper?.yields(to: found) ?? true
            {
                ImageGenStore.remember(helper: found)
            }
            self.onChange?(.state)
        }
    }

    func setHelper(_ helper: ImageGenHelper?) {
        var chosen = helper
        chosen?.chosenByHand = true
        ImageGenStore.remember(helper: chosen)
        onChange?(.state)
    }

    func toggleHelper() {
        guard var current = helper else { return }
        current.enabled.toggle()
        ImageGenStore.remember(helper: current)
        onChange?(.state)
    }

    /// A rewrite put on the card by hand, for a state staged without a helper to write one.
    func stage(draft staged: ImageGenRewriteDraft?) {
        guard staged != nil || draft != nil else { return }
        draft = staged
        onChange?(.state)
    }

    /// Lets go of a rewrite still being written. The Studio's panel closing is not a reason to
    /// stop one; leaving the app is.
    func release() {
        rewriter.cancel()
    }

    func chips() -> [StudioChip] {
        StudioVideoChips.read(board: board)
    }

    func toggle(_ chip: StudioChip) {}

    func menu(for chip: StudioChip, gallery: @escaping @MainActor () -> Void) -> NSMenu? {
        guard case .forge(let field) = chip.kind else { return nil }
        let menu = NSMenu()
        for choice in board.choices(of: field) {
            let item = ClosureMenuItem(title: choice.menuTitle) { [runner] in
                runner.pick(field, id: choice.id)
            }
            item.state = choice.selected ? .on : .off
            if !choice.detail.isEmpty { item.subtitle = choice.detail }
            menu.addItem(item)
        }
        return menu
    }

    func wordsField(for chip: StudioChip) -> StudioWordsField? {
        switch chip.kind {
        case .avoid:
            return StudioWordsField(
                title: ForgeField.negative.label, hint: ForgeWords.negativeIgnoredHint,
                placeholder: Localized.text("Nothing in particular"), current: board.recipe.negative
            ) { [runner] words in runner.avoid(words) }
        case .sound:
            return StudioWordsField(
                title: ForgeField.sound.label, hint: ForgeWords.soundHint,
                placeholder: ForgeWords.soundPlaceholder, current: board.recipe.sound
            ) { [runner] words in runner.hear(words) }
        default:
            return nil
        }
    }

    /// The doors a first frame comes through on a Mac — a file, the pasteboard, the machine's own
    /// gallery — and the end of a clip already made, which continues it. Letting go of the frame is
    /// one row.
    func fillStartMenu(_ menu: NSMenu, gallery: @escaping @MainActor () -> Void) {
        let file = ClosureMenuItem(title: ImageGenReferenceSource.files.title + "…") { [weak self] in
            self?.chooseFile()
        }
        file.image = StudioTheme.symbol(ImageGenReferenceSource.files.symbol, size: 12)
        file.subtitle = ForgeWords.pickFileHint
        menu.addItem(file)
        let paste = ClosureMenuItem(title: ImageGenReferenceSource.clipboard.title) { [weak self] in
            guard let drop = StudioDrop.read(.general) else { return }
            self?.hold(drop: drop) { _ in }
        }
        paste.image = StudioTheme.symbol(ImageGenReferenceSource.clipboard.symbol, size: 12)
        if StudioDrop.read(.general) == nil { paste.action = nil }
        menu.addItem(paste)
        let from = ClosureMenuItem(title: ImageGenReferenceSource.library.title + "…") { gallery() }
        from.image = StudioTheme.symbol(ImageGenReferenceSource.library.symbol, size: 12)
        menu.addItem(from)
        let clips = board.history.filter(\.isPlayable).prefix(3)
        if !clips.isEmpty {
            menu.addItem(.separator())
            for entry in clips {
                guard let asset = entry.asset else { continue }
                let item = ClosureMenuItem(title: ForgeWords.continueTitle(entry)) { [runner] in
                    runner.start(from: .clipEnd(asset))
                }
                item.subtitle = ForgeWords.continueHint
                item.image = StudioTheme.symbol("film", size: 12)
                menu.addItem(item)
            }
        }
        if board.recipe.frame != nil {
            menu.addItem(.separator())
            let none = ClosureMenuItem(title: ForgeWords.noFrameTitle) { [runner] in
                runner.start(from: nil)
            }
            none.image = StudioTheme.symbol("xmark.circle", size: 12)
            menu.addItem(none)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = ForgeField.frame.label
        panel.begin { [runner] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                runner.start(from: .file(url.path))
            }
        }
    }

    func releaseStart() {
        runner.start(from: nil)
    }

    /// What a drop means here: a picture is the clip's first frame, and a tile dragged out of this
    /// shelf is a clip, whose last frame the next one opens on.
    func hold(drop: StudioDrop, then done: @escaping @MainActor (Bool) -> Void) {
        StudioDrop.resolve(drop) { [weak self] picture in
            guard let self else { return done(false) }
            switch picture {
            case .tile(let id)?:
                guard let asset = self.board.history.first(where: { $0.id == id })?.asset else {
                    return done(false)
                }
                self.runner.start(from: .clipEnd(asset))
                done(true)
            case .path(let path)?:
                self.runner.start(from: .file(path))
                done(true)
            case .pixels(let data)?:
                guard let path = ImageGenFiles.stage(data, named: "dropped.png") else {
                    return done(false)
                }
                self.runner.start(from: .file(path))
                done(true)
            case nil:
                done(false)
            }
        }
    }

    func hold(gallery item: ImageGenLibraryItem) {
        let facts = library.facts(of: item)
        runner.start(from: .kept(item.annotatedName), width: facts?.width, height: facts?.height)
    }
}
