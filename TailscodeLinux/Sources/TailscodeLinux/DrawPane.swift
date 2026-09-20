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
    private let helperChip: UnsafeMutablePointer<GtkWidget>
    /// The words as they were before a rewrite, kept for exactly one undo — a helper that
    /// misread the brief must never cost the sentence a person actually wrote.
    private var beforeEnhance: String?
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
        helperChip = Gtk.menuButton("", css: ["draw-chip"]) {
            guard let studio = helperHeld.value else { return [] }
            var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
            let current = studio.helper
            for model in studio.knownHelperModels {
                let address = studio.knownHelperAddress ?? current?.address ?? ""
                rows.append(
                    (
                        title: model, detail: address.isEmpty ? nil : address,
                        action: {
                            Gtk.onMain {
                                guard !address.isEmpty else { return }
                                studio.setHelper(ImageGenHelper(address: address, model: model))
                            }
                        }
                    ))
            }
            if rows.isEmpty {
                rows.append(
                    (
                        title: ImageGenWords.enhanceLookingTitle,
                        detail: ImageGenWords.enhanceLookingHint,
                        action: { Gtk.onMain { studio.lookForHelper() } }
                    ))
            }
            if let current {
                rows.append(
                    (
                        title: current.enabled
                            ? ImageGenWords.helperOffTitle : ImageGenWords.enhanceTitle,
                        detail: current.enabled ? ImageGenWords.helperOffHint : nil,
                        action: {
                            Gtk.onMain {
                                var flipped = current
                                flipped.enabled.toggle()
                                studio.setHelper(flipped)
                            }
                        }
                    ))
            }
            return rows
        }
        referenceChip = Gtk.button("", css: ["draw-chip"], onClick: {})
        renderButton = Gtk.button("", css: ["draw-go"], onClick: {})
        buildRoot()
        render()
        refreshNotice()
        studio.checkMachine()
        studio.library.refresh()
        studioObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in
                self?.render()
                self?.onChange?()
            }
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
        gtk_editable_set_text(op(entry), text)
    }

    func driverSubmit() {
        submit()
    }

    /// The harness's way in to the one control that writes words, so a headless run exercises the
    /// same path a press does.
    func driverEnhance() {
        enhancePressed()
    }

    func focusPrompt() {
        gtk_widget_grab_focus(entry)
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

    /// Lets go of the view. A studio of this pane's own dies with it; the shared one keeps
    /// painting, because closing a window is not cancelling a render.
    func shutdown() {
        if let studioObserver { NotificationCenter.default.removeObserver(studioObserver) }
        studioObserver = nil
        if studio !== ImageStudio.shared { studio.release() }
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "draw-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

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

        for chip in [engineChip, aspectChip, sizeChip, enhanceChip, referenceChip, moreChip] {
            gtk_widget_set_halign(chip, GTK_ALIGN_START)
            gtk_box_append(ptr(chipRow), chip)
        }
        Gtk.addClass(moreRow, "draw-chips-more")
        gtk_widget_set_halign(moreRow, GTK_ALIGN_START)
        for chip in [detailChip, cutoutChip, seedChip, helperChip] {
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
        gtk_widget_set_visible(avoidEntry, showsMore ? 1 : 0)
        gtk_button_set_label(
            ptr(moreChip), showsMore ? ImageGenWords.lessTitle : ImageGenWords.moreTitle)
        mark(moreChip, on: showsMore)
        refreshEnhance()

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
            helper.map(ImageGenWords.enhanceHint) ?? ImageGenWords.enhanceLookingHint)
        gtk_widget_set_sensitive(enhanceChip, busy || !slot.isBusy ? 1 : 0)
        mark(enhanceChip, on: busy || beforeEnhance != nil)
        gtk_menu_button_set_label(
            op(helperChip),
            helper.map { "\(ImageGenWords.helperTitle) · \($0.chip)" }
                ?? ImageGenWords.enhanceLookingTitle)
        gtk_widget_set_tooltip_text(
            helperChip, helper.map { $0.displayHost } ?? ImageGenWords.enhanceLookingHint)
        mark(helperChip, on: helper?.enabled == true)
    }

    /// Press once to have the brief written out, press again to get your own sentence back. A
    /// rewrite that lands also takes the shape the helper asked for, unless a person has already
    /// chosen one by hand this session.
    private func enhancePressed() {
        if let original = beforeEnhance {
            fill(original)
            beforeEnhance = nil
            refreshEnhance()
            return
        }
        guard !studio.enhancing else { return }
        let typed = gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        let brief = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            focusPrompt()
            return
        }
        let pane = Weak(self)
        studio.enhance(brief) { result in
            Gtk.onMain {
                guard let pane = pane.value else { return }
                switch result {
                case .success(let written):
                    pane.beforeEnhance = brief
                    if let aspect = written.1, pane.slot.applies(.aspect) {
                        pane.studio.choose(aspect: aspect)
                    }
                    pane.fill(written.0)
                    if let helper = pane.studio.helper {
                        pane.onNotice?(ImageGenWords.enhancedNotice(helper))
                    }
                case .failure(let failure):
                    pane.onNotice?(
                        pane.studio.helper == nil
                            ? ImageGenWords.enhanceMissing : failure.reason)
                }
                pane.refreshEnhance()
            }
        }
        refreshEnhance()
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
        let typed = gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        guard !slot.isBusy, ImageGenBrief.isThin(typed) else {
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
        gtk_editable_set_text(op(entry), text)
        gtk_editable_set_position(op(entry), -1)
        focusPrompt()
        refreshHint()
    }

    private func refreshNotice() {
        let text = fills ? ImageGenNotice.costLine : ImageGenNotice.splitCostLine
        gtk_label_set_text(op(noticeLabel), text)
        let unspent = slot.pictures.isEmpty && !slot.isBusy && studio.keptStage == nil
        gtk_widget_set_visible(noticeLabel, unspent ? 1 : 0)
    }

    private func refreshStatus() {
        switch slot.phase {
        case .asking:
            gtk_label_set_text(op(statusLabel), "")
            gtk_widget_set_visible(statusLabel, 0)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
        case .composing:
            gtk_label_set_text(op(statusLabel), "")
            gtk_widget_set_visible(statusLabel, 0)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
        case .painting(let prompt, let engine, let mode):
            let verb =
                mode == .edit ? Localized.text("Editing with %@", engine.label)
                : Localized.text("Painting with %@", engine.label)
            gtk_label_set_text(
                op(statusLabel), "\(verb) — \(prompt.ellipsized(to: 72))")
            gtk_widget_set_visible(statusLabel, 1)
            gtk_label_set_text(op(progressLabel), elapsedLine())
            gtk_widget_set_visible(progressLabel, 1)
            refreshProgressBar()
            startTicking()
        case .failed(_, let reason):
            gtk_label_set_text(op(statusLabel), reason)
            gtk_widget_set_visible(statusLabel, 1)
            gtk_widget_set_visible(progressLabel, 0)
            gtk_widget_set_visible(progressBar, 0)
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
        Gtk.removeChildren(of: stagePicture)
        let key = stageTextureKey
        let hasBits = key.flatMap { textures[$0] }.map { $0 != 0 } ?? false
        if slot.isBusy || !hasBits { zoomed = false }
        for widget in [
            captionLabel, factsLabel, keptHintLabel, actionRow, shelfBox, chipRow, promptRow,
        ] {
            gtk_widget_set_visible(widget, zoomed ? 0 : 1)
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

        if slot.isBusy {
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
            gtk_box_append(ptr(stagePicture), button)
        } else if studio.keptStage != nil {
            stagePicture.appendWorking(room: fills)
        } else {
            appendEmptyStage()
        }

        guard !zoomed else { return }
        let showFacts = stageAvailable && !slot.isBusy
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
                self.refreshProgressBar()
                self.tick()
            }
        }
    }

    /// Whether Escape has something of this surface's own to close before it closes the surface.
    var isZoomed: Bool { zoomed }

    func unzoom() {
        guard zoomed else { return }
        zoomed = false
        render()
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
        guard !slot.isBusy, stagePath != nil else {
            gtk_widget_set_visible(actionRow, 0)
            return
        }
        gtk_widget_set_visible(actionRow, 1)
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

    /// Every picture the machine keeps, newest first — the words never say the shelf is empty or
    /// unsupported by leaving it blank.
    private func refreshShelf() {
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
        let body = Gtk.label(ImageGenWords.emptyBody, css: "dim", wrap: true, selectable: false)
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
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        studio.submit(prompt: String(cString: raw))
        gtk_editable_set_text(op(entry), "")
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
