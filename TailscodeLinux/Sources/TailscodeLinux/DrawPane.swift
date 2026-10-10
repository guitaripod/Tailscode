import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A picture being painted: the Studio's image lane, as a pane in the split tree and as a window
/// of its own. The same anatomy serves both — the stage fills everything above the dock, the
/// shelf is a rail beside it or a strip above the dock depending on the room, and the brief is
/// one dock under the stage — and a pane in the grid splits, resizes, zooms and closes with the
/// same verbs as any other, holding one endpoint and one prompt small enough to survive a restart.
///
/// The stage is the point. A render is a minute or two of somebody's card, so the sketch the
/// machine streams fills the stage for all of it, the progress line runs along the stage's bottom
/// edge, and the finished picture arrives into the rectangle the sketch used — the shape is
/// decided before the render starts — through one crossfade. The verbs a finished picture offers
/// are docked under it and hold their room while it is painting. What the machine has made is the
/// shelf, thumbnails only for the tiles in view; the machine itself is a pill that says whether it
/// can paint, replacing a note about what a render costs the grid.
///
/// Everything this view says is Core's: the chips are `StudioChips` over `ImageGenField`, the
/// words for a wait are `ImageGenProgress`, the verbs are `ImageGenAction.offered`, the arithmetic
/// of the room is `StudioArrangement`. Nothing here is state — the slot, the running job, the
/// library and the pictures it decoded live in ``ImageStudio``.
final class DrawPane: @unchecked Sendable {
    /// Everything that outlives this view: the slot, the running job, the library and the
    /// pictures it decoded.
    let studio: ImageStudio
    var onChange: (@Sendable () -> Void)?
    /// Something worth telling the person that this view has no room to say — a file written, a
    /// picture put on the clipboard. Whoever hosts the pane owns where a notice appears.
    var onNotice: (@Sendable (String) -> Void)?
    var slot: ImageGenSlot { studio.slot }
    var textures: [String: UInt] { studio.textures }

    let fills: Bool
    /// The room: the pill's bar, the stage, the shelf and the dock, put where the space says.
    let chrome: StudioFrame
    var root: UnsafeMutablePointer<GtkWidget> { chrome.root }
    var machine: StudioMachineButton { chrome.machine }
    var shell: StudioStageShell { chrome.shell }
    var shelf: StudioShelfView { chrome.shelf }
    var dock: StudioDock { chrome.dock }

    let faces = gtk_stack_new()!
    let emptyOverlay = gtk_overlay_new()!
    let backdrop = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let emptyTitle = Gtk.label("", css: "draw-empty-title", selectable: false)
    let emptyBody = Gtk.label("", css: "dim", wrap: true, selectable: false)
    let frame = gtk_aspect_frame_new(0.5, 0.5, 1.5, 0)!
    let art = gtk_stack_new()!
    let sketchOverlay = gtk_overlay_new()!
    let sketchPicture = gtk_picture_new()!
    let sketchBadge = Gtk.label("", css: "studio-badge", selectable: false)
    let mainSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let heldSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    var mainKey: String?
    var heldKey: String?
    var backdropKey: String?
    var arrivedKey: String?
    var fadeEnds: Date?

    let engineChip: StudioChip
    let aspectChip: StudioChip
    let sizeChip: StudioChip
    let detailChip: StudioChip
    let cutoutChip: StudioChip
    let avoidChip: StudioChip
    let seedChip: StudioChip
    let referenceChip: StudioChip
    let craftChip: StudioChip
    let avoidEntry = gtk_entry_new()!
    let helperMenu: UnsafeMutablePointer<GtkWidget>
    var beforeEnhance: String?

    let rewrite = StudioRewriteCard()
    let slotView: StudioSlotView

    var studioObserver: NSObjectProtocol?
    var sketchObserver: NSObjectProtocol?
    var rewriteObserver: NSObjectProtocol?
    var progressObserver: NSObjectProtocol?
    var storeObserver: NSObjectProtocol?
    var ticking = false
    var entries: [StudioShelfEntry] = []
    var selectedTile: String?
    var referenceTextures: [String: UInt] = [:]
    var loadingReferences: Set<String> = []
    var emptyColumn: UnsafeMutablePointer<GtkWidget>!
    var starters: UnsafeMutablePointer<GtkWidget>!

    /// Where the renders actually run. A slot is pointed at one machine; the address survives a
    /// restart and the pane re-checks the server when it wakes.
    convenience init(endpoint: ImageGenEndpoint?) {
        self.init(studio: ImageStudio(endpoint: endpoint))
    }

