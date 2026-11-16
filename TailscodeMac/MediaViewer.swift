import AppKit
import CodingAgentKit
import TailscodeCore

/// The one viewer the app has: a sheet on the lights-down canvas that a gallery of the conversation's
/// pictures or a clip plays in, raised in the Tailscode window the way the Studio is and stacked on it
/// when it is opened from there. It is the same host (`SheetView`, `SheetPresenter`), so the scrim, the
/// motion, the keyboard, the focus trap and the accessibility are the Studio's and are not written twice.
///
/// One at a time: opening another picture while one is up points the gallery at it, with no motion, and a
/// clip opened over a gallery takes its place. Esc, ⌘W, Done and a press on the scrim close this sheet
/// and nothing beneath it.
@MainActor
final class MediaViewer {
    static let shared = MediaViewer()

    let presenter: SheetPresenter
    private(set) var surface: ViewerSurface?
    private let stack: SheetStack
    private var keyMonitor: Any?
    private var previousEar: ((String) -> Void)?
    private var listening = false
    private var toast: ((String) -> Void)?
    /// Where the conversation draws the pictures being shown, when they came from one.
    private var stands: ((String) -> PictureStand?)?
    /// Draws again the tile whose picture is in the viewer.
    private var putBack: (() -> Void)?

    init(stack: SheetStack = .shared) {
        self.stack = stack
        let sheet = SheetView(
            content: NSView(), toolbar: NSView(), dialogName: MediaViewerWords.dialogName,
            closeLabel: MediaViewerWords.closeLabel, lightsDown: true)
        presenter = SheetPresenter(sheet: sheet, stack: stack)
        presenter.onDismissed = { [weak self] in
            self?.surface?.leave()
            self?.flyHome()
        }
        presenter.onClosed = { [weak self] in self?.sheetClosed() }
    }

    var sheet: SheetView { presenter.sheet }

    var state: StudioSheetState { presenter.state }

    /// Raises the gallery on `items` at `startKey`, or, when a viewer is up, points it there.
    /// `stands` says where the conversation draws these pictures: with it the sheet arrives in
    /// place while the picture that was pressed flies out of its tile, and the page being shown
    /// flies home when the viewer closes (`PictureFlight`). Without it the sheet rises.
    func showPictures(
        items: [ImageViewer.Item], startKey: String, host: NSWindow?,
        fetch: @escaping (FileReference, String) -> Void,
        stands: ((String) -> PictureStand?)? = nil, toast: ((String) -> Void)?
    ) {
        guard !items.isEmpty else { return }
        takeOut(nil)
        self.stands = stands
        if let gallery = surface as? PictureGalleryView {
            gallery.retarget(items: items, startKey: startKey, fetch: fetch)
            present(gallery, host: host, toast: toast)
            takeOut(gallery.currentItem.key)
            return
        }
        let gallery = PictureGalleryView(items: items, startKey: startKey, fetch: fetch)
        gallery.onTurned = { [weak self, weak gallery] in
            guard let self, let gallery else { return }
            self.sheet.endFlight()
            gallery.setPageShown(true)
            self.takeOut(gallery.currentItem.key)
        }
        present(gallery, host: host, toast: toast)
    }

    /// One tile is out of the chat at a time: the one whose picture the viewer is showing.
    private func takeOut(_ key: String?) {
        putBack?()
        putBack = nil
        guard let key, let stand = stands?(key) else { return }
        stand.setOut(true)
        putBack = { stand.setOut(false) }
    }

    /// The flight of the page being shown, out of its tile or home to it, when that tile is in
    /// sight, the page is fitted whole and motion is allowed.
    private func flightPlan(opening: Bool) -> FlightPictureView.Plan? {
        guard !presenter.reducedMotion(), let gallery = surface as? PictureGalleryView,
            let stand = stands?(gallery.currentItem.key), let tile = stand.frame(in: sheet),
            let picture = stand.picture, let stage = gallery.pageFrame(in: sheet)
        else { return nil }
        return FlightPictureView.Plan(
            picture: picture, tile: tile, stage: stage, tileRadius: stand.radius, opening: opening)
    }

