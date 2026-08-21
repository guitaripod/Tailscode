import AppKit
import TailscodeCore

#if !TAILSCODE_MAS
    /// Signing into Twitch or YouTube, in the smallest sheet that can honestly do it. No password
    /// field and no browser embedded in a pane: the site is opened in the person's own browser, the
    /// short code is printed here big enough to compare at a glance, and the confirmation happens over
    /// there. `WatchSignIn` owns the whole state machine — the polling, the interval the site asked
    /// for, the deadline it set — so this file is only the four states drawn, the way `SignInSheet`
    /// draws the two halves of a Claude sign-in.
    @MainActor
    final class WatchSignInSheet {
        private static var active: [WatchSignInSheet] = []

        private let sheet: NSWindow
        private let source: MediaSource
        private let onFinished: @MainActor () -> Void
        private let column = NSStackView()
        private let headingLabel = NSTextField(wrappingLabelWithString: "")
        private let detailLabel = NSTextField(wrappingLabelWithString: "")
        private let instructionLabel = NSTextField(wrappingLabelWithString: "")
        private let codeLabel = NSTextField(labelWithString: "")
        private let codeRow = NSStackView()
        private let copyButton = NSButton(title: "", target: nil, action: nil)
        private let actionButton = NSButton(title: "", target: nil, action: nil)
        private let spinner = NSProgressIndicator()
        private var flow: WatchSignIn
        private var running: Task<Void, Never>?
        /// Whether the caller has been told the account landed. The flow reports `granted` once, but a
        /// sheet left open on the finished state must not report it again if it is redrawn.
        private var reported = false

        /// One flow per site at a time. A second press would queue a second sheet behind the first and
        /// poll for a second code the whole time it was invisible — and whichever code the person then
        /// read would be as likely as not to be the one the site was not waiting for.
        static func present(
            on parent: NSWindow, source: MediaSource, onFinished: @escaping @MainActor () -> Void
        ) {
            if let running = active.first(where: { $0.source == source }) {
                (running.sheet.sheetParent ?? running.sheet).makeKeyAndOrderFront(nil)
                return
            }
            let sheet = WatchSignInSheet(source: source, onFinished: onFinished)
            active.append(sheet)
            parent.beginSheet(sheet.sheet) { _ in
                sheet.stop()
                active.removeAll { $0 === sheet }
            }
            sheet.begin()
        }

        private init(source: MediaSource, onFinished: @escaping @MainActor () -> Void) {
            self.source = source
            self.onFinished = onFinished
            flow = WatchSignIn(source: source)
            sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            sheet.title = Localized.text("Sign in to %@", source.label)

            headingLabel.font = MacTheme.Ramp.font(.cardTitle)
            detailLabel.font = MacTheme.Ramp.font(.panelFootnote)
            detailLabel.textColor = MacTheme.Color.secondaryLabel
            instructionLabel.font = MacTheme.Ramp.font(.panelFootnote)
            instructionLabel.textColor = MacTheme.Color.secondaryLabel

            codeLabel.font = MacTheme.Ramp.font(.pairingCode)
            codeLabel.textColor = MacTheme.Color.label
            codeLabel.isSelectable = true
            copyButton.title = Localized.text("Copy")
            copyButton.bezelStyle = .rounded
            copyButton.target = self
            copyButton.action = #selector(copyCode)
            copyButton.setContentHuggingPriority(.required, for: .horizontal)
            codeRow.orientation = .horizontal
            codeRow.alignment = .firstBaseline
            codeRow.spacing = MacTheme.Spacing.m
            codeRow.addArrangedSubview(codeLabel)
            codeRow.addArrangedSubview(copyButton)
            codeRow.addArrangedSubview(Self.spacer())

            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.setContentHuggingPriority(.required, for: .horizontal)

            let close = NSButton(
                title: Localized.text("Close"), target: self, action: #selector(closeSheet))
            close.keyEquivalent = "\u{1B}"
            actionButton.bezelStyle = .rounded
            actionButton.keyEquivalent = "\r"
            actionButton.target = self
            actionButton.action = #selector(actPressed)
            let buttons = NSStackView(views: [spinner, Self.spacer(), close, actionButton])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = MacTheme.Spacing.s

            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = MacTheme.Spacing.m
            column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            column.setViews(
                [headingLabel, detailLabel, codeRow, instructionLabel, buttons], in: .leading)
            column.translatesAutoresizingMaskIntoConstraints = false
            sheet.contentView = column
            column.widthAnchor.constraint(equalToConstant: 460).isActive = true
            for view in [headingLabel, detailLabel, instructionLabel, codeRow, buttons] as [NSView] {
                view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
            }
            apply(flow)
        }

        /// Starts the flow over from nothing. Reached on the first present and again from the button a
        /// failure offers, because a code that expired or a site that refused is answered by asking for
        /// another code, not by making somebody reopen the sheet.
        private func begin() {
            let source = self.source
            running?.cancel()
            reported = false
            apply(WatchSignIn(source: source))
            running = Task { [weak self] in
                await WatchSignIn.run(source: source) { flow in
                    Task { @MainActor in self?.apply(flow) }
                }
            }
        }

        private func apply(_ flow: WatchSignIn) {
            self.flow = flow
            headingLabel.stringValue = flow.heading
            detailLabel.stringValue = flow.detail
            instructionLabel.stringValue = flow.instruction ?? ""
            instructionLabel.isHidden = flow.instruction == nil
            codeLabel.stringValue = flow.code ?? ""
            codeRow.isHidden = flow.code == nil
            actionButton.title = flow.actionTitle
            actionButton.isEnabled = canAct
            if flow.isFinished {
                spinner.stopAnimation(nil)
            } else {
                spinner.startAnimation(nil)
            }
            if case .granted = flow.step, !reported {
                reported = true
                onFinished()
            }
            sheet.setContentSize(column.fittingSize)
        }

        /// The button has nothing to do until the site has answered with a code, so while the sheet is
        /// still asking it stays titled and inert rather than absent — a control that appears mid-flow
        /// moves everything under it while somebody is reading.
        private var canAct: Bool {
            if case .starting = flow.step { return false }
            return true
        }

        @objc private func actPressed() {
            switch flow.step {
            case .starting:
                return
            case .waiting:
                guard let link = flow.link, let url = URL(string: link) else { return }
                NSWorkspace.shared.open(url)
            case .granted:
                close()
            case .failed:
                begin()
            }
        }

        @objc private func copyCode() {
            guard let code = flow.code else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }

        @objc private func closeSheet() {
            close()
        }

        private func close() {
            sheet.sheetParent?.endSheet(sheet)
        }

        /// A sheet closed on the second step must stop asking the site. The flow polls for as long as
        /// the code lives — half an hour on both — and nothing else will cancel it.
        private func stop() {
            running?.cancel()
            running = nil
        }

        private static func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            return view
        }
    }
#endif
