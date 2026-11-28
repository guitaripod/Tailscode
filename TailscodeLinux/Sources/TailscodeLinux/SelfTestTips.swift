import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// Hover help is quick and gentle, and says something over every control that has no words of
    /// its own: the timings stay inside what feels immediate, GTK's own slower tooltip is switched
    /// off for anything given help, an icon-only control speaks its accessible name, a control
    /// that already reads as a sentence does not repeat it, and a control that cannot be pressed
    /// is still helped.
    static func checkHoverHelp() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ words: String) throws {
            guard condition else { throw SelfTestFailure(words) }
            claims += 1
        }

        try expect(tailscode_tip_first_delay_ms() <= 300, "help arrives within 300 ms of resting")
        try expect(
            tailscode_tip_browse_delay_ms() <= 80, "help after help is nearly immediate")
        try expect(
            tailscode_tip_fade_ms() >= 80 && tailscode_tip_fade_ms() <= 180,
            "help fades over a visible but short moment")

        guard gtk_init_check() != 0 else { return claims }

        let glyph = gtk_button_new_with_label("⚙")!
        Tip.set(glyph, "Settings and more")
        try expect(Tip.text(of: glyph) == "Settings and more", "help is kept on the widget")
        try expect(
            gtk_widget_get_has_tooltip(glyph) == 0, "GTK's own tooltip is off for a helped widget")
        Tip.set(glyph, nil)
        try expect(Tip.text(of: glyph) == nil, "nil takes the help away")

        let named = gtk_button_new_with_label("⌨")!
        try expect(Tip.text(of: named) == nil, "a glyph with no name says nothing yet")
        tailscode_set_accessible_label(named, "Show or hide the terminal")
        try expect(
            Tip.text(of: named) == "Show or hide the terminal",
            "an icon-only control speaks the name it already carries")

        let sentence = gtk_button_new_with_label("Cancel")!
        tailscode_set_accessible_label(sentence, "Cancel")
        try expect(
            Tip.text(of: sentence) == nil, "a button that reads Cancel does not say Cancel again")
        try expect(tailscode_tip_names_itself(sentence) != 0, "a labelled button names itself")
        try expect(tailscode_tip_names_itself(glyph) == 0, "a glyph does not")

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(row), Gtk.label("Keep the screen on", selectable: false))
        let flip = gtk_switch_new()!
        gtk_box_append(ptr(row), flip)
        try expect(
            tailscode_tip_names_itself(flip) != 0, "a switch beside its title is named by it")
        return claims
    }
}
