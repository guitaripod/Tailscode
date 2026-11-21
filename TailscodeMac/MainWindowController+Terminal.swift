import AppKit
import CodingAgentKit
import TailscodeCore

extension MainWindowController {
    /// A split whose chat starts in the folder the terminal is standing in, on the server that
    /// holds the shell: the folder is that machine's, so that is where the chat can start in it.
    /// The new half is made first, so a server slow to answer leaves the usual chooser in it
    /// rather than nothing.
    func splitAtTerminal(axis: SplitAxis) {
        switch TerminalSplit.plan(
            directory: terminalPane.standingDirectory(), server: terminalPane.standingServer)
        {
        case .refused(let refusal):
            toast(refusal.words)
        case .open(let profileID, let folder):
            guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID }) else {
                toast(Localized.text("That server is not configured."))
                return
            }
            focused = .transcript
            splitPanes.splitActive(axis: axis)
            createChat(on: profile, directory: folder)
        }
    }
}

#if DEBUG
    extension MainWindowController {
        /// `term=show` opens the pane and gives it the keyboard, `term=type=<words>` types them,
        /// `term=enter` presses Return, and `term=read` says what the screen and the caption hold.
        func driveTerminal(_ argument: String) -> String {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts.first ?? "" {
            case "show":
                setPane(.terminal, shown: true)
                _ = focus(.terminal)
                return "TERM shown focus=\(terminalHasFocus)"
            case "type":
                terminalPane.driveType(parts.count > 1 ? parts[1] : "")
                return "TERM typed"
            case "enter":
                terminalPane.driveType("\r")
                return "TERM enter"
            default:
                let lines = terminalPane.screenText.split(separator: "\n").suffix(6).joined(separator: " | ")
                return "TERM caption=\(terminalPane.captionText) screen=\(lines) view: \(terminalPane.diagnostics)"
            }
        }
    }
#endif
