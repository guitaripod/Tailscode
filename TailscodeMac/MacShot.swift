import AppKit
import TailscodeCore

/// `TailscodeMac --shot <path> [--shot-delay <seconds>]` — the window, as a PNG, from a Mac
/// nobody is sitting at.
///
/// The Linux client has a harness that renders it on a display of its own; a Mac reached over
/// ssh has a window server but frequently no framebuffer to capture, so `screencapture` answers
/// "could not create image from display" and the app becomes the one thing in this repo that
/// cannot be looked at. The window can always draw itself, though: `cacheDisplay` renders the
/// view tree into a bitmap whether or not any of it ever reached a screen.
///
/// What it cannot show is the part of the Mac's design that is not the app's to draw: a glass
/// material samples what is behind the window, and behind an offscreen window there is nothing,
/// so chrome that would be tinted by the transcript comes back flat. It is a picture of the
/// layout and the palette, not a substitute for a real screen.
@MainActor
enum MacShot {
    static var isRequested: Bool { path != nil }

    static var path: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--shot"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// How long the window gets to fill itself before the picture is taken. A listing crosses a
    /// tailnet, so the default is generous; a screen with nothing to fetch can ask for less.
    static var delay: Duration {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--shot-delay"), index + 1 < arguments.count,
            let seconds = Double(arguments[index + 1])
        else { return .seconds(6) }
        return .seconds(seconds)
    }

    /// The size to draw at. A window nobody has ever resized opens at its smallest useful size,
    /// which is not the shape anyone actually works in.
    static var size: NSSize? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--shot-size"), index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1])
        else { return nil }
        return NSSize(width: width, height: height)
    }

    static func schedule() {
        guard let path else { return }
        Task { @MainActor in
            if let size, let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.setContentSize(size)
            }
            try? await Task.sleep(for: delay)
            capture(to: path)
            exit(0)
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
            let view = window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            FileHandle.standardError.write(Data("SHOT no window to draw\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("SHOT could not encode\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("SHOT \(path) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
        } catch {
            FileHandle.standardError.write(Data("SHOT \(error)\n".utf8))
        }
    }
}