    /// Chooses how a rising sheet comes, once it is laid out in its window and before it moves: in
    /// place, with the pressed picture planned to fly, for pictures of a conversation; rising, as
    /// the Studio's sheet does, for everything else.
    private func chooseArrival(for surface: ViewerSurface) {
        sheet.endFlight()
        guard stands != nil, surface is PictureGalleryView else {
            sheet.arrival = .rise
            return
        }
        sheet.arrival = .inPlace
        sheet.layoutSubtreeIfNeeded()
        surface.arrive()
        guard let plan = flightPlan(opening: true) else {
            sheet.inPlaceSpans.arriving = PictureFlight.fadeDuration
            return
        }
        sheet.inPlaceSpans.arriving = PictureFlight.openDuration
        sheet.plan(plan)
    }

    /// Starts the planned flight out of the tile, in the same turn the sheet began to arrive.
    private func flyOut() {
        guard sheet.arrival == .inPlace, let gallery = surface as? PictureGalleryView else { return }
        takeOut(gallery.currentItem.key)
        guard let plan = flightPlan(opening: true) else { return }
        gallery.setPageShown(false)
        sheet.fly(plan) { [weak self, weak gallery] in
            gallery?.setPageShown(true)
            self?.sheet.endFlight()
        }
    }

    /// The sheet is about to leave: the page being shown flies home when its tile is in sight,
    /// and the sheet fades where it stands when it is not.
    private func flyHome() {
        guard sheet.arrival == .inPlace else { return }
        sheet.endFlight()
        guard let plan = flightPlan(opening: false) else {
            sheet.inPlaceSpans.leaving = PictureFlight.fadeDuration
            return
        }
        sheet.inPlaceSpans.leaving = PictureFlight.closeDuration
        (surface as? PictureGalleryView)?.setPageShown(false)
        sheet.fly(plan) {}
    }

    /// Raises the player on a clip. `save` and `share` are the lane's own, so the clip is saved and shared
    /// exactly as it is from the shelf; a save reports through the viewer, which covers the Studio's own notice.
    func play(
        clip url: URL, title: String, host: NSWindow?,
        save: @escaping (@escaping @MainActor (String) -> Void) -> Void, share: @escaping (NSView) -> Void,
        toast: ((String) -> Void)? = nil
    ) {
        present(ClipPlayerView(url: url, title: title, save: save, share: share), host: host, toast: toast)
    }

    private func present(_ next: ViewerSurface, host: NSWindow?, toast: ((String) -> Void)?) {
        guard let window = presentingWindow(preferring: host) else { return }
        self.toast = toast
        let previous = surface
        if previous !== next {
            previous?.leave()
            previous?.finish()
            next.onClose = { [weak self] in self?.presenter.dismiss() }
            next.onSay = { [weak self] text in self?.notify(text) }
            surface = next
            sheet.setContent(next, toolbar: next.toolbar)
        }
        var arrived = false
        let effect = presenter.show(
            in: window,
            prepare: {
                self.chooseArrival(for: next)
                arrived = self.sheet.arrival == .inPlace
            },
            ready: { _ = window.makeFirstResponder(next.focusTarget) })
        switch effect {
        case .animateIn:
            listen()
            flyOut()
        case .changeLane:
            _ = window.makeFirstResponder(next.focusTarget)
        default:
            if state == .closed {
                surface = nil
                next.finish()
                sheet.setContent(NSView(), toolbar: NSView())
                return
            }
        }
        sheet.layoutSubtreeIfNeeded()
        if !arrived { next.arrive() }
    }

    /// The window the viewer rises in: the one a sheet is already standing in — a viewer opened over the
    /// Studio is in the Studio's window whichever window asked — else the one asked for, else the key
    /// Tailscode window.
    private func presentingWindow(preferring host: NSWindow?) -> NSWindow? {
        if let standing = stack.presenters.last?.sheet.host { return standing }
        if let host, host.contentView != nil { return host }
        if let key = NSApp.keyWindow, key.windowController is MainWindowController { return key }
        return NSApp.orderedWindows.first { $0.windowController is MainWindowController && $0.isVisible }
    }

