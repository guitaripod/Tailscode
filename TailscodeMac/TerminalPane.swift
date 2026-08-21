import AppKit
import os
import TailscodeCore

#if !TAILSCODE_MAS
    /// A shell in the project the conversation is working in.
    ///
    /// The Mac build has no embedded terminal, and the pane does not pretend to be one: a login shell
    /// runs one command at a time (`$SHELL -lc`) in the conversation's directory, which sources the
    /// same rc files and so resolves the same aliases and functions, and the output is shown as it
    /// returns. The notice line says exactly that, because a half-terminal that pretends to be a
    /// terminal is worse than one that admits it — the same honesty the Linux app applies when vte4
    /// is absent.
    @MainActor
    final class TerminalPane: NSViewController {
        private let notice = NSTextField(labelWithString: "")
        private let scrollView = NSScrollView()
        private let output = NSTextView()
        private let field = NSTextField()
        private var history: [String] = []
        private var historyIndex = 0
        private var directory: String?
        private var runTask: Task<Void, Never>?
        private let runningProcess = OSAllocatedUnfairLock<Process?>(uncheckedState: nil)

        init() {
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let container = AppearanceView()
            container.wantsLayer = true
            container.onAppearanceChange = { [weak self] in self?.applyPaneColours() }

            notice.stringValue = Localized.text(
                "Running one command at a time in a login shell on this Mac — not a full terminal")
            notice.font = MacTheme.Ramp.font(.panelFootnote)
            notice.lineBreakMode = .byTruncatingTail
            notice.translatesAutoresizingMaskIntoConstraints = false

            configureOutput()
            configureField()
            container.addSubview(notice)
            container.addSubview(scrollView)
            container.addSubview(field)

            NSLayoutConstraint.activate([
                notice.topAnchor.constraint(
                    equalTo: container.topAnchor, constant: MacTheme.Spacing.s),
                notice.leadingAnchor.constraint(
                    equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
                notice.trailingAnchor.constraint(
                    equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
                scrollView.topAnchor.constraint(
                    equalTo: notice.bottomAnchor, constant: MacTheme.Spacing.xs),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(
                    equalTo: field.topAnchor, constant: -MacTheme.Spacing.xs),
                field.leadingAnchor.constraint(
                    equalTo: container.leadingAnchor, constant: MacTheme.Spacing.s),
                field.trailingAnchor.constraint(
                    equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.s),
                field.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.s),
            ])
            view = container
            applyPaneColours()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            NotificationCenter.default.addObserver(
                self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        }

        @objc private func themeChanged() {
            applyPaneColours()
        }

        /// The pane's ground is a `CGColor`, which is the light it was resolved under rather than a
        /// colour that answers again — so a system that crossed into dark, or a palette that moved,
        /// would otherwise leave a pale slab under a dark transcript until the app was relaunched.
        private func applyPaneColours() {
            view.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
            notice.textColor = MacTheme.Color.tertiaryLabel
        }

        func takeFocus() {
            view.window?.makeFirstResponder(field)
        }

        /// Whether a keystroke belongs to the shell rather than the app: true while the command field
        /// or the output is first responder, which is what puts the shortcut engine in the terminal
        /// context — only Ctrl+Shift moves and zoom, everything else stays with the shell.
        func ownsFocus(in window: NSWindow?) -> Bool {
            guard let responder = window?.firstResponder else { return false }
            if responder === output { return true }
            if let editor = field.currentEditor(), responder === editor { return true }
            return responder === field
        }

        /// The runner cannot tell a shell to change directory — there is no shell alive between
        /// commands — so the follow is a fact echoed dim into the log: the next command runs there.
        ///
        /// The path belongs to whichever machine runs the bridge, and this shell belongs to this Mac.
        /// When the two are not the same box the directory does not exist here, and echoing `cd` for
        /// it would promise a place every command then failed to start in — so the pane says whose
        /// disk it is standing on instead.
        func setDirectory(_ path: String?) {
            guard directory != path else { return }
            directory = path
            guard let path, !FileManager.default.fileExists(atPath: path) else {
                appendLine("cd \(path ?? "~")", color: MacTheme.Color.tertiaryLabel)
                return
            }
            appendLine(
                Localized.text(
                    "%@ is the agent's folder, not one on this Mac — commands run from your home folder.",
                    path),
                color: MacTheme.Color.tertiaryLabel)
        }

        private func configureOutput() {
            output.isEditable = false
            output.isRichText = false
            output.drawsBackground = false
            output.font = MacTheme.Ramp.font(.code)
            output.textContainerInset = NSSize(width: MacTheme.Spacing.s, height: MacTheme.Spacing.xs)
            output.autoresizingMask = [.width]
            output.isVerticallyResizable = true
            output.textContainer?.widthTracksTextView = true
            scrollView.documentView = output
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
        }

        private func configureField() {
            field.font = MacTheme.Ramp.font(.code)
            field.placeholderString = Localized.text("Run a command…")
            field.target = self
            field.action = #selector(runFromField)
            field.cell?.sendsActionOnEndEditing = false
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        @objc private func runFromField() {
            let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return }
            field.stringValue = ""
            history.append(command)
            historyIndex = history.count
            appendLine("$ \(command)", color: MacTheme.Color.label, emphasized: true)
            run(command)
        }

        /// One command, one login shell, off the main actor. A new command cancels the previous run
        /// outright — its process is terminated and whatever it would still have printed is dropped —
        /// because two commands interleaving into one log reads as neither.
        ///
        /// A run that printed nothing still closes its own line, because a command that finished
        /// silently and one that is still going are otherwise the same picture.
        private func run(_ command: String) {
            let cwd = Self.localDirectory(directory)
            runTask?.cancel()
            runningProcess.withLockUnchecked { process in
                process?.terminate()
                process = nil
            }
            let holder = runningProcess
            runTask = Task { [weak self] in
                let result = await Task.detached { Self.shell(command, in: cwd, holding: holder) }
                    .value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard !result.isEmpty else {
                    self.appendLine(
                        Localized.text("(no output)"), color: MacTheme.Color.tertiaryLabel)
                    return
                }
                self.appendLine(result, color: MacTheme.Color.label)
            }
        }

        /// The agent's directory when this Mac actually has it, and the home folder when it does not:
        /// a shell told to start in a path that is not here fails before it has read the command, and
        /// answers every one of them with the same four words.
        private static func localDirectory(_ path: String?) -> String {
            guard let path, FileManager.default.fileExists(atPath: path) else {
                return NSHomeDirectory()
            }
            return path
        }

        /// `-lc` rather than `-c`: a login shell reads the same rc files the user's own terminal
        /// does, so an alias or function they rely on resolves here too. The started process is
        /// parked in `holding` so the next command can terminate it.
        nonisolated static func shell(
            _ command: String, in directory: String?,
            holding holder: OSAllocatedUnfairLock<Process?>? = nil
        ) -> String {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-lc", command]
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else {
                return Localized.text("could not start a shell")
            }
            holder?.withLockUnchecked { $0 = process }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            holder?.withLockUnchecked { if $0 === process { $0 = nil } }
            return String(data: data, encoding: .utf8) ?? ""
        }

        /// The echoed command is the same size as the output under it and heavier, not a second size:
        /// two mono sizes alternating down a log break the one column the eye is following.
        private func appendLine(_ text: String, color: NSColor, emphasized: Bool = false) {
            guard let storage = output.textStorage else { return }
            let body = MacTheme.Ramp.font(.code)
            let font =
                emphasized
                ? NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .semibold)
                : body
            storage.append(
                NSAttributedString(
                    string: text.hasSuffix("\n") ? text : text + "\n",
                    attributes: [.font: font, .foregroundColor: color]))
            output.scrollToEndOfDocument(nil)
        }

        private func stepHistory(_ delta: Int) {
            guard !history.isEmpty else { return }
            let next = historyIndex + delta
            guard next >= 0 else { return }
            if next >= history.count {
                historyIndex = history.count
                field.stringValue = ""
                return
            }
            historyIndex = next
            field.stringValue = history[next]
            field.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    extension TerminalPane: NSTextFieldDelegate {
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                stepHistory(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                stepHistory(1)
                return true
            default:
                return false
            }
        }
    }
#endif
