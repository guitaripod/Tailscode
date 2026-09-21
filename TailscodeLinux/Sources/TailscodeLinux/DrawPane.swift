import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A picture being painted inside the split tree. The pane is a pane like any other — it splits,
/// resizes, zooms and closes with the same verbs — and what it holds is one endpoint plus one
/// prompt, small enough to survive a restart exactly as a stream or a page does.
///
/// The surface is a fusion of the three image UIs worth stealing from: the prompt bar lives at
/// the bottom where the hands already are (OpenAI), the chips that shape the ask sit in one row
/// above it and never open a menu (Grok), and the picture that comes back is the pane — full
/// bleed, click to open it full size, with the words that made it one glance away (Gemini).
/// Everything the model is asked, the pane says in its own body: engine, aspect, mode, and what
/// each one costs. Under all of that sits the machine's own shelf of everything it has kept — a
/// picture made here is simply the newest tile in it.
final class DrawPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    /// Everything that outlives this view: the slot, the running job, the library and the
    /// pictures it decoded.
    let studio: ImageStudio
    private var onChange: (@Sendable () -> Void)?
    /// Something worth telling the person that this view has no room to say — a file written, a
    /// picture put on the clipboard. Whoever hosts the pane owns where a notice appears.
    var onNotice: (@Sendable (String) -> Void)?
    private var studioObserver: NSObjectProtocol?
    var slot: ImageGenSlot { studio.slot }

    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private(set) var entry = gtk_entry_new()!
    private let chipRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let moreRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let engineChip: UnsafeMutablePointer<GtkWidget>
    private let aspectChip: UnsafeMutablePointer<GtkWidget>
    private let sizeChip: UnsafeMutablePointer<GtkWidget>
    private let detailChip: UnsafeMutablePointer<GtkWidget>
    private let cutoutChip: UnsafeMutablePointer<GtkWidget>
    private let seedChip: UnsafeMutablePointer<GtkWidget>
    private let moreChip: UnsafeMutablePointer<GtkWidget>
    private let enhanceChip: UnsafeMutablePointer<GtkWidget>
    /// Which model writes, on which machine: every door that answered, grouped by machine, with
    /// the current one marked. Sits beside Enhance in both shapes of this surface.
    private let helperMenu: UnsafeMutablePointer<GtkWidget>
    /// The words as they were before a rewrite, kept for exactly one undo — a helper that
    /// misread the brief must never cost the sentence a person actually wrote.
    private var beforeEnhance: String?
    /// The rewrite card: who is writing, the paragraph as it lands, and the three verbs.
    private let rewriteBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let rewriteHead = Gtk.label("", css: "draw-rewrite-head", wrap: true, selectable: false)
    private let rewriteBody = gtk_text_view_new()!
    private let rewriteInstruction = gtk_entry_new()!
    private let rewriteVerbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let rewriteUse: UnsafeMutablePointer<GtkWidget>
    private let rewriteKeep: UnsafeMutablePointer<GtkWidget>
    private let rewriteAgain: UnsafeMutablePointer<GtkWidget>
    private let rewriteStop: UnsafeMutablePointer<GtkWidget>
    private var rewriteShown = ""
    private var rewriteWasWriting = false
    /// The sketch on the stage while a render runs, swapped in place for each frame the machine
    /// sends rather than rebuilt: a frame changes one paintable, never the layout around it.
    private var sketchPicture: UnsafeMutablePointer<GtkWidget>?
    private var sketchObserver: NSObjectProtocol?
    private var rewriteObserver: NSObjectProtocol?
    private var progressObserver: NSObjectProtocol?
    private var surveyShown: Date?
    private let referenceChip: UnsafeMutablePointer<GtkWidget>
    private let renderButton: UnsafeMutablePointer<GtkWidget>
    /// The pictures the next render works from, shown as what they are rather than as a count.
    private let referenceStrip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let avoidEntry = gtk_entry_new()!
    private let hintBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    /// Whether the second row of decisions is open. A person who works with an avoid list keeps
    /// it open; everyone else never sees it.
    private var showsMore = false
    private let promptRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let stagePicture = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let factsLabel = Gtk.label("", css: "draw-facts", selectable: true)
    private let captionLabel = Gtk.label("", css: "draw-caption", wrap: true, selectable: true)
    private let keptHintLabel = Gtk.label("", css: "dim", wrap: true, selectable: false)
    private let actionRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let zoomHint = Gtk.label("", css: "dim", selectable: false)
    private let statusLabel = Gtk.label("", css: "draw-status", wrap: true, selectable: false)
    private let progressLabel = Gtk.label("", css: "draw-progress", selectable: false)
    private let progressBar = gtk_progress_bar_new()!
    private let noticeLabel = Gtk.label("", css: "video-notice", wrap: true, selectable: false)

    private let shelfBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let shelfHeadingLabel = Gtk.label("", css: "draw-shelf-heading", selectable: false)
    private let shelfCountLabel = Gtk.label("", css: "dim", selectable: false)
    private let shelfRefreshButton = Gtk.button(
        ImageGenLibraryWords.refresh, css: ["flat"], onClick: {})
    private let shelfStatusLabel = Gtk.label("", css: "dim", wrap: true, selectable: false)
    private let shelfFlowBox = gtk_flow_box_new()!
    private let shelfScroller = gtk_scrolled_window_new()!

    private let fills: Bool

    /// The studio's own controls — the ask laid out as a form down the left, the shelf as a list
    /// down the right. Built only when `fills`; a slot in the grid keeps its chips.
    private let promptView = gtk_text_view_new()!
    private let countLabel = Gtk.label("", css: "draw-count", selectable: false)
    private let briefColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
    private let stageColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let shelfColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let progressRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let clockLabel = Gtk.label("", css: "draw-clock", selectable: false)
    private let underRow = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let shelfList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private var engineCards: [ImageGenEngine: UnsafeMutablePointer<GtkWidget>] = [:]
    private var aspectButtons: [ImageGenAspect: UnsafeMutablePointer<GtkWidget>] = [:]
    private var sizeButtons: [ImageGenSize: UnsafeMutablePointer<GtkWidget>] = [:]
    private var detailButtons: [ImageGenDetail: UnsafeMutablePointer<GtkWidget>] = [:]
    private let seedSwitch = gtk_switch_new()!
    private let seedDetailLabel = Gtk.label("", css: "draw-toggle-detail", wrap: true, selectable: false)
    private let cutoutSwitch = gtk_switch_new()!
    /// A switch being told what the slot holds must not be heard as the person flipping it.
    private var syncingSwitches = false
    private let keysLabel = Gtk.label("", css: "draw-keys", wrap: true, selectable: false)

    /// Whether the picture has the whole surface. A studio that is itself a modal may not open a
    /// window over itself — a modal transient for a modal takes the pointer away from the desktop
    /// on X11 — so full size happens here, in the room this surface already has.
    private var zoomed = false
    private var ticking = false
    private var textures: [String: UInt] { studio.textures }
    /// Where the renders actually run. A slot is pointed at one machine; the address survives a
    /// restart and the pane re-checks the server when it wakes.
    convenience init(endpoint: ImageGenEndpoint?) {
        self.init(studio: ImageStudio(endpoint: endpoint))
    }

    /// `fills` is the difference between a slot and a studio: a pane in the grid keeps its
    /// controls at the bottom where a transcript's would be, while a modal opened for this one
    /// job gives the picture the whole room.
    init(studio: ImageStudio, fills: Bool = false) {
        self.studio = studio
        self.fills = fills
        let held = studio
        engineChip = Gtk.menuButton("", css: ["draw-chip"]) {
            ImageGenEngine.allCases.map { engine in
                (
                    title: engine.label, detail: engine.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(engine: engine) } }
                )
            }
        }
        aspectChip = Gtk.menuButton("", css: ["draw-chip"]) {
            ImageGenAspect.allCases.map { aspect in
                (
                    title: "\(aspect.glyph)  \(aspect.short) · \(aspect.ratioLabel)",
                    detail: aspect.label(held.slot.size),
                    action: { @Sendable in Gtk.onMain { held.choose(aspect: aspect) } }
                )
            }
        }
        sizeChip = Gtk.menuButton("", css: ["draw-chip"]) {
            ImageGenSize.allCases.map { size in
                (
                    title: "\(size.title) · \(held.slot.aspect.label(size))",
                    detail: size.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(size: size) } }
                )
            }
        }
        detailChip = Gtk.menuButton("", css: ["draw-chip"]) {
            ImageGenDetail.allCases.map { detail in
                (
                    title: detail.short, detail: detail.detail,
                    action: { @Sendable in Gtk.onMain { held.choose(detail: detail) } }
                )
            }
        }
        cutoutChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        seedChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        moreChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        enhanceChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        let helperHeld = Weak<ImageStudio>(studio)
        helperMenu = Gtk.menuButton("", css: ["draw-chip"]) {
            guard let studio = helperHeld.value else { return [] }
            return DrawPane.helperSections(studio)
        }
        rewriteUse = Gtk.button(ImageGenRewriteWords.useTitle, css: ["draw-action", "draw-action-lead"], onClick: {})
        rewriteKeep = Gtk.button(ImageGenRewriteWords.keepTitle, css: ["draw-action"], onClick: {})
        rewriteAgain = Gtk.button(ImageGenRewriteWords.againTitle, css: ["draw-action"], onClick: {})
        rewriteStop = Gtk.button(ImageGenRewriteWords.stopTitle, css: ["draw-action", "danger"], onClick: {})
        referenceChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        renderButton = Gtk.button("", css: ["draw-go"], onClick: {})
        buildRewriteCard()
        buildRoot()
        render()
        refreshNotice()
        studio.checkMachine()
        studio.library.refresh()
        if !(studio.helper?.isChosenByHand ?? false) { studio.surveyHelpers() }
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
        studio.onNotice = { [weak self] line in
            Gtk.onMain { [weak self] in self?.onNotice?(line) }
        }
    }

    /// The picker's rows: every machine that answered, its models under it with the current one
    /// marked and the loaded ones saying so; then the look-again row and the off switch. A menu
    /// opened before any survey starts one, so the first opening is never empty for long.
    private static func helperSections(_ studio: ImageStudio) -> [Gtk.MenuSection] {
        let current = studio.helper
        var sections: [Gtk.MenuSection] = []
        if studio.helperServers.isEmpty, !studio.surveying { Gtk.onMain { studio.surveyHelpers() } }
        for server in studio.helperServers {
            let rows = server.models.map { model in
                Gtk.MenuRow(
                    title: model.label, detail: model.detail,
                    on: current?.address == server.address && current?.model == model.id,
                    action: {
                        Gtk.onMain {
                            studio.setHelper(ImageGenHelper(address: server.address, model: model))
                        }
                    })
            }
            sections.append(Gtk.MenuSection(heading: server.heading, rows: rows))
        }
        var tail: [Gtk.MenuRow] = []
        if studio.surveying {
            tail.append(Gtk.MenuRow(title: ImageGenRewriteWords.lookingTitle, detail: nil))
        } else if studio.helperServers.isEmpty {
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.noneFoundTitle,
                    detail: ImageGenRewriteWords.noneFoundHint))
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.lookAgainTitle,
                    detail: ImageGenRewriteWords.lookAgainHint,
                    action: { Gtk.onMain { studio.surveyHelpers() } }))
        } else {
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.lookAgainTitle,
                    detail: ImageGenRewriteWords.lookAgainHint,
                    action: { Gtk.onMain { studio.surveyHelpers() } }))
        }
        if let current {
            tail.append(
                Gtk.MenuRow(
                    title: current.enabled
                        ? ImageGenRewriteWords.offTitle : ImageGenRewriteWords.onTitle,
                    detail: current.enabled ? ImageGenWords.helperOffHint : current.displayHost,
                    action: { Gtk.onMain { studio.toggleHelper() } }))
        }
        sections.append(Gtk.MenuSection(heading: nil, rows: tail))
        return sections
    }

    /// The card under the words. Built once; ``refreshRewrite()`` tells it what changed.
    private func buildRewriteCard() {
        Gtk.addClass(rewriteBox, "draw-rewrite")
        gtk_widget_set_visible(rewriteBox, 0)
        gtk_label_set_xalign(op(rewriteHead), 0)
        gtk_label_set_max_width_chars(op(rewriteHead), 64)
        gtk_box_append(ptr(rewriteBox), rewriteHead)
        gtk_text_view_set_editable(ptr(rewriteBody), 0)
        gtk_text_view_set_cursor_visible(ptr(rewriteBody), 0)
        gtk_text_view_set_wrap_mode(ptr(rewriteBody), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(rewriteBody), 10)
        gtk_text_view_set_right_margin(ptr(rewriteBody), 10)
        gtk_text_view_set_top_margin(ptr(rewriteBody), 8)
        gtk_text_view_set_bottom_margin(ptr(rewriteBody), 8)
        Gtk.addClass(rewriteBody, "draw-rewrite-body")
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), 150)
        gtk_scrolled_window_set_max_content_height(op(scroller), 260)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), rewriteBody)
        Gtk.addClass(scroller, "draw-rewrite-scroller")
        gtk_box_append(ptr(rewriteBox), scroller)
        gtk_entry_set_placeholder_text(ptr(rewriteInstruction), ImageGenRewriteWords.instructionPlaceholder)
        Gtk.addClass(rewriteInstruction, "draw-avoid")
        gtk_widget_set_hexpand(rewriteInstruction, 1)
        gtk_widget_set_tooltip_text(rewriteInstruction, ImageGenRewriteWords.reviseTitle)
        gtk_box_append(ptr(rewriteBox), rewriteInstruction)
        gtk_widget_set_tooltip_text(rewriteUse, ImageGenRewriteWords.useHint)
        gtk_widget_set_tooltip_text(rewriteKeep, ImageGenRewriteWords.keepHint)
        gtk_widget_set_tooltip_text(rewriteAgain, ImageGenRewriteWords.againHint)
        for verb in [rewriteUse, rewriteAgain, rewriteKeep, rewriteStop] {
            gtk_box_append(ptr(rewriteVerbs), verb)
        }
        gtk_widget_set_halign(rewriteVerbs, GTK_ALIGN_START)
        gtk_box_append(ptr(rewriteBox), rewriteVerbs)
        Gtk.connect(UnsafeMutableRawPointer(rewriteUse), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.useRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteKeep), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.studio.dismissRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteAgain), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let draft = self.studio.draft else { return }
                self.studio.rewrite(draft.original)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteStop), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.studio.stopRewrite() }
        }
        Gtk.connect(UnsafeMutableRawPointer(rewriteInstruction), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.revisePressed() }
        }
    }

    /// Wires the chips once the pane exists — a closure over `self` cannot be built until every
    /// stored property is initialized, so the actions attach here rather than in `init`.
    func wireChips() {
        Gtk.connect(UnsafeMutableRawPointer(cutoutChip), "clicked") { [weak self] in
            guard let self else { return }
            self.studio.setCutout(!self.slot.cutout)
        }
        Gtk.connect(UnsafeMutableRawPointer(seedChip), "clicked") { [weak self] in
            self?.studio.toggleSeedHold()
        }
        Gtk.connect(UnsafeMutableRawPointer(enhanceChip), "clicked") { [weak self] in
            self?.enhancePressed()
        }
        Gtk.connect(UnsafeMutableRawPointer(moreChip), "clicked") { [weak self] in
            guard let self else { return }
            self.showsMore.toggle()
            self.render()
        }
        Gtk.connect(UnsafeMutableRawPointer(referenceChip), "clicked") { [weak self] in
            self?.referencePressed()
        }
        Gtk.connect(UnsafeMutableRawPointer(avoidEntry), "changed") { [weak self] in
            guard let self, let raw = gtk_editable_get_text(op(self.avoidEntry)) else { return }
            self.studio.setNegative(String(cString: raw))
        }
        Gtk.connect(UnsafeMutableRawPointer(renderButton), "clicked") { [weak self] in
            self?.renderPressed()
        }
        Gtk.connect(UnsafeMutableRawPointer(shelfRefreshButton), "clicked") { [weak self] in
            self?.studio.library.refresh()
        }
    }

    var target: ImageGenEndpoint { studio.endpoint }
    var isAsking: Bool { slot.isAsking }
    var isBusy: Bool { slot.isBusy }

    /// One line for the headless driver: the phase, the chips, and what the stage is holding.
    var summary: String { studio.summary }

    /// Types into the prompt as a person would, so the driver exercises the same path a
    /// keystroke does rather than a private one that could drift from it.
    func driverType(_ text: String) {
        focusPrompt()
        promptText = text
    }

    /// The words, wherever this surface keeps them: a one-line entry in a slot, a paragraph's
    /// worth of text view in the studio.
    private var promptText: String {
        get {
            if fills {
                let buffer = gtk_text_view_get_buffer(ptr(promptView))
                var start = GtkTextIter()
                var end = GtkTextIter()
                gtk_text_buffer_get_bounds(buffer, &start, &end)
                guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
                defer { g_free(raw) }
                return String(cString: raw)
            }
            return gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        }
        set {
            if fills {
                gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(promptView)), newValue, -1)
            } else {
                gtk_editable_set_text(op(entry), newValue)
            }
        }
    }

    func driverSubmit() {
        submit()
    }

    /// The harness's way in to the one control that writes words, so a headless run exercises the
    /// same path a press does.
    func driverEnhance() {
        enhancePressed()
    }

    func driverUseRewrite() {
        useRewrite()
    }

    func focusPrompt() {
        gtk_widget_grab_focus(fills ? promptView : entry)
    }

    func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    private func changed() {
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.refreshChips()
            self.onChange?()
        }
    }

    /// A step moved: the machine's line, the bar, the clock, the sketch's caption and the row
    /// on the shelf change in place. Nothing is rebuilt — a frame changes words, never layout.
    private func refreshProgressOnly() {
        guard slot.isBusy else { return }
        refreshStatus()
        if fills {
            refreshInFlightRow()
            if let sketchPicture, studio.previewTexture != 0 {
                tailscode_set_accessible_label(
                    sketchPicture, ImageGenPreviewWords.caption(studio.progress))
            }
            if studio.previewTexture != 0, case .painting(_, let engine, let mode) = slot.phase {
                gtk_label_set_text(op(factsLabel), inFlightFactsLine(engine: engine, mode: mode))
            }
        }
    }

    /// The facts line under the stage while a render runs: the engine, the shape and the steps,
    /// then what the stage is showing in place of the picture — the sketch with its step, or the
    /// previous picture until this one lands.
    private func inFlightFactsLine(engine: ImageGenEngine, mode: ImageGenMode) -> String {
        guard case .painting(let prompt, _, _) = slot.phase else { return "" }
        let steps = Localized.text(
            "%@ steps", "\(slot.recipe(prompt: prompt, seed: slot.seed.last ?? 0).steps)")
        let shape =
            mode == .edit
            ? "\(engine.short) · \(ImageGenMode.edit.label) · \(steps)"
            : "\(engine.short) · \(slot.aspect.short) \(slot.aspect.ratioLabel) · \(slot.aspect.label(slot.size)) · \(steps)"
        let sketching = studio.previewTexture != 0
        let previous = fills && slot.isBusy ? underwayKey : nil
        let note =
            sketching
            ? ImageGenPreviewWords.caption(studio.progress)
            : mode == .edit
                ? ImageGenStudioWords.editingShownNote : ImageGenStudioWords.previousShownNote
        return previous == nil && !sketching ? shape : "\(shape) · \(note)"
    }

    /// The picture a render just landed arrives under its last sketch rather than in place of
    /// it: both sit in a stack that crossfades from the sketch to the picture once, on the frame
    /// after it is mapped, and the sketch is let go when the fade is over. A rebuild in the
    /// meantime — the shelf catching up, a thumbnail decoding — finds the fade already begun for
    /// this picture and shows the picture outright, so nothing fades twice. Reduced motion
    /// shows the picture at once.
    private var arrivedKey: String?
    /// Until when the arrival stack is left alone: a rebuild inside this window — the shelf
    /// catching up, a thumbnail decoding — would cut the fade short, so the stage keeps what it
    /// has while the picture is still arriving.
    private var arrivalUntil: Date?

    private func arrivalKeeps(_ key: String?) -> Bool {
        guard let arrivalUntil, arrivalUntil > Date(), let key, key == arrivedKey,
            !slot.isBusy, !zoomed, let stack = arrivalStackWidget,
            gtk_widget_get_parent(stack) == stagePicture
        else { return false }
        return true
    }

    private func arrivalStack(for key: String, landing: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard fills, arrivedKey != key, studio.previewTexture != 0,
            slot.pictures.first?.path == key, RepeatingMotion.allowed,
            let sketch = Gtk.pictureWidget(bits: studio.previewTexture)
        else { return nil }
        arrivedKey = key
        arrivalUntil = Date().addingTimeInterval(Double(Self.arrivalFade + 400) / 1000)
        let stack = gtk_stack_new()!
        gtk_stack_set_transition_type(op(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(op(stack), Self.arrivalFade)
        gtk_stack_set_hhomogeneous(op(stack), 1)
        gtk_stack_set_vhomogeneous(op(stack), 1)
        gtk_widget_set_vexpand(stack, 1)
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(sketch, 1)
        gtk_widget_set_hexpand(sketch, 1)
        Gtk.addClass(sketch, "draw-sketch")
        gtk_stack_add_child(op(stack), sketch)
        gtk_stack_add_child(op(stack), landing)
        gtk_stack_set_visible_child(op(stack), sketch)
        arrivalStackWidget = stack
        let stackBits = UInt(bitPattern: stack)
        let landingBits = UInt(bitPattern: landing)
        Gtk.connect(UnsafeMutableRawPointer(stack), "map") {
            Gtk.after(60) {
                guard let stack = UnsafeMutablePointer<GtkWidget>(bitPattern: stackBits),
                    let landing = UnsafeMutablePointer<GtkWidget>(bitPattern: landingBits),
                    gtk_widget_get_parent(landing) == stack, gtk_widget_get_mapped(stack) != 0
                else { return }
                gtk_stack_set_visible_child(op(stack), landing)
            }
        }
        Gtk.after(Self.arrivalFade + 400) { [weak self] in
            Gtk.onMain { [weak self] in self?.studio.settleSketch() }
        }
        return stack
    }

    private static let arrivalFade: UInt32 = 700

    /// For the headless driver: whether a landed picture was faded in, and what the stack says.
    var arrivalSummary: String {
        guard let arrivedKey else { return "none" }
        guard let stack = arrivalStackWidget else { return "built(\(arrivedKey.suffix(12)))" }
        let running = gtk_stack_get_transition_running(op(stack)) != 0
        return "stack running=\(running) mapped=\(gtk_widget_get_mapped(stack) != 0)"
    }

    private var arrivalStackWidget: UnsafeMutablePointer<GtkWidget>?

    /// A new sketch swaps the paintable of the picture already on the stage; only the first
    /// frame, which has no picture to swap into, rebuilds the stage.
    private func adoptSketch() {
        guard slot.isBusy, studio.previewTexture != 0 else { return }
        guard let sketchPicture, gtk_widget_get_parent(sketchPicture) == stagePicture,
            let raw = UnsafeMutableRawPointer(bitPattern: studio.previewTexture)
        else {
            refreshStage()
            return
        }
        gtk_picture_set_paintable(op(sketchPicture), OpaquePointer(raw))
        tailscode_set_accessible_label(sketchPicture, ImageGenPreviewWords.caption(studio.progress))
    }

    /// Lets go of the view. A studio of this pane's own dies with it; the shared one keeps
    /// painting, because closing a window is not cancelling a render.
    func shutdown() {
        if let studioObserver { NotificationCenter.default.removeObserver(studioObserver) }
        studioObserver = nil
        if let sketchObserver { NotificationCenter.default.removeObserver(sketchObserver) }
        sketchObserver = nil
        if let rewriteObserver { NotificationCenter.default.removeObserver(rewriteObserver) }
        rewriteObserver = nil
        if let progressObserver { NotificationCenter.default.removeObserver(progressObserver) }
        progressObserver = nil
        studio.onNotice = nil
        if studio !== ImageStudio.shared { studio.release() }
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "draw-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        if fills {
            buildStudio()
            return
        }

        Gtk.addClass(askBox, "draw-ask")
        Gtk.margins(askBox, top: 12, bottom: 12, leading: 18, trailing: 18)
        gtk_widget_set_valign(askBox, fills ? GTK_ALIGN_FILL : GTK_ALIGN_END)
        gtk_widget_set_vexpand(askBox, fills ? 1 : 0)
        gtk_widget_set_hexpand(askBox, 1)

        gtk_entry_set_placeholder_text(ptr(entry), ImageGenNotice.emptyBody)
        gtk_widget_set_hexpand(entry, 1)
        Gtk.addClass(entry, "draw-entry")
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            self?.submit()
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            self?.refreshHint()
        }
        Gtk.addClass(chipRow, "draw-chips")
        gtk_widget_set_halign(chipRow, GTK_ALIGN_START)
        gtk_widget_set_hexpand(chipRow, 1)

        gtk_label_set_xalign(op(statusLabel), 0)
        gtk_label_set_xalign(op(progressLabel), 0)
        gtk_label_set_xalign(op(noticeLabel), 0)
        gtk_label_set_max_width_chars(op(noticeLabel), 46)
        gtk_widget_set_visible(progressBar, 0)
        Gtk.addClass(progressBar, "draw-progress-bar")

        gtk_widget_set_vexpand(stagePicture, 1)
        gtk_widget_set_hexpand(stagePicture, 1)
        Gtk.addClass(stagePicture, "draw-stage-room")
        gtk_label_set_xalign(op(factsLabel), 0)
        gtk_label_set_xalign(op(captionLabel), 0)
        gtk_label_set_max_width_chars(op(captionLabel), 96)
        gtk_label_set_ellipsize(op(captionLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(keptHintLabel), 0)
        Gtk.addClass(actionRow, "draw-actions")

        for chip in [engineChip, aspectChip, sizeChip, enhanceChip, helperMenu, referenceChip, moreChip] {
            gtk_widget_set_halign(chip, GTK_ALIGN_START)
            gtk_box_append(ptr(chipRow), chip)
        }
        Gtk.addClass(moreRow, "draw-chips-more")
        gtk_widget_set_halign(moreRow, GTK_ALIGN_START)
        for chip in [detailChip, cutoutChip, seedChip] {
            gtk_widget_set_halign(chip, GTK_ALIGN_START)
            gtk_box_append(ptr(moreRow), chip)
        }
        gtk_entry_set_placeholder_text(ptr(avoidEntry), ImageGenWords.avoidPlaceholder)
        Gtk.addClass(avoidEntry, "draw-avoid")
        gtk_widget_set_hexpand(avoidEntry, 1)
        gtk_widget_set_halign(referenceStrip, GTK_ALIGN_START)

        gtk_widget_set_hexpand(entry, 1)
        gtk_widget_set_valign(renderButton, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(promptRow), entry)
        gtk_box_append(ptr(promptRow), renderButton)

        buildShelf()

        gtk_box_append(ptr(askBox), stagePicture)
        gtk_box_append(ptr(askBox), zoomHint)
        gtk_box_append(ptr(askBox), captionLabel)
        gtk_box_append(ptr(askBox), factsLabel)
        gtk_box_append(ptr(askBox), keptHintLabel)
        gtk_box_append(ptr(askBox), actionRow)
        gtk_box_append(ptr(askBox), shelfBox)
        gtk_box_append(ptr(askBox), statusLabel)
        gtk_box_append(ptr(askBox), progressLabel)
        gtk_box_append(ptr(askBox), progressBar)
        gtk_box_append(ptr(askBox), hintBox)
        gtk_box_append(ptr(askBox), rewriteBox)
        gtk_box_append(ptr(askBox), referenceStrip)
        gtk_box_append(ptr(askBox), chipRow)
        gtk_box_append(ptr(askBox), moreRow)
        gtk_box_append(ptr(askBox), avoidEntry)
        gtk_box_append(ptr(askBox), promptRow)
        gtk_box_append(ptr(askBox), noticeLabel)
        gtk_box_append(ptr(root), askBox)
    }

    /// The shelf: every picture the machine keeps, newest first, under a heading that names the
    /// machine and says how many there are — and how stale that count is, when it is a remembered
    /// one rather than the machine's own answer just now.
    private func buildShelf() {
        Gtk.addClass(shelfBox, "draw-shelf")
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(shelfHeadingLabel, "draw-shelf-heading")
        gtk_label_set_ellipsize(op(shelfCountLabel), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(header), shelfHeadingLabel)
        gtk_box_append(ptr(header), shelfCountLabel)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        gtk_box_append(ptr(header), shelfRefreshButton)
        gtk_box_append(ptr(shelfBox), header)

        gtk_label_set_xalign(op(shelfStatusLabel), 0)
        gtk_label_set_max_width_chars(op(shelfStatusLabel), 60)
        gtk_box_append(ptr(shelfBox), shelfStatusLabel)

        gtk_flow_box_set_selection_mode(op(shelfFlowBox), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_homogeneous(op(shelfFlowBox), 1)
        gtk_flow_box_set_row_spacing(op(shelfFlowBox), 8)
        gtk_flow_box_set_column_spacing(op(shelfFlowBox), 8)
        gtk_flow_box_set_max_children_per_line(op(shelfFlowBox), 999)
        gtk_flow_box_set_activate_on_single_click(op(shelfFlowBox), 1)
        gtk_widget_set_focusable(shelfFlowBox, 0)
        gtk_widget_set_halign(shelfFlowBox, GTK_ALIGN_START)
        Gtk.addClass(shelfFlowBox, "draw-shelf-grid")

        gtk_scrolled_window_set_policy(op(shelfScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(shelfScroller), 280)
        gtk_scrolled_window_set_propagate_natural_height(op(shelfScroller), 1)
        gtk_scrolled_window_set_child(op(shelfScroller), shelfFlowBox)
        gtk_widget_set_hexpand(shelfScroller, 1)
        gtk_box_append(ptr(shelfBox), shelfScroller)
    }

    private func render() {
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.refreshChips()
            self.refreshStatus()
            self.refreshStage()
            self.refreshNotice()
        }
    }

    /// Every decision the next render is made of, worn where the hands already are. A chip that
    /// would change nothing is disabled rather than removed, so the row never moves under the
    /// pointer: an edit takes its frame from the picture it starts from, and the fast engine
    /// reads neither the sampler length nor the alpha channel.
    private func refreshChips() {
        gtk_menu_button_set_label(op(engineChip), slot.engine.label)
        gtk_widget_set_tooltip_text(engineChip, slot.engine.detail)
        gtk_menu_button_set_label(op(aspectChip), "\(slot.aspect.glyph)  \(slot.aspect.ratioLabel)")
        gtk_widget_set_tooltip_text(aspectChip, slot.aspect.short)
        gtk_menu_button_set_label(op(sizeChip), slot.size.short)
        gtk_widget_set_tooltip_text(sizeChip, slot.aspect.label(slot.size))
        gtk_widget_set_sensitive(aspectChip, slot.applies(.aspect) ? 1 : 0)
        gtk_widget_set_sensitive(sizeChip, slot.applies(.size) ? 1 : 0)

        gtk_menu_button_set_label(op(detailChip), slot.detail.short)
        gtk_widget_set_tooltip_text(detailChip, slot.detail.detail)
        gtk_widget_set_sensitive(detailChip, slot.applies(.detail) ? 1 : 0)
        gtk_button_set_label(ptr(cutoutChip), ImageGenWords.cutoutTitle)
        gtk_widget_set_tooltip_text(cutoutChip, ImageGenWords.cutoutHint)
        gtk_widget_set_sensitive(cutoutChip, slot.cutoutApplies ? 1 : 0)
        mark(cutoutChip, on: slot.cutout && slot.cutoutApplies)
        gtk_button_set_label(ptr(seedChip), slot.seed.chip)
        gtk_widget_set_tooltip_text(
            seedChip, slot.seed.isHeld ? ImageGenWords.seedHeldHint : ImageGenWords.seedRollsHint)
        mark(seedChip, on: slot.seed.isHeld)
        gtk_widget_set_sensitive(avoidEntry, slot.negativeApplies ? 1 : 0)
        gtk_widget_set_visible(moreRow, showsMore ? 1 : 0)
        gtk_widget_set_visible(avoidEntry, fills || showsMore ? 1 : 0)
        gtk_button_set_label(
            ptr(moreChip), showsMore ? ImageGenWords.lessTitle : ImageGenWords.moreTitle)
        mark(moreChip, on: showsMore)
        refreshEnhance()
        refreshStudioControls()

        let references = slot.references
        if references.isEmpty {
            gtk_button_set_label(ptr(referenceChip), ImageGenWords.attachTitle)
            gtk_widget_set_tooltip_text(referenceChip, ImageGenWords.attachHint)
            gtk_widget_remove_css_class(referenceChip, "draw-chip-on")
        } else {
            gtk_button_set_label(
                ptr(referenceChip),
                references.count == 1
                    ? ImageGenWords.attachMoreTitle
                    : ImageGenWords.attachedCount(references.count))
            gtk_widget_set_tooltip_text(referenceChip, ImageGenWords.attachMoreHint)
            Gtk.addClass(referenceChip, "draw-chip-on")
        }
        gtk_widget_set_sensitive(
            referenceChip, references.count < ImageGenSlot.referenceLimit ? 1 : 0)
        refreshReferences()

        gtk_button_set_label(
            ptr(renderButton),
            slot.isBusy ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode))
        if slot.isBusy {
            Gtk.addClass(renderButton, "stopping")
        } else {
            gtk_widget_remove_css_class(renderButton, "stopping")
        }
        refreshHint()
    }

    /// The one control that writes words rather than choosing a value, so it says which model
    /// will write them and never runs on its own.
    private func refreshEnhance() {
        let helper = studio.helper
        let busy = studio.enhancing
        gtk_button_set_label(
            ptr(enhanceChip),
            busy ? ImageGenWords.enhancingTitle
                : (beforeEnhance == nil ? ImageGenWords.enhanceTitle : ImageGenWords.undoTitle))
        gtk_widget_set_tooltip_text(
            enhanceChip,
            busy ? ImageGenRewriteWords.stopTitle
                : helper.map(ImageGenWords.enhanceHint) ?? ImageGenWords.enhanceLookingHint)
        gtk_widget_set_sensitive(enhanceChip, busy || !slot.isBusy ? 1 : 0)
        mark(enhanceChip, on: busy || beforeEnhance != nil)
        let name: String
        if let helper {
            let shown = fills ? helper.name : helper.chip
            name = helper.enabled ? shown : "\(shown) · \(ImageGenWords.offMark)"
        } else if studio.surveying {
            name = ImageGenRewriteWords.lookingTitle
        } else {
            name = ImageGenRewriteWords.chooseTitle
        }
        gtk_menu_button_set_label(
            op(helperMenu),
            fills
                ? ImageGenRewriteWords.withLine(name)
                : "\(ImageGenRewriteWords.chooseTitle) · \(name)")
        gtk_widget_set_tooltip_text(
            helperMenu,
            helper.map { "\(ImageGenRewriteWords.chooseHint) · \($0.label ?? $0.model) · \($0.displayHost)" }
                ?? ImageGenRewriteWords.chooseHint)
        mark(helperMenu, on: helper?.enabled == true && !fills)
        reopenHelperMenuIfSurveyLanded()
        refreshRewrite()
    }

    /// A menu opened before the survey came back was a "Looking…" row; when the answer lands
    /// while it is still open, it is rebuilt in place rather than left to be closed and opened.
    private func reopenHelperMenuIfSurveyLanded() {
        guard let landed = studio.surveyedAt, landed != surveyShown else { return }
        surveyShown = landed
        guard let popover = gtk_menu_button_get_popover(op(helperMenu)),
            gtk_widget_get_mapped(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkWidget.self)) != 0
        else { return }
        gtk_menu_button_popdown(op(helperMenu))
        gtk_menu_button_popup(op(helperMenu))
    }

    /// The card follows the draft: hidden with none, writing with a Stop, landed with the three
    /// verbs and a line for what to change, failed with the reason and a way to try again. The
    /// paragraph is set only when it grew, and the view keeps its end in sight while it does.
    private func refreshRewrite() {
        guard let draft = studio.draft else {
            gtk_widget_set_visible(rewriteBox, 0)
            rewriteShown = ""
            return
        }
        gtk_widget_set_visible(rewriteBox, 1)
        gtk_label_set_text(op(rewriteHead), draft.headline)
        if case .failed = draft.phase {
            Gtk.addClass(rewriteHead, "danger")
        } else {
            gtk_widget_remove_css_class(rewriteHead, "danger")
        }
        let landedNow = !draft.isWriting && rewriteWasWriting
        rewriteWasWriting = draft.isWriting
        if draft.written != rewriteShown || landedNow {
            rewriteShown = draft.written
            let buffer = gtk_text_view_get_buffer(ptr(rewriteBody))
            gtk_text_buffer_set_text(buffer, draft.written, -1)
            var edge = GtkTextIter()
            if draft.isWriting {
                gtk_text_buffer_get_end_iter(buffer, &edge)
            } else {
                gtk_text_buffer_get_start_iter(buffer, &edge)
            }
            let mark = gtk_text_buffer_create_mark(buffer, nil, &edge, 0)
            gtk_text_view_scroll_mark_onscreen(ptr(rewriteBody), mark)
            gtk_text_buffer_delete_mark(buffer, mark)
        }
        let scroller = gtk_widget_get_parent(rewriteBody)
        gtk_widget_set_visible(scroller, draft.written.isEmpty ? 0 : 1)
        gtk_widget_set_visible(rewriteStop, draft.isWriting ? 1 : 0)
        gtk_widget_set_visible(rewriteUse, draft.isUsable ? 1 : 0)
        gtk_widget_set_visible(rewriteAgain, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(rewriteKeep, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(rewriteInstruction, draft.isUsable ? 1 : 0)
        gtk_widget_set_sensitive(rewriteUse, slot.isBusy ? 0 : 1)
    }

    /// Takes the paragraph: into the box, where it can still be edited, with the typed sentence
    /// one press away. The shape the helper chose is followed only where nobody chose one by
    /// hand, and never for an edit, which takes its shape from the picture.
    private func useRewrite() {
        guard let draft = studio.draft, draft.isUsable else { return }
        beforeEnhance = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.original : promptText
        if let aspect = draft.aspect, !studio.aspectChosen, slot.applies(.aspect) {
            studio.follow(aspect: aspect)
        }
        fill(draft.written)
        studio.dismissRewrite()
        onNotice?(ImageGenWords.enhancedNotice(draft.helper))
        refreshEnhance()
    }

    /// One line of what to change sends the same paragraph back for a revision.
    private func revisePressed() {
        guard let draft = studio.draft, draft.isUsable,
            let raw = gtk_editable_get_text(op(rewriteInstruction))
        else { return }
        let instruction = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        gtk_editable_set_text(op(rewriteInstruction), "")
        studio.rewrite(draft.original, instruction: instruction)
    }

    /// Press once to have the brief written out, press again while it writes to stop it, and
    /// press once more after taking it to get your own sentence back.
    private func enhancePressed() {
        if let original = beforeEnhance {
            fill(original)
            beforeEnhance = nil
            refreshEnhance()
            return
        }
        if studio.enhancing {
            studio.stopRewrite()
            return
        }
        let brief = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            focusPrompt()
            return
        }
        studio.rewrite(brief)
    }

    private func mark(_ chip: UnsafeMutablePointer<GtkWidget>, on: Bool) {
        if on {
            Gtk.addClass(chip, "draw-chip-on")
        } else {
            gtk_widget_remove_css_class(chip, "draw-chip-on")
        }
    }

    /// Each picture the render works from, in the order the words address them, with the number
    /// the prompt would call it and a way to let go of exactly that one.
    private func refreshReferences() {
        Gtk.removeChildren(of: referenceStrip)
        let references = slot.references
        gtk_widget_set_visible(referenceStrip, references.isEmpty ? 0 : 1)
        guard !references.isEmpty else { return }
        for (index, reference) in references.enumerated() {
            let tile = Gtk.button(
                "\(ImageGenWords.referenceSlot(index + 1))  ✕", css: ["draw-ref-drop"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.studio.release(reference.path)
                    self?.resetPlaceholder()
                }
            }
            gtk_widget_set_tooltip_text(tile, ImageGenWords.releaseHint(reference.name))
            gtk_box_append(ptr(referenceStrip), tile)
        }
        if references.count > 1 {
            let note = Gtk.label(ImageGenWords.addressHint, css: "draw-hint-body", selectable: false)
            gtk_box_append(ptr(referenceStrip), note)
        }
    }

    /// The one nudge this surface gives: a brief thin enough that the model will invent most of
    /// the frame gets told so, with the two ways out beside it. It is never a block — it appears
    /// while the words are thin and goes when they are not.
    private func refreshHint() {
        Gtk.removeChildren(of: hintBox)
        let typed = promptText
        refreshCount(typed)
        guard !slot.isBusy, slot.mode != .edit, ImageGenBrief.isThin(typed) else {
            gtk_widget_set_visible(hintBox, 0)
            return
        }
        gtk_widget_set_visible(hintBox, 1)
        Gtk.addClass(hintBox, "draw-hint")
        gtk_box_append(
            ptr(hintBox), Gtk.label(ImageGenBrief.thinTitle, css: "draw-hint-title", selectable: false))
        let body = Gtk.label(ImageGenBrief.thinBody, css: "draw-hint-body", wrap: true, selectable: false)
        gtk_label_set_xalign(op(body), 0)
        gtk_label_set_max_width_chars(op(body), 64)
        gtk_box_append(ptr(hintBox), body)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        if let helper = studio.helper, helper.enabled {
            let write = Gtk.button(ImageGenWords.enhanceTitle, css: ["draw-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.enhancePressed() }
            }
            gtk_widget_set_tooltip_text(write, ImageGenWords.enhanceHint(helper))
            gtk_box_append(ptr(row), write)
        }
        let frame = Gtk.button(ImageGenWords.scaffoldTitle, css: ["draw-action"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.fill(ImageGenBrief.scaffold) }
        }
        gtk_widget_set_tooltip_text(frame, ImageGenWords.scaffoldHint)
        gtk_box_append(ptr(row), frame)
        gtk_box_append(ptr(row), craftButton())
        gtk_box_append(ptr(hintBox), row)
    }

    /// The craft, as six rules and four worked briefs. Opening one fills the composer rather
    /// than sending it: what the person types is theirs, always.
    private func craftButton() -> UnsafeMutablePointer<GtkWidget> {
        let pane = Weak(self)
        return Gtk.menuButton(ImageGenBrief.craftTitle, css: ["draw-action"]) {
            var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
            for rule in ImageGenBrief.rules {
                rows.append((title: rule.title, detail: rule.detail, action: {}))
            }
            for example in ImageGenBrief.examples {
                let prompt = example.prompt
                let aspect = example.aspect
                rows.append(
                    (
                        title: "\(ImageGenWords.examplePrefix) \(example.title)",
                        detail: example.detail,
                        action: {
                            Gtk.onMain {
                                guard let pane = pane.value else { return }
                                pane.studio.choose(aspect: aspect)
                                pane.fill(prompt)
                            }
                        }
                    ))
            }
            return rows
        }
    }

    /// Words land in the composer with the caret at their end and nothing is sent. A surface
    /// that sent something the person did not type would be a surface nobody trusts twice.
    private func fill(_ text: String) {
        promptText = text
        if fills {
            let buffer = gtk_text_view_get_buffer(ptr(promptView))
            var end = GtkTextIter()
            gtk_text_buffer_get_end_iter(buffer, &end)
            gtk_text_buffer_place_cursor(buffer, &end)
        } else {
            gtk_editable_set_position(op(entry), -1)
        }
        focusPrompt()
        refreshHint()
    }

    /// What the words weigh, under them, so a thin brief is a number before it is a warning.
    private func refreshCount(_ typed: String) {
        guard fills else { return }
        let words = ImageGenBrief.words(in: typed.trimmingCharacters(in: .whitespacesAndNewlines))
        gtk_label_set_text(
            op(countLabel), ImageGenStudioWords.countLine(words: words, engine: slot.engine))
    }

    private func refreshNotice() {
        let text = fills ? ImageGenNotice.costLine : ImageGenNotice.splitCostLine
        gtk_label_set_text(op(noticeLabel), text)
        let unspent = slot.pictures.isEmpty && !slot.isBusy && studio.keptStage == nil
        gtk_widget_set_visible(noticeLabel, unspent && !fills ? 1 : 0)
    }

    private func refreshStatus() {
        switch slot.phase {
        case .asking:
            gtk_label_set_text(op(statusLabel), "")
            gtk_widget_set_visible(statusLabel, 0)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
            refreshClock()
        case .composing:
            gtk_label_set_text(op(statusLabel), "")
            gtk_widget_set_visible(statusLabel, 0)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
            refreshClock()
        case .painting(let prompt, let engine, let mode):
            let verb =
                mode == .edit ? Localized.text("Editing with %@", engine.label)
                : Localized.text("Painting with %@", engine.label)
            gtk_label_set_text(
                op(statusLabel),
                fills ? (studio.progress?.line ?? verb) : "\(verb) — \(prompt.ellipsized(to: 72))")
            gtk_widget_set_visible(statusLabel, 1)
            gtk_label_set_text(op(progressLabel), elapsedLine())
            gtk_widget_set_visible(progressLabel, fills ? 0 : 1)
            refreshClock()
            refreshProgressBar()
            startTicking()
        case .failed(_, let reason):
            gtk_label_set_text(op(statusLabel), reason)
            gtk_widget_set_visible(statusLabel, 1)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
            refreshClock()
        }
    }

    /// A bar is drawn only once the machine's own sampler step gives it a count to draw from —
    /// never at zero, which is a lie about a wait that has not started yet.
    private func refreshProgressBar() {
        guard let fraction = studio.progress?.bar else {
            gtk_widget_set_visible(progressBar, 0)
            return
        }
        gtk_progress_bar_set_fraction(op(progressBar), fraction)
        gtk_widget_set_visible(progressBar, 1)
    }

    /// The room: one picture at the size the surface can give it, the words that made it, what it
    /// cost, and the verbs that get it out of this app. An empty studio argues for itself rather
    /// than showing a grey rectangle, and a render in flight paints in place of the picture so the
    /// eye never has to go looking for where the answer will appear.
    private func refreshStage() {
        let key = stageTextureKey
        let keepArrival = arrivalKeeps(key)
        if !keepArrival { Gtk.removeChildren(of: stagePicture) }
        let hasBits = key.flatMap { textures[$0] }.map { $0 != 0 } ?? false
        if slot.isBusy || !hasBits { zoomed = false }
        if fills {
            for widget in [briefColumn, shelfColumn, underRow] {
                gtk_widget_set_visible(widget, zoomed ? 0 : 1)
            }
            if let scroller = gtk_widget_get_parent(briefColumn),
                let column = gtk_widget_get_parent(scroller)
            {
                gtk_widget_set_visible(column, zoomed ? 0 : 1)
            }
        } else {
            for widget in [
                captionLabel, factsLabel, keptHintLabel, actionRow, shelfBox, chipRow, promptRow,
            ] {
                gtk_widget_set_visible(widget, zoomed ? 0 : 1)
            }
        }
        if zoomed {
            for widget in [hintBox, referenceStrip, moreRow, avoidEntry] {
                gtk_widget_set_visible(widget, 0)
            }
        } else {
            refreshHint()
            refreshReferences()
        }
        gtk_label_set_text(op(zoomHint), ImageGenWords.zoomHint)
        gtk_widget_set_visible(zoomHint, zoomed ? 1 : 0)

        let previousKey = fills && slot.isBusy ? underwayKey : nil
        if !keepArrival { sketchPicture = nil }
        if keepArrival {
        } else if slot.isBusy, studio.previewTexture != 0,
            let widget = Gtk.pictureWidget(bits: studio.previewTexture)
        {
            gtk_widget_set_vexpand(widget, 1)
            gtk_widget_set_hexpand(widget, 1)
            Gtk.addClass(widget, "draw-sketch")
            gtk_widget_set_tooltip_text(widget, ImageGenPreviewWords.note)
            tailscode_set_accessible_label(widget, ImageGenPreviewWords.caption(studio.progress))
            sketchPicture = widget
            gtk_box_append(ptr(stagePicture), widget)
        } else if slot.isBusy, let previousKey,
            let bits = textures[previousKey] ?? studio.library.textures[previousKey], bits != 0,
            let widget = Gtk.pictureWidget(bits: bits)
        {
            gtk_widget_set_vexpand(widget, 1)
            gtk_widget_set_hexpand(widget, 1)
            gtk_widget_set_opacity(widget, 0.45)
            gtk_box_append(ptr(stagePicture), widget)
        } else if slot.isBusy {
            stagePicture.appendWorking(room: fills)
        } else if let key, let bits = textures[key], bits != 0,
            let widget = Gtk.pictureWidget(bits: bits)
        {
            gtk_widget_set_vexpand(widget, 1)
            gtk_widget_set_hexpand(widget, 1)
            let button = gtk_button_new()!
            Gtk.addClass(button, "draw-tile")
            gtk_widget_set_vexpand(button, 1)
            gtk_widget_set_hexpand(button, 1)
            gtk_widget_set_halign(button, GTK_ALIGN_FILL)
            gtk_button_set_child(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), widget)
            gtk_widget_set_tooltip_text(button, ImageGenAction.open.hint)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.openStage() }
            }
            if zoomed { Gtk.addClass(button, "draw-tile-zoomed") }
            if let arrival = arrivalStack(for: key, landing: button) {
                gtk_box_append(ptr(stagePicture), arrival)
            } else {
                gtk_box_append(ptr(stagePicture), button)
            }
        } else if studio.keptStage != nil {
            stagePicture.appendWorking(room: fills)
        } else {
            appendEmptyStage()
        }

        guard !zoomed else { return }
        if fills, slot.isBusy, case .painting(let prompt, let engine, let mode) = slot.phase {
            gtk_widget_set_visible(underRow, 1)
            gtk_label_set_text(op(captionLabel), prompt)
            gtk_widget_set_visible(captionLabel, 1)
            gtk_label_set_text(op(factsLabel), inFlightFactsLine(engine: engine, mode: mode))
            gtk_widget_set_visible(factsLabel, 1)
            gtk_widget_set_visible(keptHintLabel, 0)
            refreshActions()
            refreshShelf()
            return
        }
        let showFacts = stageAvailable && !slot.isBusy
        if fills { gtk_widget_set_visible(underRow, showFacts ? 1 : 0) }
        gtk_label_set_text(op(factsLabel), showFacts ? stageFactsLine : "")
        gtk_widget_set_visible(factsLabel, showFacts ? 1 : 0)
        gtk_label_set_text(op(captionLabel), showFacts ? stageCaption : "")
        gtk_widget_set_visible(captionLabel, showFacts ? 1 : 0)
        gtk_label_set_text(op(keptHintLabel), stageIsKept ? ImageGenWords.keptNote : "")
        gtk_widget_set_visible(keptHintLabel, showFacts && stageIsKept ? 1 : 0)
        refreshActions()
        refreshShelf()
    }

    /// How long the machine has been at it, and what it last said it was doing — the sampler's
    /// own step when it has one, else which editor is at work.
    private func elapsedLine() -> String {
        slot.waitingLine(since: studio.startedAt, progress: studio.progress)
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a surface that keeps a timer alive over a settled state is a surface
    /// spending frames on nothing.
    private func startTicking() {
        guard !ticking else { return }
        ticking = true
        tick()
    }

    private func tick() {
        Gtk.after(1000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard self.slot.isBusy else {
                    self.ticking = false
                    return
                }
                gtk_label_set_text(op(self.progressLabel), self.elapsedLine())
                if self.fills, let line = self.studio.progress?.line {
                    gtk_label_set_text(op(self.statusLabel), line)
                }
                self.refreshClock()
                self.refreshProgressBar()
                self.tick()
            }
        }
    }

    /// The studio's clock: how long, and how many renders are queued ahead when the machine has
    /// said so. Lives at the right end of the progress row, opposite the machine's own words.
    private func refreshClock() {
        guard fills else { return }
        var ahead: Int?
        if let progress = studio.progress, case .queued(let count) = progress.stage { ahead = count }
        gtk_label_set_text(
            op(clockLabel), ImageGenStudioWords.clockLine(since: studio.startedAt, ahead: ahead))
        gtk_widget_set_visible(clockLabel, slot.isBusy ? 1 : 0)
    }

    /// Whether Escape has something of this surface's own to close before it closes the surface.
    var isZoomed: Bool { zoomed }

    func unzoom() {
        guard zoomed else { return }
        zoomed = false
        render()
    }

    /// What stays on the stage, dimmed, while a render is out: the picture being edited when
    /// there is one — the result replaces it — else the last picture this session made.
    private var underwayKey: String? {
        if slot.mode == .edit, let reference = slot.references.first {
            let key = reference.kept?.id ?? reference.path
            if let bits = textures[key] ?? studio.library.textures[key], bits != 0 { return key }
        }
        return slot.pictures.first?.path
    }

    /// The key into ``ImageStudio/textures`` for whatever is on the stage right now: a library
    /// item's own id for a kept picture, a session render's local path otherwise.
    private var stageTextureKey: String? {
        if let kept = studio.keptStage { return kept.item.id }
        return slot.onStage?.path
    }

    /// The local file a save, a copy or a reference reads from — nil while a kept picture's
    /// original is still on its way from the machine.
    private var stagePath: String? {
        if let kept = studio.keptStage { return kept.path }
        return slot.onStage?.path
    }

    private var stageAvailable: Bool { studio.keptStage != nil || slot.onStage != nil }
    private var stageIsKept: Bool { studio.keptStage != nil }

    private var stageCaption: String {
        if let kept = studio.keptStage { return ImageGenFacts.caption(for: kept.facts) }
        return slot.onStage?.prompt ?? ""
    }

    private var stageFactsLine: String {
        if let kept = studio.keptStage { return ImageGenFacts.line(for: kept.facts) }
        guard let picture = slot.onStage else { return "" }
        return ImageGenFacts.line(for: picture)
    }

    private var stageActions: [ImageGenAction] {
        if let kept = studio.keptStage {
            return ImageGenAction.offered(
                kept: true, hasWords: kept.facts?.recipe?.prompt != nil, sharing: false,
                tapOpens: false)
        }
        guard slot.onStage != nil else { return [] }
        return ImageGenAction.forPicture
    }

    /// Which shelf tile is the one on the stage — a session render is the same picture as the
    /// machine's own copy of it the moment the listing catches up, so the tile is marked rather
    /// than drawn a second time.
    private var onStageLibraryID: String? {
        if let kept = studio.keptStage { return kept.item.id }
        return slot.onStage?.remoteName
    }

    private func stageFileName() -> String {
        if let kept = studio.keptStage { return kept.item.filename }
        if let picture = slot.onStage { return ImageGenFacts.fileName(for: picture) }
        return "image.png"
    }

    /// The verbs a finished picture earns. They exist at all only when there is something to act
    /// on, and the one that destroys sits apart from the hand reaching for the others.
    private func refreshActions() {
        Gtk.removeChildren(of: actionRow)
        if fills, slot.isBusy {
            reserveActionRow()
            return
        }
        guard !slot.isBusy, stagePath != nil else {
            gtk_widget_set_visible(actionRow, 0)
            return
        }
        gtk_widget_set_visible(actionRow, 1)
        gtk_widget_remove_css_class(actionRow, "draw-actions-reserved")
        gtk_widget_set_can_target(actionRow, 1)
        for action in stageActions {
            if action.isDestructive {
                let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
                gtk_widget_set_hexpand(spacer, 1)
                gtk_box_append(ptr(actionRow), spacer)
            }
            let button = Gtk.button(
                "\(action.glyph)  \(action.title)",
                css: action.isDestructive ? ["flat", "draw-action", "danger"]
                    : ["flat", "draw-action"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.perform(action) }
            }
            gtk_widget_set_tooltip_text(button, action.hint)
            gtk_box_append(ptr(actionRow), button)
        }
    }

    /// While a render runs the verbs it will land with already take their room, invisible and
    /// untouchable, so the stage does not shrink by a row the moment the picture arrives — a
    /// picture that jumps up as it lands is a picture nobody watched arrive.
    private func reserveActionRow() {
        gtk_widget_set_visible(actionRow, 1)
        Gtk.addClass(actionRow, "draw-actions-reserved")
        gtk_widget_set_can_target(actionRow, 0)
        for action in ImageGenAction.forPicture {
            if action.isDestructive {
                let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
                gtk_widget_set_hexpand(spacer, 1)
                gtk_box_append(ptr(actionRow), spacer)
            }
            let button = Gtk.button(
                "\(action.glyph)  \(action.title)", css: ["flat", "draw-action"], onClick: {})
            gtk_widget_set_sensitive(button, 0)
            gtk_box_append(ptr(actionRow), button)
        }
    }

    /// Every picture the machine keeps, newest first — the words never say the shelf is empty or
    /// unsupported by leaving it blank.
    private func refreshShelf() {
        if fills {
            refreshShelfRows()
            return
        }
        let library = studio.library
        gtk_label_set_text(
            op(shelfHeadingLabel), ImageGenLibraryWords.heading(machine: studio.endpoint.shortName))
        gtk_flow_box_remove_all(op(shelfFlowBox))

        if let failure = library.failure, library.items.isEmpty {
            gtk_label_set_text(op(shelfCountLabel), "")
            gtk_label_set_text(op(shelfStatusLabel), failure.reason(machine: studio.endpoint.shortName))
            gtk_widget_set_visible(shelfStatusLabel, 1)
            gtk_widget_set_visible(shelfScroller, 0)
            return
        }
        if library.items.isEmpty {
            gtk_label_set_text(op(shelfCountLabel), "")
            let text =
                library.loading
                ? ImageGenLibraryWords.loading
                : "\(ImageGenLibraryWords.emptyTitle)\n\(ImageGenLibraryWords.emptyBody)"
            gtk_label_set_text(op(shelfStatusLabel), text)
            gtk_widget_set_visible(shelfStatusLabel, 1)
            gtk_widget_set_visible(shelfScroller, 0)
            return
        }

        gtk_label_set_text(
            op(shelfCountLabel),
            ImageGenLibraryWords.line(count: library.items.count, staleSince: library.staleSince))
        gtk_widget_set_visible(shelfStatusLabel, 0)
        gtk_widget_set_visible(shelfScroller, 1)
        let onStageID = onStageLibraryID
        for item in library.items {
            library.describe(item)
            let tile = buildShelfTile(item, current: item.id == onStageID)
            gtk_flow_box_insert(op(shelfFlowBox), tile, -1)
        }
    }

    /// One square tile: the machine's own thumbnail once it has decoded, the caption as a
    /// tooltip once the facts have come back, and the accent frame on whichever one is on stage.
    private func buildShelfTile(_ item: ImageGenLibraryItem, current: Bool) -> UnsafeMutablePointer<
        GtkWidget
    > {
        let button = gtk_button_new()!
        Gtk.addClass(button, "draw-thumb")
        if current { Gtk.addClass(button, "draw-thumb-on") }
        gtk_widget_set_focusable(button, 0)
        let child: UnsafeMutablePointer<GtkWidget>
        if let bits = studio.library.textures[item.id], bits != 0,
            let picture = Gtk.pictureWidget(bits: bits)
        {
            child = picture
        } else {
            let placeholder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(placeholder, "draw-tile-empty")
            child = placeholder
        }
        gtk_widget_set_size_request(child, 96, 96)
        gtk_button_set_child(
            UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), child)
        if let facts = studio.library.facts[item.id] {
            gtk_widget_set_tooltip_text(button, ImageGenFacts.caption(for: facts))
        }
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.studio.showKept(item) }
        }
        return button
    }

    /// An empty studio makes its case and then hands over something to press: four briefs that
    /// are known to come back right, which fill the composer rather than sending anything.
    private func appendEmptyStage() {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(column, 1)
        let title = Gtk.label(ImageGenWords.emptyTitle, css: "draw-empty-title", selectable: false)
        let body = Gtk.label(
            fills ? ImageGenStudioWords.emptyBody : ImageGenWords.emptyBody, css: "dim", wrap: true,
            selectable: false)
        gtk_label_set_max_width_chars(op(body), 52)
        gtk_label_set_justify(op(body), GTK_JUSTIFY_CENTER)
        gtk_box_append(ptr(column), title)
        gtk_box_append(ptr(column), body)

        let grid = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(grid), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(op(grid), fills ? 2 : 1)
        gtk_flow_box_set_row_spacing(op(grid), 6)
        gtk_flow_box_set_column_spacing(op(grid), 6)
        gtk_widget_set_halign(grid, GTK_ALIGN_CENTER)
        for example in ImageGenBrief.examples {
            let prompt = example.prompt
            let aspect = example.aspect
            let card = gtk_button_new()!
            Gtk.addClass(card, "draw-example")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let name = Gtk.label(example.title, css: "draw-example-title", selectable: false)
            gtk_label_set_xalign(op(name), 0)
            let detail = Gtk.label(example.detail, css: "draw-example-detail", selectable: false)
            gtk_label_set_xalign(op(detail), 0)
            gtk_box_append(ptr(lines), name)
            gtk_box_append(ptr(lines), detail)
            gtk_button_set_child(ptr(card), lines)
            gtk_widget_set_tooltip_text(card, ImageGenWords.scaffoldHint)
            Gtk.connect(UnsafeMutableRawPointer(card), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.studio.choose(aspect: aspect)
                    self?.fill(prompt)
                }
            }
            gtk_flow_box_insert(op(grid), card, -1)
        }
        gtk_box_append(ptr(column), grid)
        gtk_box_append(ptr(stagePicture), column)
    }

    private func cycleEngine() {
        studio.advance(.engine)
        render()
    }

    private func cycleAspect() {
        studio.advance(.aspect)
        render()
    }

    /// Always the same meaning: hand the render one more picture to work from. Letting go of one
    /// lives on the tile that shows it, because with several attached a single chip could not say
    /// which one it would drop.
    private func referencePressed() {
        guard slot.references.count < ImageGenSlot.referenceLimit else { return }
        offerReference()
    }

    private func renderPressed() {
        if slot.isBusy {
            studio.stop()
        } else {
            submit()
        }
    }

    func handle(_ command: ImageGenCommand) {
        guard !slot.isBusy || command.duringRender else { return }
        switch command {
        case .submit: submit()
        case .stop: studio.stop()
        case .engine: cycleEngine()
        case .aspect: cycleAspect()
        case .size: studio.advance(.size)
        case .detail: studio.advance(.detail)
        case .cutout: studio.setCutout(!slot.cutout)
        case .seed: studio.toggleSeedHold()
        case .reference: referencePressed()
        case .again: performAgain()
        case .save: perform(.save)
        case .copy: perform(.copy)
        case .open: openStage()
        case .next: step(by: 1)
        case .previous: step(by: -1)
        }
    }

    /// Walks the session's own pictures. The newest is first, so "next" moves back through the
    /// session the way the eye reads it rather than the way the list is stored. A kept picture
    /// on the stage is left behind the moment either direction is pressed.
    private func step(by delta: Int) {
        guard slot.pictures.count > 1 else { return }
        let paths = slot.pictures.map(\.path)
        let current = slot.onStage?.path ?? paths[0]
        guard let index = paths.firstIndex(of: current) else { return }
        let next = (index + delta + paths.count) % paths.count
        studio.show(paths[next])
    }

    /// The same words again, with whichever engine made the picture in the first place when that
    /// is known — a kept picture rolled again should paint with what made it, not with whatever
    /// chip happens to be selected.
    private func performAgain() {
        if let kept = studio.keptStage {
            guard let prompt = kept.facts?.recipe?.prompt else { return }
            studio.again(prompt: prompt, engine: kept.facts?.recipe?.engine)
        } else {
            studio.again()
        }
    }

    private func perform(_ action: ImageGenAction) {
        guard let path = stagePath else { return }
        switch action {
        case .save:
            guard let data = studio.bytes(atPath: path) else { return }
            Gtk.saveFile(
                parent: hostWindow, suggestedName: stageFileName(), data: data
            ) { [weak self] savedPath in
                guard let savedPath else { return }
                Gtk.onMain { [weak self] in
                    self?.onNotice?(ImageGenWords.savedNotice(path: savedPath))
                }
            }
        case .copy:
            guard let data = studio.bytes(atPath: path) else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tailscode_clipboard_set_image_png(base, gsize(data.count))
            }
            onNotice?(ImageGenWords.copiedNotice)
        case .open:
            openStage()
        case .again:
            performAgain()
        case .reference:
            if let kept = studio.keptStage {
                studio.attach(ImageGenReference(path: path, kept: kept.item))
            } else {
                studio.attach(ImageGenReference(path: path))
            }
            resetPlaceholder()
            focusPrompt()
        case .discard:
            studio.discard(path)
        case .share, .stage:
            break
        }
    }

    func submit() {
        let words = promptText
        studio.submit(prompt: words)
        if !fills { promptText = "" }
        render()
    }

    /// The prompt says what it will do with what is attached, so the mode is legible in the one
    /// place a person is already looking.
    private func resetPlaceholder() {
        let text: String
        switch slot.references.count {
        case 0: text = ImageGenNotice.emptyBody
        case 1: text = Localized.text("What to change in %@…", slot.references[0].name)
        default: text = ImageGenWords.addressHint
        }
        gtk_entry_set_placeholder_text(ptr(entry), text)
    }

    /// Several at once: a person picking three pictures for one edit picks them in one gesture,
    /// and the order they picked is the order the words address them in.
    private func offerReference() {
        Gtk.openFiles(parent: hostWindow) { [weak self] paths in
            guard let self, !paths.isEmpty else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                for path in paths { self.studio.attach(ImageGenReference(path: path)) }
                self.resetPlaceholder()
                self.focusPrompt()
            }
        }
    }

    /// Full size. In the grid that is a window of its own beside the pane; in the modal studio it
    /// is this surface giving the picture everything it has, because a window opened over a modal
    /// is how the pointer was lost. A kept picture has no `ImageGenPicture` of its own record, so
    /// one is built from its facts just for the viewer — nothing here is kept beyond the call.
    private func openStage() {
        guard let key = stageTextureKey, let bits = textures[key], bits != 0 else { return }
        if fills {
            zoomed.toggle()
            render()
            return
        }
        if let kept = studio.keptStage, let path = kept.path {
            let facts = kept.facts
            let synthetic = ImageGenPicture(
                path: path, prompt: ImageGenFacts.caption(for: facts),
                engine: facts?.recipe?.engine ?? .quality,
                mode: facts?.recipe?.mode ?? .generate, aspect: facts?.aspect ?? .square,
                seconds: 0, seed: facts?.recipe?.seed ?? 0, madeAt: facts?.modifiedAt ?? Date())
            DrawViewer.present(picture: synthetic, textureBits: bits, parent: hostWindow)
            return
        }
        guard let picture = slot.onStage else { return }
        DrawViewer.present(picture: picture, textureBits: bits, parent: hostWindow)
    }


    /// The studio: the ask as a form down the left with room for a paragraph, the picture in the
    /// middle with its progress drawn over it and its words and verbs under it, and the machine's
    /// shelf down the right as rows that carry the words and the facts rather than only squares.
    private func buildStudio() {
        let columns = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(columns, 1)
        gtk_widget_set_vexpand(columns, 1)
        gtk_box_append(ptr(columns), buildBrief())
        gtk_box_append(ptr(columns), buildStageColumn())
        gtk_box_append(ptr(columns), buildShelfColumn())
        gtk_box_append(ptr(root), columns)
    }

    private func sectionLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "draw-lbl", selectable: false)
        gtk_widget_set_margin_bottom(label, 4)
        return label
    }

    private func section(_ title: String, _ body: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(column), sectionLabel(title))
        gtk_box_append(ptr(column), body)
        return column
    }

    private func buildBrief() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(briefColumn, "draw-brief")
        Gtk.margins(briefColumn, 14)
        gtk_widget_set_vexpand(briefColumn, 1)

        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(frame, "draw-textarea")
        gtk_text_view_set_wrap_mode(ptr(promptView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(ptr(promptView), 0)
        gtk_text_view_set_top_margin(ptr(promptView), 10)
        gtk_text_view_set_bottom_margin(ptr(promptView), 10)
        gtk_text_view_set_left_margin(ptr(promptView), 12)
        gtk_text_view_set_right_margin(ptr(promptView), 12)
        gtk_widget_set_size_request(promptView, -1, 120)
        gtk_widget_set_tooltip_text(promptView, ImageGenNotice.emptyBody)
        gtk_box_append(ptr(frame), promptView)
        Gtk.connect(UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(promptView))!), "changed") {
            [weak self] in
            Gtk.onMain { [weak self] in self?.refreshHint() }
        }
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_box_append(ptr(words), frame)
        let countRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_hexpand(countLabel, 1)
        gtk_box_append(ptr(countRow), countLabel)
        Gtk.addClass(enhanceChip, "draw-link")
        gtk_widget_remove_css_class(enhanceChip, "draw-chip")
        gtk_box_append(ptr(countRow), enhanceChip)
        gtk_box_append(ptr(words), countRow)
        Gtk.addClass(helperMenu, "draw-link")
        Gtk.addClass(helperMenu, "draw-helper-link")
        gtk_widget_remove_css_class(helperMenu, "draw-chip")
        gtk_menu_button_set_can_shrink(op(helperMenu), 0)
        gtk_menu_button_set_always_show_arrow(op(helperMenu), 1)
        gtk_widget_set_halign(helperMenu, GTK_ALIGN_END)
        gtk_box_append(ptr(words), helperMenu)
        gtk_box_append(ptr(words), rewriteBox)
        gtk_box_append(ptr(words), hintBox)
        gtk_box_append(ptr(briefColumn), section(ImageGenStudioWords.wordsTitle, words))

        gtk_entry_set_placeholder_text(ptr(avoidEntry), ImageGenWords.avoidPlaceholder)
        Gtk.addClass(avoidEntry, "draw-avoid")
        gtk_widget_set_hexpand(avoidEntry, 1)
        gtk_box_append(ptr(briefColumn), section(ImageGenStudioWords.avoidTitle, avoidEntry))

        let engines = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_set_homogeneous(ptr(engines), 1)
        for engine in ImageGenEngine.allCases {
            let card = gtk_button_new()!
            Gtk.addClass(card, "draw-opt")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let name = Gtk.label(engine.label, css: "draw-opt-title", selectable: false)
            let detail = Gtk.label(engine.detail, css: "draw-opt-detail", wrap: true, selectable: false)
            gtk_label_set_xalign(op(name), 0)
            gtk_label_set_xalign(op(detail), 0)
            gtk_box_append(ptr(lines), name)
            gtk_box_append(ptr(lines), detail)
            gtk_button_set_child(ptr(card), lines)
            Gtk.connect(UnsafeMutableRawPointer(card), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.studio.choose(engine: engine) }
            }
            engineCards[engine] = card
            gtk_box_append(ptr(engines), card)
        }
        gtk_box_append(ptr(briefColumn), section(ImageGenStudioWords.engineTitle, engines))

        let shapes = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_set_homogeneous(ptr(shapes), 1)
        for aspect in ImageGenAspect.allCases {
            let button = gtk_button_new()!
            Gtk.addClass(button, "draw-shape")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
            gtk_widget_set_halign(lines, GTK_ALIGN_CENTER)
            let glyph = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(glyph, "draw-shape-glyph")
            let ratio = aspect.ratio
            let longest: Double = 20
            let wide = ratio.width >= ratio.height
            let short = longest * Double(wide ? ratio.height : ratio.width)
                / Double(wide ? ratio.width : ratio.height)
            gtk_widget_set_size_request(
                glyph, Int32(wide ? longest : max(8, short)), Int32(wide ? max(8, short) : longest))
            gtk_widget_set_halign(glyph, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(glyph, GTK_ALIGN_END)
            gtk_widget_set_size_request(button, -1, 46)
            gtk_widget_set_valign(lines, GTK_ALIGN_END)
            let name = Gtk.label(aspect.ratioLabel, css: "draw-shape-label", selectable: false)
            gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_halign(name, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(lines), glyph)
            gtk_box_append(ptr(lines), name)
            gtk_button_set_child(ptr(button), lines)
            gtk_widget_set_tooltip_text(button, aspect.short)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.studio.choose(aspect: aspect) }
            }
            aspectButtons[aspect] = button
            gtk_box_append(ptr(shapes), button)
        }
        gtk_box_append(ptr(briefColumn), section(ImageGenStudioWords.shapeTitle, shapes))

        let pair = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_set_homogeneous(ptr(pair), 1)
        let sizes = segment()
        for size in ImageGenSize.allCases {
            let button = Gtk.button(size.short, css: ["draw-seg-item"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.studio.choose(size: size) }
            }
            gtk_widget_set_tooltip_text(button, size.detail)
            gtk_widget_set_hexpand(button, 1)
            sizeButtons[size] = button
            gtk_box_append(ptr(sizes), button)
        }
        gtk_box_append(ptr(pair), section(ImageGenStudioWords.sizeTitle, sizes))
        let details = segment()
        for detail in ImageGenDetail.allCases {
            let button = Gtk.button("\(detail.steps)", css: ["draw-seg-item"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.studio.choose(detail: detail) }
            }
            gtk_widget_set_tooltip_text(button, detail.detail)
            gtk_widget_set_hexpand(button, 1)
            detailButtons[detail] = button
            gtk_box_append(ptr(details), button)
        }
        gtk_box_append(ptr(pair), section(ImageGenStudioWords.detailTitle, details))
        gtk_box_append(ptr(briefColumn), pair)

        let toggles = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(
            ptr(toggles),
            toggleRow(ImageGenStudioWords.holdSeedTitle, detail: seedDetailLabel, control: seedSwitch))
        let cutoutDetail = Gtk.label(
            ImageGenStudioWords.cutoutDetail, css: "draw-toggle-detail", wrap: true, selectable: false)
        gtk_box_append(
            ptr(toggles),
            toggleRow(ImageGenWords.cutoutTitle, detail: cutoutDetail, control: cutoutSwitch))
        Gtk.onNotify(UnsafeMutableRawPointer(seedSwitch), property: "active") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.syncingSwitches else { return }
                let wants = gtk_switch_get_active(op(self.seedSwitch)) != 0
                if wants != self.slot.seed.isHeld { self.studio.toggleSeedHold() }
            }
        }
        Gtk.onNotify(UnsafeMutableRawPointer(cutoutSwitch), property: "active") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.syncingSwitches else { return }
                let wants = gtk_switch_get_active(op(self.cutoutSwitch)) != 0
                if wants != self.slot.cutout { self.studio.setCutout(wants) }
            }
        }
        gtk_box_append(ptr(briefColumn), toggles)

        let references = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_halign(referenceStrip, GTK_ALIGN_START)
        gtk_box_append(ptr(references), referenceStrip)
        gtk_widget_set_halign(referenceChip, GTK_ALIGN_START)
        gtk_box_append(ptr(references), referenceChip)
        gtk_box_append(
            ptr(briefColumn), section(ImageGenStudioWords.referencesTitle, references))

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), briefColumn)
        gtk_widget_set_vexpand(scroller, 1)

        let footer = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.margins(footer, top: 10, bottom: 12, leading: 14, trailing: 14)
        Gtk.addClass(renderButton, "draw-go-wide")
        gtk_widget_set_hexpand(renderButton, 1)
        gtk_box_append(ptr(footer), renderButton)
        gtk_label_set_text(op(keysLabel), ImageGenStudioWords.keysLine)
        gtk_label_set_justify(op(keysLabel), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(keysLabel), 0.5)
        gtk_box_append(ptr(footer), keysLabel)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "draw-brief-scroller")
        gtk_widget_set_size_request(column, Self.briefWidth, -1)
        gtk_widget_set_hexpand(column, 0)
        gtk_widget_set_vexpand(column, 1)
        gtk_box_append(ptr(column), scroller)
        gtk_box_append(ptr(column), Gtk.hairline())
        gtk_box_append(ptr(column), footer)
        return column
    }

    /// The two side columns are a fixed width and the stage takes the rest: a form column
    /// that grew with its longest label and a shelf that grew with its longest prompt left
    /// the picture the narrowest thing on a wide screen.
    private static let briefWidth: Int32 = 340
    private static let shelfWidth: Int32 = 320

    private func segment() -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(box, "draw-seg")
        gtk_box_set_homogeneous(ptr(box), 1)
        return box
    }

    private func toggleRow(
        _ title: String, detail: UnsafeMutablePointer<GtkWidget>,
        control: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_hexpand(lines, 1)
        let name = Gtk.label(title, css: "draw-toggle-title", selectable: false)
        gtk_box_append(ptr(lines), name)
        gtk_label_set_xalign(op(detail), 0)
        gtk_box_append(ptr(lines), detail)
        gtk_box_append(ptr(row), lines)
        gtk_widget_set_valign(control, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), control)
        return row
    }

    private func buildStageColumn() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_hexpand(stageColumn, 1)
        gtk_widget_set_vexpand(stageColumn, 1)

        let overlay = gtk_overlay_new()!
        gtk_widget_set_vexpand(overlay, 1)
        gtk_widget_set_hexpand(overlay, 1)
        Gtk.margins(stagePicture, 24)
        gtk_widget_set_vexpand(stagePicture, 1)
        gtk_widget_set_hexpand(stagePicture, 1)
        Gtk.addClass(stagePicture, "draw-stage-room")
        gtk_overlay_set_child(op(overlay), stagePicture)

        let progress = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 5)
        Gtk.addClass(progress, "draw-progress-block")
        Gtk.margins(progress, top: 0, bottom: 14, leading: 24, trailing: 24)
        gtk_widget_set_valign(progress, GTK_ALIGN_END)
        gtk_widget_set_hexpand(progress, 1)
        gtk_widget_set_hexpand(statusLabel, 1)
        gtk_label_set_xalign(op(statusLabel), 0)
        gtk_label_set_ellipsize(op(statusLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(clockLabel), 1)
        gtk_box_append(ptr(progressRow), statusLabel)
        gtk_box_append(ptr(progressRow), clockLabel)
        gtk_box_append(ptr(progress), progressRow)
        Gtk.addClass(progressBar, "draw-progress-bar")
        gtk_box_append(ptr(progress), progressBar)
        gtk_widget_set_can_target(progress, 0)
        gtk_overlay_add_overlay(op(overlay), progress)
        gtk_widget_set_visible(progressLabel, 0)
        gtk_box_append(ptr(stageColumn), overlay)
        gtk_box_append(ptr(stageColumn), zoomHint)

        gtk_box_append(ptr(stageColumn), Gtk.hairline())
        Gtk.margins(underRow, top: 10, bottom: 14, leading: 24, trailing: 24)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        gtk_label_set_xalign(op(captionLabel), 0)
        gtk_label_set_wrap(op(captionLabel), 1)
        gtk_label_set_lines(op(captionLabel), 2)
        gtk_label_set_ellipsize(op(captionLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(captionLabel), 72)
        Gtk.addClass(captionLabel, "draw-caption-lead")
        gtk_label_set_xalign(op(factsLabel), 0)
        gtk_label_set_ellipsize(op(factsLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(factsLabel), 72)
        gtk_label_set_xalign(op(keptHintLabel), 0)
        gtk_label_set_wrap(op(keptHintLabel), 0)
        gtk_label_set_ellipsize(op(keptHintLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(keptHintLabel), 72)
        gtk_widget_remove_css_class(keptHintLabel, "dim")
        Gtk.addClass(keptHintLabel, "draw-facts")
        gtk_box_append(ptr(words), captionLabel)
        gtk_box_append(ptr(words), factsLabel)
        gtk_box_append(ptr(words), keptHintLabel)
        gtk_box_append(ptr(underRow), words)
        Gtk.addClass(actionRow, "draw-actions")
        gtk_widget_set_halign(actionRow, GTK_ALIGN_START)
        gtk_box_append(ptr(underRow), actionRow)
        gtk_box_append(ptr(stageColumn), underRow)
        return stageColumn
    }

    private func buildShelfColumn() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(shelfColumn, "draw-shelf-column")
        gtk_widget_set_size_request(shelfColumn, Self.shelfWidth, -1)
        gtk_widget_set_hexpand(shelfColumn, 0)
        gtk_widget_set_vexpand(shelfColumn, 1)
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(header, top: 12, bottom: 8, leading: 12, trailing: 12)
        Gtk.addClass(shelfHeadingLabel, "draw-shelf-heading")
        gtk_box_append(ptr(header), shelfHeadingLabel)
        gtk_box_append(ptr(header), shelfCountLabel)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        gtk_box_append(ptr(header), shelfRefreshButton)
        gtk_box_append(ptr(shelfColumn), header)
        gtk_label_set_xalign(op(shelfStatusLabel), 0)
        gtk_label_set_max_width_chars(op(shelfStatusLabel), 36)
        Gtk.margins(shelfStatusLabel, top: 0, bottom: 8, leading: 12, trailing: 12)
        gtk_box_append(ptr(shelfColumn), shelfStatusLabel)
        Gtk.margins(shelfList, top: 0, bottom: 12, leading: 12, trailing: 12)
        gtk_scrolled_window_set_policy(op(shelfScroller), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(shelfScroller), shelfList)
        gtk_widget_set_vexpand(shelfScroller, 1)
        gtk_box_append(ptr(shelfColumn), shelfScroller)
        return shelfColumn
    }

    /// The form's own controls told what the slot holds, so every decision reads the same on
    /// the card, the segment and the switch as it does on a chip.
    private func refreshStudioControls() {
        guard fills else { return }
        for (engine, card) in engineCards { mark(card, on: engine == slot.engine) }
        for (aspect, button) in aspectButtons {
            mark(button, on: aspect == slot.aspect)
            gtk_widget_set_sensitive(button, slot.applies(.aspect) ? 1 : 0)
        }
        for (size, button) in sizeButtons {
            mark(button, on: size == slot.size)
            gtk_widget_set_sensitive(button, slot.applies(.size) ? 1 : 0)
        }
        for (detail, button) in detailButtons {
            mark(button, on: detail == slot.detail)
            gtk_widget_set_sensitive(button, slot.applies(.detail) ? 1 : 0)
        }
        syncingSwitches = true
        gtk_switch_set_active(op(seedSwitch), slot.seed.isHeld ? 1 : 0)
        gtk_switch_set_active(op(cutoutSwitch), slot.cutout && slot.cutoutApplies ? 1 : 0)
        syncingSwitches = false
        gtk_widget_set_sensitive(cutoutSwitch, slot.cutoutApplies ? 1 : 0)
        gtk_label_set_text(op(seedDetailLabel), ImageGenStudioWords.holdSeedDetail(seed: slot.seed))
        gtk_widget_set_tooltip_text(
            seedSwitch, slot.seed.isHeld ? ImageGenWords.seedHeldHint : ImageGenWords.seedRollsHint)
        gtk_widget_set_tooltip_text(cutoutSwitch, ImageGenWords.cutoutHint)
        refreshCount(promptText)
    }

    /// One row on the shelf, kept between refreshes: the library announces every thumbnail it
    /// decodes and every file head it reads, and a shelf that rebuilt a hundred rows on each of
    /// those announcements spent the main loop on widgets and never reached a frame. A row is
    /// built once per listing and told what changed.
    private struct ShelfRow {
        let button: UnsafeMutablePointer<GtkWidget>
        let thumbSlot: UnsafeMutablePointer<GtkWidget>
        let words: UnsafeMutablePointer<GtkWidget>
        let facts: UnsafeMutablePointer<GtkWidget>
        var hasPicture: Bool
    }

    private var shelfRows: [String: ShelfRow] = [:]
    private var shelfOrder: [String] = []
    private var inFlightRow: ShelfRow?

    /// The shelf as rows: the thumbnail, the words that made the picture, and its facts — with
    /// the render in flight as the first row, since that is where it will land.
    private func refreshShelfRows() {
        let library = studio.library
        gtk_label_set_text(
            op(shelfHeadingLabel), ImageGenLibraryWords.heading(machine: studio.endpoint.shortName))
        refreshInFlightRow()

        if let failure = library.failure, library.items.isEmpty {
            clearShelfRows()
            gtk_label_set_text(op(shelfCountLabel), "")
            gtk_label_set_text(op(shelfStatusLabel), failure.reason(machine: studio.endpoint.shortName))
            gtk_widget_set_visible(shelfStatusLabel, 1)
            return
        }
        if library.items.isEmpty {
            clearShelfRows()
            gtk_label_set_text(op(shelfCountLabel), "")
            gtk_label_set_text(
                op(shelfStatusLabel),
                library.loading
                    ? ImageGenLibraryWords.loading
                    : "\(ImageGenLibraryWords.emptyTitle)\n\(ImageGenLibraryWords.emptyBody)")
            gtk_widget_set_visible(shelfStatusLabel, 1)
            return
        }
        gtk_label_set_text(
            op(shelfCountLabel),
            ImageGenLibraryWords.line(count: library.items.count, staleSince: library.staleSince))
        gtk_widget_set_visible(shelfStatusLabel, 0)

        let ids = library.items.map(\.id)
        if ids != shelfOrder {
            clearShelfRows()
            for item in library.items {
                let row = makeShelfRow(busy: false) { [weak self] in
                    Gtk.onMain { [weak self] in self?.studio.showKept(item) }
                }
                shelfRows[item.id] = row
                gtk_box_append(ptr(shelfList), row.button)
            }
            shelfOrder = ids
        }
        let onStageID = onStageLibraryID
        for item in library.items {
            guard var row = shelfRows[item.id] else { continue }
            library.describe(item)
            let facts = library.facts[item.id]
            setLabel(row.words, ImageGenFacts.caption(for: facts))
            setLabel(row.facts, ImageGenFacts.line(for: facts))
            if !row.hasPicture, let bits = library.textures[item.id], bits != 0,
                let picture = Gtk.pictureWidget(bits: bits)
            {
                gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_COVER)
                gtk_widget_remove_css_class(picture, "draw-picture")
                Gtk.removeChildren(of: row.thumbSlot)
                gtk_widget_remove_css_class(row.thumbSlot, "draw-tile-empty")
                gtk_box_append(ptr(row.thumbSlot), Self.squareThumb(picture))
                row.hasPicture = true
                shelfRows[item.id] = row
            }
            if item.id == onStageID {
                Gtk.addClass(row.button, "draw-row-on")
            } else {
                gtk_widget_remove_css_class(row.button, "draw-row-on")
            }
        }
    }

    private func setLabel(_ label: UnsafeMutablePointer<GtkWidget>, _ text: String) {
        let current = gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
        if current != text { gtk_label_set_text(op(label), text) }
    }

    private func clearShelfRows() {
        for (_, row) in shelfRows { gtk_box_remove(ptr(shelfList), row.button) }
        shelfRows = [:]
        shelfOrder = []
    }

    /// The render in flight is the first row while it runs and nothing once it lands, because
    /// by then it is the newest picture in the listing.
    private func refreshInFlightRow() {
        guard slot.isBusy, case .painting(let prompt, let engine, _) = slot.phase else {
            if let row = inFlightRow {
                gtk_box_remove(ptr(shelfList), row.button)
                inFlightRow = nil
            }
            return
        }
        if inFlightRow == nil {
            let row = makeShelfRow(busy: true, onClick: nil)
            gtk_box_prepend(ptr(shelfList), row.button)
            inFlightRow = row
        }
        guard let row = inFlightRow else { return }
        setLabel(row.words, studio.progress?.line ?? prompt)
        setLabel(
            row.facts,
            ImageGenStudioWords.inFlightFacts(
                engine: engine, aspect: slot.mode == .edit ? nil : slot.aspect,
                since: studio.startedAt))
    }

    /// A picture cropped to a square, whatever its shape: a GtkPicture asks for the width its
    /// paintable has and a box grants it, so a wide render took twice the room of a tall one and
    /// the rows never lined up. A viewport with no scrolling allocates exactly its own size.
    private static let thumbSide: Int32 = 64

    private static func squareThumb(_ picture: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let frame = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(frame), GTK_POLICY_EXTERNAL, GTK_POLICY_EXTERNAL)
        gtk_scrolled_window_set_child(op(frame), picture)
        gtk_widget_set_size_request(frame, thumbSide, thumbSide)
        gtk_widget_set_hexpand(frame, 0)
        gtk_widget_set_vexpand(frame, 0)
        gtk_widget_set_overflow(frame, GTK_OVERFLOW_HIDDEN)
        Gtk.addClass(frame, "draw-row-thumb")
        return frame
    }

    private func makeShelfRow(busy: Bool, onClick: (@Sendable () -> Void)?) -> ShelfRow {
        let button = gtk_button_new()!
        Gtk.addClass(button, "draw-row")
        if busy { Gtk.addClass(button, "draw-row-busy") }
        gtk_widget_set_focusable(button, 0)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let thumbSlot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(thumbSlot, busy ? "draw-row-thumb-busy" : "draw-tile-empty")
        Gtk.addClass(thumbSlot, "draw-row-thumb")
        gtk_widget_set_size_request(thumbSlot, Self.thumbSide, Self.thumbSide)
        gtk_widget_set_valign(thumbSlot, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), thumbSlot)
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_hexpand(lines, 1)
        gtk_widget_set_valign(lines, GTK_ALIGN_CENTER)
        let words = Gtk.label(
            "", css: busy ? "draw-row-words-busy" : "draw-row-words", wrap: true, selectable: false)
        gtk_label_set_lines(op(words), 2)
        gtk_label_set_ellipsize(op(words), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(words), 28)
        let facts = Gtk.label("", css: "draw-row-facts", selectable: false)
        gtk_label_set_ellipsize(op(facts), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(facts), 28)
        gtk_box_append(ptr(lines), words)
        gtk_box_append(ptr(lines), facts)
        gtk_box_append(ptr(row), lines)
        gtk_button_set_child(ptr(button), row)
        if let onClick {
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        } else {
            gtk_widget_set_sensitive(button, 0)
        }
        return ShelfRow(button: button, thumbSlot: thumbSlot, words: words, facts: facts, hasPicture: false)
    }

    var hostWindow: UnsafeMutablePointer<GtkWidget>? {
        guard let root = gtk_widget_get_root(ptr(root)) else { return nil }
        return UnsafeMutablePointer(root)
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

extension Gtk {
    fileprivate static func pictureWidget(bits: UInt)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return nil }
        guard let widget = tailscode_picture_for_texture(OpaquePointer(raw)) else { return nil }
        gtk_picture_set_content_fit(op(widget), GTK_CONTENT_FIT_CONTAIN)
        Gtk.addClass(widget, "draw-picture")
        return widget
    }
}

extension UnsafeMutablePointer where Pointee == GtkWidget {
    /// The render in flight, painted where the picture will be so the eye never has to go
    /// looking for where the answer arrives. The same placeholder stands in for a kept picture
    /// whose original is still on its way from the machine.
    fileprivate func appendWorking(room: Bool) {
        let pulse = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(pulse, "draw-working")
        gtk_widget_set_size_request(pulse, room ? 420 : 240, room ? 320 : 190)
        gtk_widget_set_halign(pulse, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(pulse, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(pulse, 1)
        gtk_box_append(ptr(self), pulse)
    }

    /// An empty studio makes its case rather than showing a grey rectangle.
    fileprivate func appendEmpty(room: Bool) {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(column, 1)
        let title = Gtk.label(ImageGenWords.emptyTitle, css: "draw-empty-title", selectable: false)
        let body = Gtk.label(
            ImageGenWords.emptyBody, css: "dim", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(body), 48)
        gtk_label_set_justify(op(body), GTK_JUSTIFY_CENTER)
        gtk_box_append(ptr(column), title)
        gtk_box_append(ptr(column), body)
        gtk_box_append(ptr(self), column)
    }
}
