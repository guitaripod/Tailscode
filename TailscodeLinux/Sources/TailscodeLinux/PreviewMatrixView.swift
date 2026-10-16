import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Matrix lens: the same screen rendered several ways on the Mac — light, dark, larger text,
/// right to left — one after another, and laid out as a grid to be compared at a glance. The live
/// picture keeps running under it; the host does the rendering on a device of its own.
///
/// The job is followed every 700 ms while it runs and not at all otherwise. Leaving the lens ends
/// the following and lets go of the pictures but remembers the job, so coming back asks the host
/// where it got to rather than starting it again.
final class PreviewMatrixView: PreviewLensView, @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished
    }

    private let context: PreviewLensContext
    private let renderButton: UnsafeMutablePointer<GtkWidget>
    private let startButton: UnsafeMutablePointer<GtkWidget>
    private let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let progress = gtk_progress_bar_new()!
    private let status = Gtk.label("", css: "preview-row-detail", selectable: false)
    private let pages = gtk_stack_new()!
    private let hint = Gtk.label("", css: "preview-status", wrap: true, selectable: false)
    private let grid = gtk_flow_box_new()!
    private let big = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let bigTitle = Gtk.label("", css: "preview-row-title", selectable: false)
    private let bigHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private var phase: Phase = .idle
    private var job: String?
    private var results: [VariantResult] = []
    private var pictures: [Int: Data] = [:]
    private var cells: [UnsafeMutablePointer<GtkWidget>] = []
    private(set) var enlarged: Int?
    private var generation = 0

    private static var idleHint: String {
        Localized.text(
            "Shows your screen in light and dark, at larger text sizes and right to left. Your live preview keeps going meanwhile."
        )
    }

    private static var runningHint: String {
        Localized.text("Showing your screen each way on your Mac, one after another. Your live preview keeps going meanwhile.")
    }

    private static let thumbnailHeight: Int32 = 220
    private static let thumbnailPixels: Int32 = 640

    init(context: PreviewLensContext) {
        self.context = context
        renderButton = Gtk.button(Localized.text("Render the looks"), css: ["preview-chip"]) {}
        startButton = Gtk.button(Localized.text("Render the looks"), css: ["preview-chip"]) {}
        build()
    }

    private func build() {
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        Gtk.margins(header, top: 10, bottom: 6, leading: 14, trailing: 14)
        gtk_widget_set_halign(header, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(renderButton, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(renderButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }
        Gtk.addClass(progress, "preview-progress")
        gtk_widget_set_valign(progress, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(progress, 140, -1)
        gtk_widget_set_visible(progress, 0)
                Gtk.connect(UnsafeMutableRawPointer(startButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.render() }
        }
        gtk_widget_set_halign(startButton, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(startButton, 16)
        gtk_box_append(ptr(header), renderButton)
        gtk_box_append(ptr(header), progress)
        gtk_box_append(ptr(header), status)
        gtk_box_append(ptr(root), header)

        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(words, GTK_ALIGN_CENTER)
        Gtk.margins(words, 24)
        PreviewPane.capWidth(hint, 40)
        gtk_label_set_justify(op(hint), GTK_JUSTIFY_CENTER)
        gtk_label_set_xalign(op(hint), 0.5)
        gtk_label_set_text(op(hint), Self.idleHint)
        gtk_box_append(ptr(words), hint)
        gtk_box_append(ptr(words), startButton)

        gtk_flow_box_set_selection_mode(op(grid), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(op(grid), 1)
        gtk_flow_box_set_min_children_per_line(op(grid), 1)
        gtk_flow_box_set_max_children_per_line(op(grid), 8)
        gtk_flow_box_set_column_spacing(op(grid), 12)
        gtk_flow_box_set_row_spacing(op(grid), 12)
        gtk_widget_set_valign(grid, GTK_ALIGN_START)
        gtk_widget_set_halign(grid, GTK_ALIGN_CENTER)
        Gtk.margins(grid, top: 6, bottom: 14, leading: 14, trailing: 14)
        let gridScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(gridScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(gridScroller), grid)

        let back = Gtk.button("‹", css: ["preview-chip"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.leaveEnlarged() }
        }
        gtk_widget_set_halign(back, GTK_ALIGN_START)
        let bigHeader = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(bigHeader, top: 0, bottom: 0, leading: 14, trailing: 14)
        gtk_box_append(ptr(bigHeader), back)
        gtk_box_append(ptr(bigHeader), bigTitle)
        gtk_widget_set_vexpand(bigHolder, 1)
        Gtk.margins(bigHolder, top: 0, bottom: 12, leading: 14, trailing: 14)
        gtk_box_append(ptr(big), bigHeader)
        gtk_box_append(ptr(big), bigHolder)

        gtk_widget_set_hexpand(pages, 1)
        gtk_widget_set_vexpand(pages, 1)
        gtk_stack_set_transition_type(op(pages), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_add_named(op(pages), words, "hint")
        gtk_stack_add_named(op(pages), gridScroller, "grid")
        gtk_stack_add_named(op(pages), big, "big")
        gtk_stack_set_visible_child_name(op(pages), "hint")
        gtk_box_append(ptr(root), pages)
        paintStart()
    }

    /// Before a run the one button sits under the sentence that explains it; once there is a run to
    /// follow it moves to the header beside the progress.
    private func paintStart() {
        let idle = phase == .idle
        gtk_widget_set_visible(header, idle ? 0 : 1)
        gtk_widget_set_visible(startButton, idle ? 1 : 0)
    }

    func fit(narrow: Bool) {
        gtk_widget_set_size_request(progress, narrow ? 70 : 140, -1)
    }

    func open() {
        guard let job else { return }
        follow(job: job)
    }

    func close() {
        generation += 1
        pictures = [:]
        clearGrid()
        clearEnlarged()
        if case .running = phase { phase = .idle }
        paintStart()
        gtk_label_set_text(op(hint), Self.idleHint)
        gtk_stack_set_visible_child_name(op(pages), "hint")
        gtk_widget_set_visible(progress, 0)
        gtk_label_set_text(op(status), "")
        gtk_widget_set_sensitive(renderButton, 1)
    }

    func render() {
        guard let runner = context.runner() else {
            fail(message: PreviewLensFailure.unreachable)
            return
        }
        if case .running = phase { return }
        generation += 1
        let ticket = generation
        job = nil
        results = []
        pictures = [:]
        clearGrid()
        clearEnlarged()
        phase = .running(done: 0, total: 0)
        paintStart()
        paintProgress(done: 0, total: 0)
        context.tasks.spawn(slot: "job") { [weak self] in
            do {
                let started = try await runner.startVariants(PreviewCompareReading.variantSpecs())
                Gtk.onMain { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.job = started
                }
                try await Self.poll(runner: runner, job: started, owner: self, ticket: ticket)
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func follow(job id: String) {
        guard let runner = context.runner() else { return }
        generation += 1
        let ticket = generation
        phase = .running(done: 0, total: 0)
        paintStart()
        paintProgress(done: 0, total: 0)
        context.tasks.spawn(slot: "job") { [weak self] in
            do {
                try await Self.poll(runner: runner, job: id, owner: self, ticket: ticket)
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.job = nil
                    self.fail(error)
                }
            }
        }
    }

    private static func poll(
        runner: PreviewRunner, job: String, owner: PreviewMatrixView?, ticket: Int
    ) async throws {
        while !Task.isCancelled {
            let reading = try await runner.variantJob(job)
            Gtk.onMain { [weak owner] in
                guard let owner, owner.generation == ticket else { return }
                owner.advance(reading)
            }
            if reading.state != .running {
                var fetched: [Int: Data] = [:]
                for (index, result) in reading.results.enumerated() where result.ok {
                    fetched[index] = try await runner.variantPicture(job, index)
                }
                let kept = fetched
                Gtk.onMain { [weak owner] in
                    guard let owner, owner.generation == ticket else { return }
                    owner.finish(reading, pictures: kept)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(700))
        }
    }

    private func advance(_ reading: VariantJob) {
        guard reading.state == .running else { return }
        phase = .running(done: reading.done, total: reading.total)
        paintProgress(done: reading.done, total: reading.total)
    }

    private func paintProgress(done: Int, total: Int) {
        gtk_label_set_text(op(hint), Self.runningHint)
        gtk_widget_set_sensitive(renderButton, 0)
        gtk_widget_set_visible(progress, 1)
        gtk_progress_bar_set_fraction(op(progress), total > 0 ? Double(done) / Double(total) : 0)
        let words =
            total > 0
            ? Localized.text("Rendering %@ of %@", String(min(done + 1, total)), String(total))
            : Localized.text("Starting")
        gtk_label_set_text(op(status), words)
    }

    func finish(_ reading: VariantJob, pictures fetched: [Int: Data]) {
        results = reading.results
        pictures = fetched
        phase = .finished
        paintStart()
        gtk_widget_set_sensitive(renderButton, 1)
        gtk_widget_set_visible(progress, 0)
        gtk_label_set_text(op(status), "")
        guard reading.state == .done else {
            fail(message: reading.message ?? PreviewLensFailure.unreachable)
            return
        }
        buildGrid()
        gtk_stack_set_visible_child_name(op(pages), "grid")
    }

    private func fail(_ error: Error) {
        fail(message: PreviewLensFailure.words(for: error))
    }

    private func fail(message text: String) {
        phase = .idle
        paintStart()
        gtk_widget_set_sensitive(renderButton, 1)
        gtk_widget_set_visible(progress, 0)
        gtk_label_set_text(op(status), "")
        gtk_label_set_text(op(hint), text)
        gtk_stack_set_visible_child_name(op(pages), "hint")
    }

    private func clearGrid() {
        for cell in cells { gtk_flow_box_remove(op(grid), gtk_widget_get_parent(cell) ?? cell) }
        cells = []
    }

    private func buildGrid() {
        clearGrid()
        for (index, result) in results.enumerated() {
            let cell = gtk_button_new()!
            Gtk.addClass(cell, "preview-cell")
            let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
            if result.ok, let bytes = pictures[index], let thumbnail = Self.thumbnail(bytes) {
                gtk_box_append(ptr(column), thumbnail)
            } else {
                let missing = Gtk.label(
                    result.error ?? Localized.text("Could not render"), css: "preview-attention", wrap: true,
                    selectable: false)
                PreviewPane.capWidth(missing, 18)
                gtk_widget_set_size_request(missing, 120, Self.thumbnailHeight)
                gtk_widget_set_valign(missing, GTK_ALIGN_CENTER)
                gtk_box_append(ptr(column), missing)
            }
            let caption = Gtk.label(result.label, css: "preview-row-title", selectable: false)
            gtk_widget_set_halign(caption, GTK_ALIGN_CENTER)
            if !result.ok {
                Gtk.addClass(caption, "preview-attention")
            }
            gtk_box_append(ptr(column), caption)
            gtk_button_set_child(ptr(cell), column)
            if result.ok {
                Gtk.connect(UnsafeMutableRawPointer(cell), "clicked") { [weak self] in
                    Gtk.onMain { [weak self] in self?.enlarge(index) }
                }
            } else {
                gtk_widget_set_sensitive(cell, 0)
            }
            gtk_flow_box_append(op(grid), cell)
            cells.append(cell)
        }
    }

    private static func thumbnail(_ bytes: Data) -> UnsafeMutablePointer<GtkWidget>? {
        let bits = LensDecode.bits(bytes, longSide: thumbnailPixels)
        guard bits != 0 else { return nil }
        defer { LensDecode.release(bits) }
        guard let size = Gtk.textureSize(bits: bits), let picture = Gtk.studioPicture(bits: bits) else { return nil }
        let aspect = Double(size.width) / Double(size.height)
        gtk_widget_set_size_request(picture, Int32(Double(thumbnailHeight) * aspect), thumbnailHeight)
        gtk_widget_set_hexpand(picture, 0)
        gtk_widget_set_vexpand(picture, 0)
        Gtk.addClass(picture, "preview-picture")
        return picture
    }

    func enlarge(_ index: Int) {
        guard results.indices.contains(index), let bytes = pictures[index] else { return }
        clearEnlarged()
        let bits = LensDecode.bits(bytes)
        guard bits != 0 else { return }
        defer { LensDecode.release(bits) }
        guard let picture = Gtk.studioPicture(bits: bits) else { return }
        gtk_box_append(ptr(bigHolder), picture)
        gtk_label_set_text(op(bigTitle), results[index].label)
        enlarged = index
        gtk_stack_set_visible_child_name(op(pages), "big")
    }

    private func leaveEnlarged() {
        clearEnlarged()
        gtk_stack_set_visible_child_name(op(pages), cells.isEmpty ? "hint" : "grid")
    }

    private func clearEnlarged() {
        Gtk.removeChildren(of: bigHolder)
        enlarged = nil
    }

    var cellCount: Int { cells.count }
    var failedCount: Int { results.filter { !$0.ok }.count }
    var isRendering: Bool {
        if case .running = phase { return true }
        return false
    }

    var summary: String {
        let state: String
        switch phase {
        case .idle: state = "idle"
        case .running(let done, let total): state = "running \(done)/\(total)"
        case .finished: state = "done"
        }
        return "matrix \(state) cells=\(cells.count) failed=\(failedCount) enlarged=\(enlarged.map(String.init) ?? "-")"
    }

    func drive(_ command: String) -> Bool {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "render": render()
        case "enlarge":
            guard parts.count > 1, let index = Int(parts[1]) else { return false }
            enlarge(index)
        case "back": leaveEnlarged()
        default: return false
        }
        return true
    }
}
