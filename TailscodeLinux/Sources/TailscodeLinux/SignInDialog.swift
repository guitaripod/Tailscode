import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A signed-out Claude is a state, not a reply — and signing back in is split across two
/// machines: the server hands over the URL, this one opens it in the browser and returns the
/// code. Never "open a terminal".
enum SignInDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        serverName: String,
        backend: any AuthenticatingBackend,
        onSignedIn: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Sign in Claude on %@", serverName), parent: parent, width: 520)

        let status = Gtk.label(
            Localized.text("Asking %@ for a sign-in link…", serverName), css: "row-detail",
            wrap: true, selectable: false)
        gtk_box_append(ptr(content), status)

        let linkButton = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_box_append(ptr(content), linkButton)

        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Paste the code the browser shows"))
        gtk_widget_set_sensitive(entry, 0)
        gtk_box_append(ptr(content), entry)

        let statusBits = UInt(bitPattern: status)
        let linkBits = UInt(bitPattern: linkButton)
        let entryBits = UInt(bitPattern: entry)
        let windowBits = UInt(bitPattern: window)

        let setStatus: @Sendable (String) -> Void = { text in
            Gtk.onMain {
                guard let raw = UnsafeMutableRawPointer(bitPattern: statusBits) else { return }
                gtk_label_set_text(op(raw), text)
            }
        }

        Task {
            do {
                let auth = try await backend.beginSignIn()
                guard let url = auth.pending?.url else {
                    setStatus(
                        Localized.text(
                            "%@ did not hand over a link — is the bridge up to date?", serverName))
                    return
                }
                setStatus(
                    Localized.text("Open the link, sign in, then paste the code back here."))
                Gtk.onMain {
                    if let raw = UnsafeMutableRawPointer(bitPattern: linkBits) {
                        let box: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                        gtk_box_append(
                            ptr(box),
                            Gtk.button(Localized.text("Open sign-in link"), css: ["suggested-action"]) {
                                openInBrowser(url)
                            })
                        gtk_box_append(
                            ptr(box), Gtk.label(url, css: "tree-path", wrap: true))
                    }
                    if let raw = UnsafeMutableRawPointer(bitPattern: entryBits) {
                        gtk_widget_set_sensitive(ptr(raw), 1)
                    }
                }
            } catch {
                setStatus(Localized.text("Could not start a sign-in: %@", "\(error)"))
            }
        }

        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            let entry: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let code = Dialogs.entryText(entry)
            guard !code.isEmpty else { return }
            setStatus(Localized.text("Submitting the code…"))
            Task {
                do {
                    let auth = try await backend.submitSignInCode(code)
                    if auth.loggedIn {
                        onSignedIn()
                        Gtk.onMain {
                            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                                gtk_window_destroy(ptr(raw))
                            }
                        }
                    } else {
                        setStatus(
                            Localized.text("The server took the code but still reports signed out."))
                    }
                } catch {
                    setStatus(Localized.text("The code was refused: %@", "\(error)"))
                }
            }
        }

        gtk_window_present(ptr(window))
    }

    static func openInBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url]
        try? process.run()
    }
}
