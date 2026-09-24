import AppKit

extension NSWindow {
    /// Keeps where and how large this window was left under `name`, and puts it back there when a
    /// window of that name was placed before. The answer says which, so a window's first opening
    /// can still be sized by whoever built it — and every opening after that is the person's own.
    @discardableResult
    func rememberFrame(as name: String) -> Bool {
        let restored = setFrameUsingName(name)
        setFrameAutosaveName(name)
        return restored
    }
}