    /// `fills` is the difference between a slot and a window: a pane in the grid opens a picture
    /// full size in a viewer beside it, while a window gives the picture its whole room in place,
    /// because a window opened over a window is how the pointer was lost.
    init(studio: ImageStudio, fills: Bool = false) {
        self.studio = studio
        self.fills = fills
        let held = studio
        let me = Weak<DrawPane>(nil)
        engineChip = StudioChip.menu {
            let sighting = held.sighting
            return ImageGenEngine.allCases.map { engine in
                let missing = sighting.map { $0.reachable && !$0.available(engine) } ?? false
                return (
                    title: engine.label,
                    detail: missing
                        ? ImageGenWords.engineUnavailable(
                            engine, missing: sighting?.missing(for: engine).count ?? 0)
                        : engine.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(engine: engine) } }
                )
            }
        }
        aspectChip = StudioChip.menu {
            ImageGenAspect.allCases.map { aspect in
                (
                    title: "\(aspect.glyph)  \(aspect.short) · \(aspect.ratioLabel)",
                    detail: aspect.label(held.slot.size),
                    action: { @Sendable in Gtk.onMain { held.choose(aspect: aspect) } }
                )
            }
        }
        sizeChip = StudioChip.menu {
            ImageGenSize.allCases.map { size in
                (
                    title: "\(size.title) · \(held.slot.aspect.label(size))",
                    detail: size.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(size: size) } }
                )
            }
        }
        detailChip = StudioChip.menu {
            ImageGenDetail.allCases.map { detail in
                (
                    title: detail.short, detail: detail.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(detail: detail) } }
                )
            }
        }
        cutoutChip = StudioChip.button { Gtk.onMain { held.setCutout(!held.slot.cutout) } }
        seedChip = StudioChip.button { Gtk.onMain { held.toggleSeedHold() } }
        let avoidCard = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        avoidChip = StudioChip.popover(content: avoidCard)
        referenceChip = StudioChip.menu { me.value?.referenceRows() ?? [] }
        craftChip = StudioChip.menu { me.value?.craftRows() ?? [] }
        slotView = StudioSlotView(
            rows: { me.value?.referenceRows() ?? [] },
            onRemove: {
                guard let pane = me.value, let first = pane.slot.references.first else { return }
                pane.studio.release(first.path)
                pane.resetPlaceholder()
            })
        let helperHeld = Weak<ImageStudio>(studio)
        helperMenu = Gtk.menuButton("", css: ["draw-chip"]) {
            guard let studio = helperHeld.value else { return [] }
            return DrawPane.helperSections(studio)
        }
        chrome = StudioFrame(helper: helperMenu, window: fills)
        me.value = self
        buildAvoidCard(avoidCard)
        buildStage()
        buildShelf()
        buildSlot()
        buildChips()
        wireDock()
        observe()
        chrome.arrange(width: 1180, height: 820)
        render()
        studio.checkMachine()
        studio.library.refresh()
        if !(studio.helper?.isChosenByHand ?? false) { studio.surveyHelpers() }
    }

    /// Which model writes, on which machine: every door that answered, grouped by machine, with
    /// the current one marked. Sits beside Enhance in both shapes of this surface.
    static func helperSections(_ studio: ImageStudio) -> [Gtk.MenuSection] {
        HelperMenu.sections(studio)
    }

    /// Wires the chips once the pane exists. Kept as a call the hosts make, as it always was; the
    /// work is done in `init`, where a closure over `self` can finally be built.
    func wireChips() {}

    var target: ImageGenEndpoint { studio.endpoint }
    var isAsking: Bool { slot.isAsking }
    var isBusy: Bool { slot.isBusy }

    /// One line for the headless driver: the phase, the chips, and what the stage is holding.
    var summary: String { studio.summary }

    func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    func focusPrompt() {
        dock.focus()
    }

    /// The words, wherever they came from.
    var promptText: String {
        get { dock.words }
        set { dock.words = newValue }
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a
    /// keystroke does rather than a private one that could drift from it.
    func driverType(_ text: String) {
        focusPrompt()
        promptText = text
        wordsChanged()
    }

    func driverSubmit() { submit() }

    /// The harness's way in to the one control that writes words, so a headless run exercises the
    /// same path a press does.
    func driverEnhance() { enhancePressed() }

    func driverUseRewrite() { useRewrite() }

    var hostWindow: UnsafeMutablePointer<GtkWidget>? {
        guard let root = gtk_widget_get_root(ptr(root)) else { return nil }
        return UnsafeMutablePointer(root)
    }

    /// Lets go of the view. A studio of this pane's own dies with it; the shared one keeps
    /// painting, because closing a window is not cancelling a render.
    func shutdown() {
        for token in [studioObserver, sketchObserver, rewriteObserver, progressObserver, storeObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        studioObserver = nil
        sketchObserver = nil
        rewriteObserver = nil
        progressObserver = nil
        storeObserver = nil
        studio.onNotice = nil
        for bits in referenceTextures.values {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        referenceTextures = [:]
        dock.tray.release()
        if studio !== ImageStudio.shared { studio.release() }
    }

    private func observe() {
        studioObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in
                self?.render()
                self?.onChange?()
            }
        }
        sketchObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.previewDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.adoptSketch() }
        }
        rewriteObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.rewriteDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.refreshRewrite() }
        }
        progressObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.progressDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.refreshProgressOnly() }
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: ImageGenStore.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.refreshMachine() }
        }
        studio.onNotice = { [weak self] line in
            Gtk.onMain { [weak self] in self?.onNotice?(line) }
        }
    }

    func render() {
        refreshChips()
        refreshDock()
        refreshStage()
        refreshShelf()
        refreshMachine()
    }

    /// For the headless driver: where the room has been put, what the stage and its verbs and
    /// progress line are doing, and what the shelf holds.
    var studioSummary: String {
        "\(chrome.summary) library=\(studio.library.heldThumbnails) faces=\(visibleFace) art=\(visibleArt) picture=[\(chrome.bounds(of: art))] stagebox=[\(chrome.bounds(of: shell.root))]"
    }

    /// For the headless driver: which face of the stack the stage shows and whether the one
    /// crossfade is running.
    var arrivalSummary: String {
        "art=\(visibleArt) fading=\(gtk_stack_get_transition_running(op(art)) != 0) arrived=\(arrivedKey.map { String($0.suffix(12)) } ?? "none")"
    }

    var visibleFace: String {
        gtk_stack_get_visible_child_name(op(faces)).map { String(cString: $0) } ?? "-"
    }

    var visibleArt: String {
        gtk_stack_get_visible_child_name(op(art)).map { String(cString: $0) } ?? "-"
    }
}

/// A weak hold on a view, so a popover built once can reach the pane that owns it without
/// keeping it alive or tripping the sendability checker on a captured `self`.
final class Weak<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
