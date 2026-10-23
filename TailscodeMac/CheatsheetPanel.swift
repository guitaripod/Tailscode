import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Esc dismisses, matching the key that opened it: the cheatsheet is a glance, not a window to
/// manage.
final class CheatsheetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
