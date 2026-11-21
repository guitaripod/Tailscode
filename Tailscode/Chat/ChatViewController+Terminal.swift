import CodingAgentKit
import TailscodeCore
import UIKit

extension ChatViewController {
    /// Whether this chat's server could hold a shell: the menu offers a terminal only then. A
    /// bridge too old for one still gets the item, because the screen says what would change it.
    var offersTerminal: Bool {
        viewModel.backend is any TerminalHostingBackend
    }

    /// The shell on this chat's machine, in this chat's folder, pushed like any other screen.
    func presentTerminal() {
        Theme.Haptics.tap()
        let session = TerminalDesk.session(
            profileID: viewModel.contextID,
            server: viewModel.serverName.isEmpty ? String(localized: "this server") : viewModel.serverName,
            backend: viewModel.backend, directory: viewModel.session.directory, sessionID: viewModel.session.id)
        navigationController?.pushViewController(TerminalViewController(session: session), animated: true)
    }

    #if DEBUG
        /// `TAILSCODE_OPEN_TERMINAL=<seconds>` opens the terminal once the chat stands,
        /// `TAILSCODE_TERMINAL_TYPE` types into it a line at a time (`\n` between lines), and
        /// `TAILSCODE_TERMINAL_KEYS=0` puts the keyboard away afterwards, so a picture can be
        /// taken of a shell that has been used.
        func stageTerminalIfAsked() {
            let environment = ProcessInfo.processInfo.environment
            guard let wait = environment["TAILSCODE_OPEN_TERMINAL"] else { return }
            let lines = (environment["TAILSCODE_TERMINAL_TYPE"] ?? "").components(separatedBy: "\\n")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(wait) ?? 3))
                guard let self else { return }
                self.presentTerminal()
                try? await Task.sleep(for: .seconds(2))
                guard let screen = self.navigationController?.topViewController as? TerminalViewController else { return }
                for line in lines where !line.isEmpty {
                    screen.stage(line + "\r")
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if environment["TAILSCODE_TERMINAL_KEYS"] == "0" { screen.view.endEditing(true) }
            }
        }
    #endif
}
