import CAdw
import Foundation
import TailscodeCore

/// The one step of this feature that happens somewhere else. Google will only run its device flow
/// for an application registered to somebody, so before YouTube can be signed into at all a person
/// has to make one — and the honest thing is to say so as a short numbered list with the console
/// one button away, rather than to hide a requirement behind a button that fails.
///
/// What gets pasted here is a client id and secret every copy of a desktop app would ship anyway;
/// they are not the account, and the account's tokens still go to the secret store.
enum YouTubeSetupDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: YouTubeSetup.heading, parent: parent, width: 520)

        let why = Gtk.label(YouTubeSetup.why, css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(why), 62)
        gtk_box_append(ptr(content), why)

        for (index, step) in YouTubeSetup.steps.enumerated() {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let number = Gtk.label("\(index + 1)", css: "watch-step", selectable: false)
            gtk_widget_set_valign(number, GTK_ALIGN_START)
            gtk_widget_set_size_request(number, 16, -1)
            let text = Gtk.label(step, css: "dim", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(text), 56)
            gtk_widget_set_hexpand(text, 1)
            gtk_box_append(ptr(line), number)
            gtk_box_append(ptr(line), text)
            gtk_box_append(ptr(content), line)
        }

        let current = MediaClientConfig.youtube
        let identity = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(identity), YouTubeSetup.idPrompt)
        if let current { gtk_editable_set_text(op(identity), current.id) }
        let secret = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(secret), YouTubeSetup.secretPrompt)
        gtk_entry_set_visibility(ptr(secret), 0)
        if let current { gtk_editable_set_text(op(secret), current.secret) }
        gtk_box_append(ptr(content), identity)
        gtk_box_append(ptr(content), secret)

        let status = Gtk.label("", css: "watch-note", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(status), 58)
        gtk_widget_set_visible(status, 0)
        gtk_box_append(ptr(content), status)

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        gtk_box_append(ptr(content), buttons)

        let identityBits = UInt(bitPattern: identity)
        let secretBits = UInt(bitPattern: secret)
        let statusBits = UInt(bitPattern: status)
        let windowBits = UInt(bitPattern: window)

        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Open the console"), css: ["flat"]) {
                SignInDialog.openInBrowser(YouTubeSetup.consoleURL)
            })
        if current != nil {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Forget it"), css: ["destructive-action", "flat"]) {
                    MediaClientConfig.setYouTube(id: "", secret: "")
                    SettingsFile.capture()
                    onSaved()
                    if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                        Dialogs.close(ptr(raw))
                    }
                })
        }
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Save"), css: ["suggested-action"]) {
                guard let identityRaw = UnsafeMutableRawPointer(bitPattern: identityBits),
                    let secretRaw = UnsafeMutableRawPointer(bitPattern: secretBits),
                    let statusRaw = UnsafeMutableRawPointer(bitPattern: statusBits)
                else { return }
                let typedID = text(of: ptr(identityRaw))
                let typedSecret = text(of: ptr(secretRaw))
                guard YouTubeSetup.looksValid(id: typedID, secret: typedSecret) else {
                    gtk_label_set_text(op(statusRaw), YouTubeSetup.rejection)
                    gtk_widget_set_visible(ptr(statusRaw), 1)
                    return
                }
                MediaClientConfig.setYouTube(id: typedID, secret: typedSecret)
                SettingsFile.capture()
                onSaved()
                if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                    Dialogs.close(ptr(raw))
                }
            })

        gtk_window_present(ptr(window))
    }

    private static func text(of entry: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_editable_get_text(op(entry)) else { return "" }
        return String(cString: raw)
    }
}
