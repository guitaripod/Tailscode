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
    /// With `--open`, it is the surface that is drawn at this size, once it is up — which is how a
    /// window is checked at its narrowest.
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
    /// ambiguous view, which is what tells a missing constraint apart from a losing one, and the
    /// narrowest width each view will allow — the number that says which one holds a window wide.
    static var wantsConstraints: Bool { CommandLine.arguments.contains("--tree-constraints") }

    /// `--open <surface>` — which window to put in front of the picture. The main window is what a
    /// launch already draws; everything else in this app is a sheet, a panel or a popover somebody
    /// has to reach, and a screen nobody can reach is a screen nobody checks. A popover's window is
    /// a child the ordered list leaves out, so the newest window outside that list is the one drawn.
    static var surface: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Whether `--shot-size` is a surface's size, drawn once it is up. A staged transcript is the
    /// main window itself, which has to be its final size before anything is staged into it, or
    /// what floats over it is placed for a window that is gone by the time it is drawn.
    private static var sizesASurface: Bool {
        guard let surface else { return false }
        return !surface.hasPrefix("stage:")
    }

    static func schedule() {
        guard path != nil || treePath != nil else { return }
        Task { @MainActor in
            if let size, !sizesASurface, let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.setContentSize(size)
            }
            try? await Task.sleep(for: delay)
            if let size, sizesASurface, let window = surfaceWindow() {
                window.setContentSize(size)
                window.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(500))
            }
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
        let natural = view.intrinsicContentSize.width
        if natural != NSView.noIntrinsicMetric, natural > (wantsConstraints ? 200 : 1000) {
            let resists = view.contentCompressionResistancePriority(for: .horizontal).rawValue
            facts.append(String(format: "natural=%.0f resists=%.0f", natural, resists))
        }
        if view.translatesAutoresizingMaskIntoConstraints {
            facts.append("autoresizing")
        }
        if wantsConstraints, !view.translatesAutoresizingMaskIntoConstraints {
            facts.append(String(format: "fits=%.0f", view.fittingSize.width))
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

    /// The window `--open` put in front: a popover's child window, else the frontmost one that is
    /// not the chat window. A surface that opens as a window becomes AppKit's main window itself,
    /// so the chat window is told apart by its name rather than by `mainWindow`.
    private static func surfaceWindow() -> NSWindow? {
        let ordered = NSApp.orderedWindows.filter { $0.isVisible && $0.contentView != nil }
        let floating = NSApp.windows.filter {
            $0.isVisible && $0.contentView != nil && !ordered.contains($0)
        }
        return floating.last ?? ordered.first(where: { $0.frameAutosaveName != "TailscodeMain" })
            ?? ordered.first
    }

    /// `--shot-scale <n>` — the pixels per point the picture is drawn at. A Mac with a 1× display
    /// has nothing sharper to give a window, and a master for a page that is looked at on 2×
    /// screens has to be drawn at 2× regardless, which the bitmap can do whatever the display is.
    static var scale: CGFloat {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--shot-scale"), index + 1 < arguments.count,
            let factor = Double(arguments[index + 1]), factor >= 1
        else { return 1 }
        return CGFloat(factor)
    }

    /// `--shot-chrome` — draw the window's frame view rather than its content view, so the
    /// title bar and the toolbar's items come out with the picture instead of being left to a
    /// real screen capture.
    static var wantsChrome: Bool { CommandLine.arguments.contains("--shot-chrome") }

    private static func bitmap(for view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        return rep
    }

    /// A toolbar is drawn by the window server's own machinery, which a bitmap of the view tree
    /// never reaches: its items come out as empty glass, a segmented control's selected thumb
    /// takes its label with it, and a pill is cut to the width it had before it knew its words.
    /// The items are ordinary views, so for a picture they are taken out of the toolbar and laid
    /// along the title bar where the toolbar would have put them: leading, centred, trailing.
    private static func standInForGlass(in window: NSWindow) {
        guard let toolbar = window.toolbar, toolbar.identifier == "studio.toolbar",
            let frame = window.contentView?.superview
        else { return }
        let views = toolbar.items.compactMap(\.view)
        toolbar.isVisible = false
        let bar: CGFloat = 52
        let edge: CGFloat = 16
        var leading = 96.0
        var trailing = frame.bounds.width - edge
        for view in views.reversed() {
            let leads = view is NSSegmentedControl
            if let button = view as? NSButton {
                button.attributedTitle = NSAttributedString(
                    string: button.title,
                    attributes: [.font: button.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            }
            let view: NSView = (view as? NSSegmentedControl).map(SegmentsStandIn.init) ?? view
            view.removeFromSuperview()
            view.invalidateIntrinsicContentSize()
            let natural = view.intrinsicContentSize
            let size = NSSize(
                width: natural.width == NSView.noIntrinsicMetric ? view.frame.width : natural.width,
                height: natural.height == NSView.noIntrinsicMetric ? view.frame.height : natural.height)
            let y = frame.isFlipped ? (bar - size.height) / 2 : frame.bounds.height - bar / 2 - size.height / 2
            let x: CGFloat
            if view is StudioMachinePill {
                x = (frame.bounds.width - size.width) / 2
            } else if leads {
                x = leading
                leading += size.width + 12
            } else {
                trailing -= size.width
                x = trailing
                trailing -= 8
            }
            view.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            frame.addSubview(view)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            if view is StudioMachinePill {
                loosenLabels(in: view)
                view.setFrameSize(NSSize(width: view.frame.width + 12, height: view.frame.height))
                view.setFrameOrigin(NSPoint(x: view.frame.minX - 6, y: view.frame.minY))
            }
        }
    }

    /// A label measured for one font and drawn in another is cut with an ellipsis a few points
    /// short of its words; in a picture the words matter more than the cut.
    private static func loosenLabels(in view: NSView) {
        for case let field as NSTextField in view.subviews {
            field.lineBreakMode = .byClipping
            field.setFrameSize(NSSize(width: field.frame.width + 8, height: field.frame.height))
        }
    }

    private static func capture(to path: String) {
        let ordered = NSApp.orderedWindows.filter { $0.isVisible && $0.contentView != nil }
        let front =
            surface == nil
            ? NSApp.keyWindow ?? NSApp.mainWindow ?? ordered.first
            : surfaceWindow()
        guard let window = front,
            let content = window.contentView
        else {
            FileHandle.standardError.write(Data("SHOT no window to draw\n".utf8))
            return
        }
        if wantsChrome { standInForGlass(in: window) }
        let view = wantsChrome ? content.superview ?? content : content
        guard let bitmap = bitmap(for: view, scale: scale) else {
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
            print("SHOT \(path) \(Int(view.bounds.width))×\(Int(view.bounds.height)) @\(Int(scale))x")
        } catch {
            FileHandle.standardError.write(Data("SHOT \(error)\n".utf8))
        }
    }
}

/// What a toolbar's segmented control looks like once its material is gone: a track, a thumb under
/// the chosen segment and the labels, drawn from the control's own titles and selection, so the
/// picture says which lane is open.
@MainActor
private final class SegmentsStandIn: NSView {
    private let titles: [String]
    private let selected: Int

    init(_ control: NSSegmentedControl) {
        titles = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        selected = control.selectedSegment
        super.init(frame: NSRect(x: 0, y: 0, width: control.frame.width, height: control.frame.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: 4)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let width = (track.width - 6) / CGFloat(max(1, titles.count))
        for (index, title) in titles.enumerated() {
            let cell = NSRect(x: track.minX + 3 + width * CGFloat(index), y: track.minY + 3, width: width, height: track.height - 6)
            if index == selected {
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: index == selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2),
                withAttributes: attributes)
        }
    }
}
