import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Signing into Twitch or YouTube, in the smallest window that can honestly do it. No password
/// field and no browser in a pane: the site is opened in the person's own browser, the short code
/// is shown here big enough to compare at a glance, and the confirmation happens over there.
/// `WatchSignIn` owns the whole state machine — the polling, the interval the site asked for, the
/// deadline it set — so this file is only the four states drawn.
enum WatchSignInDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, source: MediaSource,
        onFinished: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Sign in to %@", source.label), parent: parent, width: 440)

        let heading = Gtk.label("", css: "video-heading", selectable: false)
        let detail = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
        let instruction = Gtk.label("", css: "dim", wrap: true, selectable: false)
        let code = Gtk.label("", css: "watch-code", selectable: true)
        let note = Gtk.label("", css: "watch-note", wrap: true, selectable: true)
        gtk_label_set_max_width_chars(op(detail), 52)
        gtk_label_set_max_width_chars(op(instruction), 52)
        gtk_label_set_max_width_chars(op(note), 52)
        gtk_label_set_selectable(op(code), 1)

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)

        gtk_box_append(ptr(content), heading)
        gtk_box_append(ptr(content), detail)
        gtk_box_append(ptr(content), code)
        gtk_box_append(ptr(content), instruction)
        gtk_box_append(ptr(content), note)
        gtk_box_append(ptr(content), buttons)

        let bits = Bits(
            window: UInt(bitPattern: window), heading: UInt(bitPattern: heading),
            detail: UInt(bitPattern: detail), instruction: UInt(bitPattern: instruction),
            code: UInt(bitPattern: code), note: UInt(bitPattern: note),
            buttons: UInt(bitPattern: buttons))

        /// The flow is polled for as long as the window is up and no longer. GTK gives no
        /// destroy-with-a-Swift-value hook, so the window's own signal cancels it — a sheet closed
        /// on the second step must not keep asking Twitch for half an hour.
        let running = Running()
        running.task = Task {
            await WatchSignIn.run(source: source) { flow in
                Gtk.onMain { render(flow, bits, running, onFinished) }
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            running.task?.cancel()
            running.task = nil
        }
        gtk_window_present(ptr(window))
    }

    private static func render(
        _ flow: WatchSignIn, _ bits: Bits, _ running: Running,
        _ onFinished: @escaping @Sendable () -> Void
    ) {
        guard let heading = bits.widget(bits.heading), let detail = bits.widget(bits.detail),
            let instruction = bits.widget(bits.instruction), let code = bits.widget(bits.code),
            let note = bits.widget(bits.note), let buttons = bits.widget(bits.buttons)
        else { return }

        gtk_label_set_text(op(heading), flow.heading)
        gtk_label_set_text(op(detail), flow.detail)
        gtk_label_set_text(op(instruction), flow.instruction ?? "")
        gtk_widget_set_visible(instruction, flow.instruction == nil ? 0 : 1)
        gtk_label_set_text(op(code), flow.code ?? "")
        gtk_widget_set_visible(code, flow.code == nil ? 0 : 1)

        if case .failed(let reason) = flow.step, reason.count > 90 {
            gtk_label_set_text(op(note), reason)
            gtk_widget_set_visible(note, 1)
            gtk_label_set_text(op(detail), Localized.text("This build cannot sign in there yet."))
        } else {
            gtk_widget_set_visible(note, 0)
        }

        Gtk.removeChildren(of: buttons)
        let source = flow.source
        switch flow.step {
        case .starting:
            break
        case .waiting(let prompt):
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Copy code"), css: ["flat"]) {
                    Gtk.copyToClipboard(prompt.userCode)
                })
            gtk_box_append(
                ptr(buttons),
                Gtk.button(flow.actionTitle, css: ["suggested-action"]) {
                    SignInDialog.openInBrowser(prompt.verificationURL)
                })
        case .granted:
            gtk_box_append(
                ptr(buttons),
                Gtk.button(flow.actionTitle, css: ["suggested-action"]) {
                    onFinished()
                    if let window = bits.widget(bits.window) { Dialogs.close(window) }
                })
        case .failed:
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Close"), css: ["flat"]) {
                    if let window = bits.widget(bits.window) { Dialogs.close(window) }
                })
            gtk_box_append(
                ptr(buttons),
                Gtk.button(flow.actionTitle, css: ["suggested-action"]) {
                    running.task?.cancel()
                    running.task = Task {
                        await WatchSignIn.run(source: source) { next in
                            Gtk.onMain { render(next, bits, running, onFinished) }
                        }
                    }
                })
        }
        if case .granted = flow.step { onFinished() }
    }

    /// Widget pointers cross a `@Sendable` boundary as bit patterns, the way every other async
    /// refill in this client does — a raw pointer is not Sendable and a captured one outlives the
    /// widget it named.
    private struct Bits: Sendable {
        let window: UInt
        let heading: UInt
        let detail: UInt
        let instruction: UInt
        let code: UInt
        let note: UInt
        let buttons: UInt

        func widget(_ value: UInt) -> UnsafeMutablePointer<GtkWidget>? {
            UnsafeMutableRawPointer(bitPattern: value).map { ptr($0) }
        }
    }

    private final class Running: @unchecked Sendable {
        var task: Task<Void, Never>?
    }
}
