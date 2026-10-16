import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The Quality lens: the screen checked the way a reviewer would. The running app is asked to audit
/// itself when the lens opens and after each build, and what it finds is listed in plain words,
/// failures before warnings. Pressing a finding outlines the offending view on the picture and
/// pins it in Inspect; when something fails, one button hands the whole list to the agent.
final class PreviewQualityView: PreviewLensView, @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)

    private let model: PreviewInspectModel
    private let message = Gtk.label("", css: "preview-row-detail", wrap: true, selectable: false)
    private let countLabel = Gtk.label("", css: "preview-row-title", wrap: true, selectable: false)
    private let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let fixButton: UnsafeMutablePointer<GtkWidget>
    private let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private var drawn: [String] = []
    private var buttons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private(set) var findings: [InspectFinding] = []

    init(model: PreviewInspectModel) {
        self.model = model
        fixButton = Gtk.button(Localized.text("Fix these"), css: ["preview-chip"]) {}
        build()
    }

    private func build() {
        Gtk.margins(root, top: 10, bottom: 12, leading: 8, trailing: 14)
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        PreviewPane.capWidth(message, 32)
        gtk_box_append(ptr(root), message)

        PreviewPane.capWidth(countLabel, 16)
        gtk_widget_set_hexpand(countLabel, 1)
        gtk_widget_set_valign(countLabel, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(fixButton, GTK_ALIGN_CENTER)
        Gtk.connect(UnsafeMutableRawPointer(fixButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.fix() }
        }
        let top = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(top), countLabel)
        gtk_box_append(ptr(top), fixButton)
        gtk_box_append(ptr(body), top)
        gtk_box_append(ptr(body), list)
        gtk_box_append(ptr(root), body)
        paint()
    }

    func open() {
        model.setActive(false)
        model.read(audit: true)
        paint()
    }

    func close() {
        model.mark(nodeID: nil, fails: true)
    }

    private var ordered: [InspectFinding] {
        guard let audit = model.audit else { return [] }
        let failing = audit.findings.filter { PreviewInspectReading.words(for: $0).fails }
        let warning = audit.findings.filter { !PreviewInspectReading.words(for: $0).fails }
        return failing + warning
    }

    private var hasFailure: Bool { findings.contains { PreviewInspectReading.words(for: $0).fails } }

    func paint() {
        if let failure = model.failure, model.audit == nil {
            show(message: failure)
            return
        }
        guard let audit = model.audit else {
            show(message: Localized.text("Checking the screen…"))
            return
        }
        findings = ordered
        gtk_widget_set_visible(message, 0)
        gtk_widget_set_visible(body, 1)
        let calm = audit.findings.isEmpty
        let summary = PreviewInspectReading.summary(audit)
        gtk_label_set_text(op(countLabel), calm ? "✓  \(summary)" : summary)
        Gtk.setTone(countLabel, calm ? "preview-ok" : "preview-row-title", from: ["preview-ok", "preview-row-title"])
        gtk_widget_set_visible(fixButton, hasFailure ? 1 : 0)
        let signature = findings.map { "\($0.id)|\(model.tree?.nodeCount ?? 0)" }
        guard signature != drawn else {
            paintSelection()
            return
        }
        drawn = signature
        rebuild()
    }

    private func show(message text: String) {
        gtk_label_set_text(op(message), text)
        gtk_widget_set_visible(message, 1)
        gtk_widget_set_visible(body, 0)
    }

    private func rebuild() {
        Gtk.removeChildren(of: list)
        buttons = [:]
        for finding in findings {
            let words = PreviewInspectReading.words(for: finding)
            let row = gtk_button_new()!
            Gtk.addClass(row, "preview-shot")
            let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let title = Gtk.label(words.title, css: words.fails ? "preview-bad" : "preview-attention", selectable: false)
            let subject = PreviewInspectReading.subject(of: finding, in: model.tree)
            let place = Gtk.label(subject, css: "preview-row-title", wrap: true, selectable: false)
            let detail = Gtk.label(words.detail, css: "preview-row-detail", wrap: true, selectable: false)
            for label in [place, detail] { PreviewPane.capWidth(label, 26) }
            gtk_box_append(ptr(column), title)
            if !subject.isEmpty { gtk_box_append(ptr(column), place) }
            gtk_box_append(ptr(column), detail)
            gtk_button_set_child(ptr(row), column)
            tailscode_set_accessible_label(row, "\(words.title). \(subject). \(words.detail)")
            let id = finding.id
            Gtk.connect(UnsafeMutableRawPointer(row), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.choose(findingID: id) }
            }
            buttons[id] = row
            gtk_box_append(ptr(list), row)
        }
        paintSelection()
    }

    private var chosen: String?

    private func paintSelection() {
        for (id, row) in buttons {
            Gtk.setTone(row, id == chosen ? "preview-shot-on" : nil, from: ["preview-shot-on"])
        }
    }

    func choose(findingID id: String) {
        guard let finding = findings.first(where: { $0.id == id }), let node = finding.nodeId else { return }
        chosen = id
        model.select(nodeID: node)
        model.mark(nodeID: node, fails: PreviewInspectReading.words(for: finding).fails)
        paintSelection()
    }

    func fix() {
        guard hasFailure else { return }
        model.askAgent(PreviewInspectReading.fixRequest(findings: findings, tree: model.tree, app: model.appName))
    }

    var countText: String { gtk_label_get_text(op(countLabel)).map(String.init(cString:)) ?? "" }
    var messageText: String { gtk_label_get_text(op(message)).map(String.init(cString:)) ?? "" }
    var offersFix: Bool { gtk_widget_get_visible(fixButton) != 0 && gtk_widget_get_visible(body) != 0 }

    var summary: String {
        "quality findings=\(findings.count) fails=\(findings.filter { PreviewInspectReading.words(for: $0).fails }.count) chosen=\(chosen ?? "-")"
    }

    func drive(_ command: String) -> Bool {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return false }
        switch verb {
        case "choose":
            guard parts.count > 1, let index = Int(parts[1]), findings.indices.contains(index) else { return false }
            choose(findingID: findings[index].id)
        case "fix": fix()
        default: return false
        }
        return true
    }
}