    /// Says something in the viewer, which covers every place a notice would otherwise appear; once the
    /// sheet has gone, in the notice the caller handed over, because a save can finish after Done.
    func notify(_ text: String) {
        if state.capturesKeys, let surface { surface.notify(text) } else { toast?(text) }
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        previousEar = ImageStore.shared.onStored
        ImageStore.shared.onStored = { [weak self] key in
            self?.previousEar?(key)
            (self?.surface as? PictureGalleryView)?.stored(key)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let pressed = event
            let consumed = MainThread.call { self.consumes(pressed) }
            return consumed ? nil : event
        }
    }

    private func sheetClosed() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if listening { ImageStore.shared.onStored = previousEar }
        previousEar = nil
        listening = false
        takeOut(nil)
        stands = nil
        sheet.endFlight()
        sheet.arrival = .rise
        surface?.finish()
        surface = nil
        toast = nil
        sheet.setContent(NSView(), toolbar: NSView())
    }

    /// Reads a key event against the viewer's table when the viewer is what holds the keyboard. A key it
    /// has no meaning for goes on to whoever has focus, a player's own controls among them.
    private func consumes(_ event: NSEvent) -> Bool {
        guard presenter.ownsKeys, event.window === sheet.host else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = ViewerKey.match(
            keyCode: event.keyCode, character: event.charactersIgnoringModifiers?.lowercased() ?? "",
            command: flags.contains(.command), shift: flags.contains(.shift),
            other: flags.contains(.option) || flags.contains(.control))
        guard let key else { return false }
        return press(key)
    }

    /// What a key does in the viewer: Esc closes it, everything else is the surface's.
    @discardableResult
    func press(_ key: ViewerKey) -> Bool {
        guard presenter.state.capturesKeys else { return false }
        if key == .close {
            presenter.dismiss()
            return true
        }
        return surface?.handle(key) ?? false
    }

    #if DEBUG
        func hold(at progress: Double, closing: Bool) {
            if sheet.arrival == .inPlace, let plan = flightPlan(opening: !closing) {
                (surface as? PictureGalleryView)?.setPageShown(false)
                sheet.plan(plan)
            }
            presenter.hold(at: progress, closing: closing)
        }

        /// Where the picture in the air is drawn, for a check that reads a held frame.
        var flightFrame: NSRect? { sheet.flightFrame }
    #endif
}

/// The conversation's pictures, opened full size. The name and the call stay what they were when this was
/// a window of its own; what it opens is `MediaViewer`'s sheet.
@MainActor
enum ImageViewer {
    struct Item {
        let key: String
        let name: String
        let reference: FileReference
    }

    /// Every picture of the conversation in reading order — a lone picture's row, then each tile
    /// of a gallery under its own key — so a press on any tile starts the viewer on that picture
    /// and the arrows page through the rest.
    static func items(in rows: [TranscriptRow]) -> [Item] {
        rows.flatMap { row -> [Item] in
            let pictures: [(key: String, reference: FileReference)] = {
                switch row.kind {
                case .file(let reference, _, _): return [(row.key, reference)]
                case .pictures(let group): return group.map { ($0.key, $0.reference) }
                default: return []
                }
            }()
            return pictures.compactMap { picture in
                guard (picture.reference.mime ?? "").hasPrefix("image/") else { return nil }
                let name =
                    picture.reference.filename
                    ?? picture.reference.path.map {
                        URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent
                    }
                    ?? "image"
                return Item(key: picture.key, name: name, reference: picture.reference)
            }
        }
    }

    /// One gallery at a time: opening a second picture points the one that is up at it.
    static func present(
        items: [Item], startKey: String, host: NSWindow?,
        fetch: @escaping (FileReference, String) -> Void,
        stands: ((String) -> PictureStand?)? = nil, toast: ((String) -> Void)?
    ) {
        MediaViewer.shared.showPictures(
            items: items, startKey: startKey, host: host, fetch: fetch, stands: stands, toast: toast)
    }
}
