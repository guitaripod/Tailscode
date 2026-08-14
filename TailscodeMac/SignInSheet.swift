import AppKit
import CodingAgentKit
import TailscodeCore

/// A signed-out Claude is a state, not a reply — and signing back in is split across two
/// machines: the server hands over the URL, this Mac opens it in the browser and returns the
/// code. Never "open a terminal".
@MainActor
final class SignInSheet {
    private static var active: [SignInSheet] = []

    private let sheet: NSWindow
    private let backend: any AuthenticatingBackend
    private let onSignedIn: @MainActor () -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let linkColumn = NSStackView()
    private let codeField = NSTextField()

    static func present(
        on host: NSWindow, serverName: String, backend: any AuthenticatingBackend,
        onSignedIn: @escaping @MainActor () -> Void
    ) {
        let sheet = SignInSheet(serverName: serverName, backend: backend, onSignedIn: onSignedIn)
        active.append(sheet)
        host.beginSheet(sheet.sheet) { _ in
            active.removeAll { $0 === sheet }
        }
        sheet.begin(serverName: serverName)
    }

    private init(
        serverName: String, backend: any AuthenticatingBackend,
        onSignedIn: @escaping @MainActor () -> Void
    ) {
        self.backend = backend
        self.onSignedIn = onSignedIn
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("Sign in Claude on %@", serverName)

        let title = NSTextField(
            labelWithString: Localized.text("Sign in Claude on %@", serverName))
        title.font = MacTheme.Ramp.font(.cardTitle)

        status.stringValue = Localized.text("Asking %@ for a sign-in link…", serverName)
        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.secondaryLabel

        linkColumn.orientation = .vertical
        linkColumn.alignment = .leading
        linkColumn.spacing = MacTheme.Spacing.s

        codeField.placeholderString = Localized.text("Paste the code the browser shows")
        codeField.font = MacTheme.Ramp.font(.code)
        codeField.isEnabled = false
        codeField.target = self
        codeField.action = #selector(submitCode)

        let cancel = NSButton(
            title: Localized.text("Cancel"), target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1B}"
        let submit = NSButton(
            title: Localized.text("Submit code"), target: self, action: #selector(submitCode))
        submit.keyEquivalent = "\r"
        let buttons = NSStackView(views: [SignInSheet.spacer(), cancel, submit])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s

        let column = FillingStack(views: [title, status, linkColumn, codeField, buttons])
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = column
        column.widthAnchor.constraint(equalToConstant: 520).isActive = true
        sheet.setContentSize(column.fittingSize)
    }

    private func begin(serverName: String) {
        Task { [weak self] in
            do {
                guard let backend = self?.backend else { return }
                let auth = try await backend.beginSignIn()
                guard let self else { return }
                guard let url = auth.pending?.url else {
                    self.setStatus(
                        Localized.text(
                            "%@ did not hand over a link — is the bridge up to date?", serverName))
                    return
                }
                self.setStatus(
                    Localized.text("Open the link, sign in, then paste the code back here."))
                self.showLink(url)
                self.codeField.isEnabled = true
                self.sheet.makeFirstResponder(self.codeField)
            } catch {
                self?.setStatus(Localized.text("Could not start a sign-in: %@", "\(error)"))
            }
        }
    }

    private func showLink(_ url: String) {
        let open = NSButton(
            title: Localized.text("Open sign-in link"), target: self, action: #selector(openLink))
        open.bezelStyle = .rounded
        open.identifier = NSUserInterfaceItemIdentifier(url)
        let address = NSTextField(wrappingLabelWithString: url)
        address.font = MacTheme.Ramp.font(.toolOutput)
        address.textColor = MacTheme.Color.secondaryLabel
        address.isSelectable = true
        linkColumn.addArrangedSubview(open)
        linkColumn.addArrangedSubview(address)
        if let column = sheet.contentView { sheet.setContentSize(column.fittingSize) }
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func submitCode() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        setStatus(Localized.text("Submitting the code…"))
        Task { [weak self] in
            do {
                guard let backend = self?.backend else { return }
                let auth = try await backend.submitSignInCode(code)
                guard let self else { return }
                if auth.loggedIn {
                    self.onSignedIn()
                    self.close()
                } else {
                    self.setStatus(
                        Localized.text("The server took the code but still reports signed out."))
                }
            } catch {
                self?.setStatus(Localized.text("The code was refused: %@", "\(error)"))
            }
        }
    }

    /// Closing an unfinished sign-in tells the server to stop waiting for a code that will never
    /// come, so the next attempt starts clean.
    @objc private func cancelSheet() {
        let backend = backend
        Task.detached { try? await backend.cancelSignIn() }
        close()
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
    }

    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
}
