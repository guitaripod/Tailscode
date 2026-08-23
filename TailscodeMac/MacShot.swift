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
    static var isRequested: Bool { path != nil || treePath != nil }

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

    /// `--tree <path>` — the same window as a text file: every view's real frame, whether it is
    /// hidden, and whether Auto Layout thinks its position is ambiguous.
    ///
    /// A picture answers "does this look right"; it cannot answer "is this label 4pt off its
    /// neighbour" or "which of these two constraints is the one that is not holding". A geometry
    /// dump answers both without a screen, and `hasAmbiguousLayout` is the only way to find an
    /// underconstrained view before a person notices it moving on its own.
    static var treePath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--tree"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// `--tree-constraints` adds the horizontal constraints acting on every stack and every
    /// ambiguous view, which is what tells a missing constraint apart from a losing one.
    static var wantsConstraints: Bool { CommandLine.arguments.contains("--tree-constraints") }

    /// `--open <surface>` — which window to put in front of the picture. The main window is what a
    /// launch already draws; everything else in this app is a sheet, a panel or a popover somebody
    /// has to reach, and a screen nobody can reach is a screen nobody checks.
    static var surface: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func schedule() {
        guard path != nil || treePath != nil else { return }
        Task { @MainActor in
            if let size, let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.setContentSize(size)
            }
            try? await Task.sleep(for: delay)
            if let treePath { dumpTree(to: treePath) }
            if let path { capture(to: path) }
            exit(0)
        }
    }

    private static func dumpTree(to path: String) {
        var lines: [String] = []
        for window in NSApp.windows where window.contentView != nil {
            let frame = window.frame
            lines.append(
                "WINDOW \(type(of: window)) \"\(window.title)\" "
                    + "\(box(frame)) visible=\(window.isVisible)")
            if let root = window.contentView { describe(root, into: &lines, depth: 1, root: root) }
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        do {
            try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            print("TREE \(path) \(lines.count) lines")
        } catch {
            FileHandle.standardError.write(Data("TREE \(error)\n".utf8))
        }
    }

    private static func describe(_ view: NSView, into lines: inout [String], depth: Int, root: NSView) {
        let indent = String(repeating: "  ", count: depth)
        let inRoot = view.convert(view.bounds, to: root)
        var facts = ["\(type(of: view))", box(inRoot)]
        if view.isHidden { facts.append("hidden") }
        if view.alphaValue != 1 { facts.append(String(format: "alpha=%.2f", view.alphaValue)) }
        if view.hasAmbiguousLayout { facts.append("AMBIGUOUS") }
        if view.translatesAutoresizingMaskIntoConstraints, !(view is NSWindow) {
            facts.append("autoresizing")
        }
        if let stack = view as? NSStackView {
            facts.append(
                "stack[axis=\(stack.orientation.rawValue) align=\(stack.alignment.rawValue) "
                    + "dist=\(stack.distribution.rawValue) "
                    + "insets=\(stack.edgeInsets.left)/\(stack.edgeInsets.right) "
                    + "hugH=\(stack.contentHuggingPriority(for: .horizontal).rawValue)]")
        }
        if let text = caption(view) { facts.append("\"\(text)\"") }
        lines.append(indent + facts.joined(separator: " "))
        if wantsConstraints, view is NSStackView || view.hasAmbiguousLayout {
            describeConstraints(on: view, into: &lines, indent: indent)
        }
        for child in view.subviews {
            describe(child, into: &lines, depth: depth + 1, root: root)
        }
    }

    /// Both axes for a view Auto Layout calls ambiguous, and the horizontal one for a stack.
    /// Ambiguity has no axis in `hasAmbiguousLayout`, so dumping one axis answers half the question
    /// and leaves the other half looking like a mystery.
    private static func describeConstraints(on view: NSView, into lines: inout [String], indent: String) {
        for constraint in view.constraintsAffectingLayout(for: .horizontal) {
            lines.append(indent + "  ↔ \(constraint)")
        }
        guard view.hasAmbiguousLayout else { return }
        for constraint in view.constraintsAffectingLayout(for: .vertical) {
            lines.append(indent + "  ↕ \(constraint)")
        }
    }

    private static func caption(_ view: NSView) -> String? {
        let raw: String? =
            switch view {
            case let field as NSTextField: field.stringValue
            case let button as NSButton: button.title
            case let text as NSTextView: text.string
            default: nil
            }
        guard let raw, !raw.isEmpty else { return nil }
        let flat = raw.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    private static func box(_ rect: NSRect) -> String {
        String(
            format: "(%.1f,%.1f %.1f×%.1f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private static func capture(to path: String) {
        let ordered = NSApp.orderedWindows.filter { $0.isVisible && $0.contentView != nil }
        let front =
            surface == nil
            ? NSApp.keyWindow ?? NSApp.mainWindow ?? ordered.first
            : ordered.first(where: { $0 !== NSApp.mainWindow }) ?? ordered.first
        guard let window = front,
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
