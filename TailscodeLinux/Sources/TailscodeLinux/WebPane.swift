import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A page living inside the split tree. WebKitGTK's view is a GtkWidget, so the page is tiled by
/// the same paned tree as the transcripts around it — the dividers resize it, zoom hides its
/// siblings, and closing it hands the space back. An empty slot asks for an address in its own
/// body; a loaded one gets out of the way entirely, because a browser pane that keeps chrome is
/// just a small browser window.
final class WebPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var slot: WebSlot
    private var web: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let entry = gtk_entry_new()!
    private let headingLabel: UnsafeMutablePointer<GtkWidget>
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>
    private var callbackBox: UnsafeMutableRawPointer?

    var onChange: (@Sendable () -> Void)?

    init(target: WebTarget?) {
        slot = WebSlot(target: target)
        headingLabel = Gtk.label(Localized.text("Browse"), css: "video-heading", selectable: false)
        hintLabel = Gtk.label(slot.hint, css: "dim", selectable: false)
        reasonLabel = Gtk.label("", css: "dim", selectable: false)
        buildRoot()
        if let target { point(at: target) } else { render() }
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "web-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_widget_set_valign(askBox, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(askBox, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(askBox, 1)
        Gtk.margins(askBox, 24)
        gtk_entry_set_placeholder_text(ptr(entry), slot.prompt)
        gtk_widget_set_size_request(entry, 380, -1)
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            self?.submit()
        }
        gtk_box_append(ptr(askBox), headingLabel)
        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), hintLabel)
        gtk_box_append(ptr(root), askBox)
    }

    var target: WebTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }
    var currentAddress: String? { slot.currentURL }

    /// One line for the headless driver: the phase, then what the slot is showing.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .showing: phase = "showing"
        case .failed: phase = "failed"
        }
        return "\(phase) \(slot.currentURL ?? slot.target?.url ?? "-") [\(slot.title)]"
    }

    func focusPrompt() {
        gtk_widget_grab_focus(entry)
    }

    func submit() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        guard let target = WebTarget.classify(String(cString: raw)) else { return }
        point(at: target)
    }

    func point(at target: WebTarget) {
        slot.point(at: target)
        guard tailscode_web_available() != 0 else {
            slot.failed(Localized.text("This build has no WebKitGTK, so a slot cannot browse"))
            render()
            return
        }
        guard ensureView() else {
            slot.failed(Localized.text("The web view would not start"))
            render()
            return
        }
        tailscode_web_load(web, target.url)
        render()
    }

    func ask() {
        slot.ask()
        gtk_editable_set_text(op(entry), slot.draft)
        render()
        focusPrompt()
        gtk_editable_select_region(op(entry), 0, -1)
    }

    func handle(_ command: WebCommand) {
        guard let web else { return }
        switch command {
        case .address:
            ask()
        case .back, .forward, .reload, .stop:
            guard !slot.isAsking else { return }
            tailscode_web_verb(web, verb(for: command))
        case .zoomIn, .zoomOut, .zoomReset:
            slot.zoom = WebCommand.zoom(slot.zoom, command)
            tailscode_web_zoom(web, slot.zoom)
            render()
        }
    }

    private func verb(for command: WebCommand) -> String {
        switch command {
        case .back: return "back"
        case .forward: return "forward"
        case .reload: return "reload"
        default: return "stop"
        }
    }

    func shutdown() {
        if let web {
            tailscode_web_free(web)
            self.web = nil
            surface = nil
        }
        if let callbackBox {
            Unmanaged<Box>.fromOpaque(callbackBox).release()
            self.callbackBox = nil
        }
    }

    private func ensureView() -> Bool {
        if web != nil { return true }
        guard tailscode_web_available() != 0 else { return false }
        let box = Box(pane: self)
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard
            let created = tailscode_web_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    box.pane?.received(event: event, payload: payload)
                }, raw)
        else {
            Unmanaged<Box>.fromOpaque(raw).release()
            return false
        }
        web = created
        callbackBox = raw
        guard let widget = tailscode_web_widget(created) else { return false }
        surface = widget
        gtk_box_append(ptr(root), widget)
        return true
    }

    /// What the engine says about the page, turned into what the pane says about itself. A refused
    /// page keeps the slot and explains itself rather than emptying the pane.
    private func received(event: String, payload: String) {
        switch event {
        case "title":
            slot.arrived(url: slot.currentURL, title: payload)
        case "uri":
            slot.arrived(url: payload, title: slot.pageTitle)
        case "progress":
            slot.progress(Double(payload) ?? 0)
        case "history":
            slot.canGoBack = payload.hasPrefix("1")
            slot.canGoForward = payload.hasSuffix("1")
        case "error":
            slot.failed(payload.isEmpty ? Localized.text("That page would not open") : payload)
        default:
            return
        }
        render()
    }

    private func render() {
        let asking = slot.isAsking
        var failed = false
        if case .failed(let reason) = slot.phase {
            failed = true
            gtk_label_set_text(op(reasonLabel), reason)
        }
        gtk_widget_set_visible(askBox, asking || failed ? 1 : 0)
        gtk_widget_set_visible(reasonLabel, failed ? 1 : 0)
        if let surface { gtk_widget_set_visible(surface, asking || failed ? 0 : 1) }
        gtk_label_set_text(op(hintLabel), slot.hint)
        onChange?()
    }

    private final class Box {
        weak var pane: WebPane?
        init(pane: WebPane) { self.pane = pane }
    }
}
