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

    init(stack: SheetStack = .shared) {
        self.stack = stack
        let sheet = SheetView(
            content: NSView(), toolbar: NSView(), dialogName: MediaViewerWords.dialogName,
            closeLabel: MediaViewerWords.closeLabel, lightsDown: true)
        presenter = SheetPresenter(sheet: sheet, stack: stack)
        presenter.onDismissed = { [weak self] in self?.surface?.leave() }
        presenter.onClosed = { [weak self] in self?.sheetClosed() }
    }

    var sheet: SheetView { presenter.sheet }

    var state: StudioSheetState { presenter.state }

    /// Raises the gallery on `items` at `startKey`, or, when a viewer is up, points it there.
    func showPictures(
        items: [ImageViewer.Item], startKey: String, host: NSWindow?,
        fetch: @escaping (FileReference, String) -> Void, toast: ((String) -> Void)?
    ) {
        guard !items.isEmpty else { return }
        if let gallery = surface as? PictureGalleryView {
            gallery.retarget(items: items, startKey: startKey, fetch: fetch)
            present(gallery, host: host, toast: toast)
            return
        }
        present(PictureGalleryView(items: items, startKey: startKey, fetch: fetch), host: host, toast: toast)
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
        let effect = presenter.show(in: window, ready: { _ = window.makeFirstResponder(next.focusTarget) })
        switch effect {
        case .animateIn:
            listen()
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
        next.arrive()
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
            let consumed = MainActor.assumeIsolated { self.consumes(pressed) }
            return consumed ? nil : event
        }
    }

    private func sheetClosed() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if listening { ImageStore.shared.onStored = previousEar }
        previousEar = nil
        listening = false
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
            presenter.hold(at: progress, closing: closing)
        }
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

    /// One gallery at a time: opening a second picture points the one that is up at it.
    static func present(
        items: [Item], startKey: String, host: NSWindow?,
        fetch: @escaping (FileReference, String) -> Void, toast: ((String) -> Void)?
    ) {
        MediaViewer.shared.showPictures(items: items, startKey: startKey, host: host, fetch: fetch, toast: toast)
    }
}
