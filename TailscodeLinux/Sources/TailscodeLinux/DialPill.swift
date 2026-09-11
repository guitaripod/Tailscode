import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The one pill for model and effort, wherever a prompt is aimed: a tinted dot, the model's
/// word, the level's word in its own heat and the five-bar meter, opening the dial on a press and
/// stepping the level under the wheel. The chat's composer and the quick ask both wear it, so a
/// person learns the control once.
final class DialPill: @unchecked Sendable {
    let button: UnsafeMutablePointer<GtkWidget>
    let dial: ModelDialPopover
    private let dot = Gtk.label("●", css: "dial-dot", selectable: false)
    private let modelLabel = Gtk.label("", css: "dial-model", selectable: false)
    private let separator = Gtk.label("·", css: "dial-sep", selectable: false)
    private let effortLabel = Gtk.label("", css: "dial-effort", selectable: false)
    private let meterSlot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    /// The power's word is lit letter by letter from the rainbow, and the rainbow travels along
    /// it on the frame clock — the one level that is a power rather than a heat is the one that
    /// moves, on the same clock and under the same reduced-motion answer as the aura.
    private var shimmerPhase = -1
    private var powerWord: String?

    init(
        css: [String] = [], dial: ModelDialPopover, onStep: @escaping @Sendable (Int) -> Void
    ) {
        self.dial = dial
        button = gtk_menu_button_new()!
        Gtk.addClass(button, "dial-pill")
        for name in css { Gtk.addClass(button, name) }
        gtk_menu_button_set_can_shrink(op(button), 1)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        for widget in [dot, modelLabel, separator, effortLabel] {
            gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), widget)
        }
        gtk_label_set_max_width_chars(op(modelLabel), 22)
        gtk_label_set_xalign(op(effortLabel), 0)
        for widget in [separator, effortLabel, meterSlot] { gtk_widget_set_visible(widget, 0) }
        Gtk.addClass(meterSlot, "dial-meter-slot")
        gtk_widget_set_valign(meterSlot, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), meterSlot)
        gtk_menu_button_set_child(op(button), line)
        gtk_menu_button_set_popover(op(button), dial.popover)
        Gtk.onScroll(button) { dy in
            guard dy != 0 else { return false }
            Gtk.onMain { onStep(dy < 0 ? 1 : -1) }
            return true
        }
    }

    func open() {
        gtk_menu_button_popup(op(button))
    }

    /// The pill wears the same colours the list chips do — the family's hue on the dot, the
    /// tier's heat on the level and its bars — swapped as one class out of the set, so a change
    /// of model repaints the pill it already has. The power's word is set letter by letter from
    /// the shared rainbow and its bars each take a stop of it.
    func render(_ face: DialFace, modelTint: String?) {
        gtk_widget_set_tooltip_text(
            button, face.spoken + " · " + Localized.text("wheel to step the level"))
        Self.swapClass(on: dot, among: Self.modelTintClasses, chosen: modelTint)
        gtk_label_set_text(op(modelLabel), face.modelWord)
        for widget in [separator, effortLabel, meterSlot] {
            gtk_widget_set_visible(widget, face.showsMeter ? 1 : 0)
        }
        gtk_label_set_width_chars(op(effortLabel), Int32(face.slotWidth))
        let effortTint = face.effortWord.flatMap(ModelTint.effortClass)
        Self.swapClass(
            on: effortLabel, among: Self.effortTintClasses + ["dial-effort-server"],
            chosen: face.isServer ? "dial-effort-server" : effortTint)
        if face.isPower, let word = face.effortWord {
            powerWord = word
            shimmerPhase = -1
            gtk_label_set_markup(op(effortLabel), ModelDialPopover.rainbowMarkup(word))
            startShimmer()
        } else {
            powerWord = nil
            shimmerMotion?.lift()
            shimmerMotion = nil
            gtk_label_set_text(op(effortLabel), face.effortWord ?? "")
        }
        Gtk.removeChildren(of: meterSlot)
        gtk_box_append(
            ptr(meterSlot),
            ModelDialPopover.meter(
                heat: face.heat, tint: effortTint, rainbow: face.isPower, ember: face.isEmber))
        for cls in ["dial-pill-power", "dial-pill-server"] {
            gtk_widget_remove_css_class(button, cls)
        }
        if face.isPower { gtk_widget_add_css_class(button, "dial-pill-power") }
        if face.isServer { gtk_widget_add_css_class(button, "dial-pill-server") }
    }

    /// One step of the rainbow every ninety milliseconds, read off the monotonic clock rather
    /// than counted, so a dropped frame costs a frame and not the rhythm; the markup is rewritten
    /// only when the step actually changes, which keeps a pill that is merely on screen cheap.
    private func startShimmer() {
        let motion = RepeatingMotion(holding: false) { [weak self] in
            guard let self, let word = self.powerWord else { return }
            let phase = Int(g_get_monotonic_time() / 90_000) % max(1, word.count)
            guard phase != self.shimmerPhase else { return }
            self.shimmerPhase = phase
            gtk_label_set_markup(
                op(self.effortLabel), ModelDialPopover.rainbowMarkup(word, phase: phase))
        }
        shimmerMotion = motion
        motion.lay(on: effortLabel, meaning: .working)
    }

    private var shimmerMotion: RepeatingMotion?

    static let modelTintClasses: [String] =
        ModelTint.Family.allCases.map(ModelTint.cssClass) + (0..<12).map { "model-hue-\($0)" }
        + ["model-plain"]

    static let effortTintClasses: [String] =
        ModelTint.effortTiers.map { "effort-\($0)" } + ["effort-ultracode"]

    static func swapClass(
        on widget: UnsafeMutablePointer<GtkWidget>, among all: [String], chosen: String?
    ) {
        for cls in all where cls != chosen { gtk_widget_remove_css_class(widget, cls) }
        if let chosen { gtk_widget_add_css_class(widget, chosen) }
    }
}
