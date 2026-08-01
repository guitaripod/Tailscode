import CAdw
import Foundation
import TailscodeCore

#if HAS_VTE
    import CVte
#endif

/// A shell in the project the conversation is working in.
///
/// With `vte4` present this is a real terminal — your own `$SHELL`, your rc files, your aliases,
/// your completions, full escape handling — so "the convenience tools my shell has" means exactly
/// that rather than an approximation of them.
///
/// Without it, the pane is still useful rather than absent: a login shell runs one command at a
/// time (`$SHELL -lc`) in the same directory, which sources the same rc files and so resolves the
/// same aliases and functions, and the output is shown as it would be. It says which of the two it
/// is, because a half-terminal that pretends to be a terminal is worse than one that admits it.
final class TerminalPane: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var directory: String?

    #if HAS_VTE
        private let terminal = vte_terminal_new()!
        private var spawned = false
    #else
        private let output = gtk_text_view_new()!
        private let entry = gtk_entry_new()!
        private var history: [String] = []
        private var historyIndex = 0
        private var runTask: Task<Void, Never>?
    #endif

    init() {
        Gtk.addClass(widget, "canvas")
        #if HAS_VTE
            buildTerminal()
        #else
            buildRunner()
        #endif
    }

    func takeFocus() {
        #if HAS_VTE
            gtk_widget_grab_focus(terminal)
        #else
            gtk_widget_grab_focus(entry)
        #endif
    }

    func setDirectory(_ path: String?) {
        guard directory != path else { return }
        directory = path
        #if HAS_VTE
            guard spawned else {
                respawn()
                return
            }
            // A running shell is not restarted to follow the conversation: it is told to change
            // directory, the way you would. History, environment and whatever is half-typed all
            // survive.
            if let path {
                let line = "cd \(path.replacingOccurrences(of: "'", with: "'\\''"))\n"
                vte_terminal_feed_child(ptr(terminal), line, gssize(line.utf8.count))
            }
        #else
            appendLine("cd \(path ?? "~")", css: "dim")
        #endif
    }

    #if HAS_VTE
        private func buildTerminal() {
            gtk_widget_set_vexpand(terminal, 1)
            gtk_widget_set_hexpand(terminal, 1)
            vte_terminal_set_scrollback_lines(ptr(terminal), 10000)
            vte_terminal_set_mouse_autohide(ptr(terminal), 1)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_child(op(scroller), terminal)
            gtk_widget_set_vexpand(scroller, 1)
            gtk_box_append(ptr(widget), scroller)
            respawn()
        }

        /// Spawns the user's own login shell so every alias, function and completion they have is
        /// present. A shell that is not theirs is not the tool they asked for.
        private func respawn() {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), nil]
            defer { argv.forEach { free($0) } }
            spawned = true
            vte_terminal_spawn_async(
                ptr(terminal), VtePtyFlags(rawValue: 0), directory, &argv, nil,
                GSpawnFlags(rawValue: 4), nil, nil, nil, -1, nil, nil, nil)
        }
    #else
        private func buildRunner() {
            let notice = Gtk.label(
                Localized.text("Install vte4 for a full terminal · running one command at a time"),
                css: "dim", selectable: false)
            Gtk.margins(notice, top: 6, bottom: 2, leading: 10, trailing: 10)
            gtk_box_append(ptr(widget), notice)

            gtk_text_view_set_editable(ptr(output), 0)
            gtk_text_view_set_monospace(ptr(output), 1)
            gtk_text_view_set_left_margin(ptr(output), 10)
            gtk_text_view_set_right_margin(ptr(output), 10)
            Gtk.addClass(output, "mono")
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_child(op(scroller), output)
            gtk_widget_set_vexpand(scroller, 1)
            gtk_box_append(ptr(widget), scroller)

            gtk_entry_set_placeholder_text(ptr(entry), Localized.text("Run a command…"))
            Gtk.addClass(entry, "mono")
            Gtk.margins(entry, top: 4, bottom: 6, leading: 8, trailing: 8)
            Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
                self?.runFromEntry()
            }
            gtk_box_append(ptr(widget), entry)
        }

        private func runFromEntry() {
            guard let raw = gtk_editable_get_text(op(entry)) else { return }
            let command = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return }
            gtk_editable_set_text(op(entry), "")
            history.append(command)
            historyIndex = history.count
            appendLine("$ \(command)", css: "prompt-glyph")
            run(command)
        }

        private func run(_ command: String) {
            let cwd = directory
            runTask?.cancel()
            runTask = Task { [weak self] in
                let result = Self.shell(command, in: cwd)
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    if !result.isEmpty { self?.appendLine(result, css: nil) }
                }
            }
        }

        /// `-lc` rather than `-c`: a login shell reads the same rc files the user's own terminal
        /// does, so an alias or function they rely on resolves here too.
        static func shell(_ command: String, in directory: String?) -> String {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash")
            process.arguments = ["-lc", command]
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "could not start a shell" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }

        private func appendLine(_ text: String, css: String?) {
            let buffer = gtk_text_view_get_buffer(ptr(output))
            var end = GtkTextIter()
            gtk_text_buffer_get_end_iter(buffer, &end)
            gtk_text_buffer_insert(buffer, &end, text + "\n", -1)
            gtk_text_buffer_get_end_iter(buffer, &end)
            let mark = gtk_text_buffer_create_mark(buffer, nil, &end, 0)
            gtk_text_view_scroll_to_mark(ptr(output), mark, 0, 1, 0, 1)
        }
    #endif
}
