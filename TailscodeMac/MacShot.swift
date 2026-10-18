import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

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

#if DEBUG
    /// `TailscodeMac --shot-live <path>` — the app's real compositing, photographed from inside.
    ///
    /// `--shot` draws a view tree into a bitmap, and a glass material is not part of a view tree: it is
    /// the window server sampling what is behind the window, so offscreen it comes back flat. This verb
    /// instead puts the windows on a real display, with a backdrop window of its own behind them, and
    /// asks the window server for the picture of that display. A process may always read its own
    /// windows, so no screen-recording right is involved — and because the display is a virtual one the
    /// helper script holds open (`scripts/market-compose-mac.py`), nothing lands on anybody's desktop
    /// and nothing of anybody's desktop can show through a material.
    ///
    /// - `TAILSCODE_LIVE_SCREEN` — the display's name (default `Tailscode Panels`)
    /// - `TAILSCODE_LIVE_BACKDROP` — a PNG drawn behind everything, the whole display
    /// - `TAILSCODE_LIVE_WINDOW` — `x,y,w,h` in points from the display's top left: where the chat
    ///   window sits (default: centred at 1200×760)
    /// - `TAILSCODE_LIVE_SURFACE` — the same, for any other window that opens (default: centred)
    /// - `TAILSCODE_LIVE_HIDE_MAIN=1` — the chat window is put away just before the picture, which is how
    ///   a panel that floats over other programs is shown over a backdrop that stands in for one
    @MainActor
    enum LiveShot {
        static var path: String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--shot-live"), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        /// Whether a launch that photographs itself keeps away from `service`: everything that signs in
        /// to, or asks, an Apple service is the person's own account speaking, and a picture does not
        /// need it. Says so on stdout each time it holds one back.
        static func holdsBack(_ service: String) -> Bool {
            guard path != nil else { return false }
            print("LIVESHOT held back \(service)")
            return true
        }

        private static let environment = ProcessInfo.processInfo.environment
        private static var backdrop: NSWindow?
        private static var placed = Set<ObjectIdentifier>()

        static func prepare() {
            guard path != nil else { return }
            lendKeyAppearance()
        }

        static func install() {
            guard let path else { return }
            Task { @MainActor in
                let deadline = ContinuousClock.now.advanced(by: MacShot.delay)
                while ContinuousClock.now < deadline {
                    arrange()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                arrange()
                if environment["TAILSCODE_LIVE_HIDE_MAIN"] == "1" { main?.alphaValue = 0 }
                try? await Task.sleep(for: .milliseconds(900))
                capture(to: path)
                exit(0)
            }
        }

        private static var screen: NSScreen? {
            let name = environment["TAILSCODE_LIVE_SCREEN"] ?? "Tailscode Panels"
            return NSScreen.screens.first { $0.localizedName == name }
        }

        private static var main: NSWindow? {
            NSApp.windows.first { $0.frameAutosaveName == "TailscodeMain" && $0.contentView != nil }
        }

        /// A window that was never given the keyboard draws its inactive face: grey traffic lights, a
        /// dimmed title. Taking the keyboard would take it from whoever is typing, so the windows that
        /// are put on the display are only *reported* as key, main and visible, which is all their
        /// drawing asks.
        private static func lendKeyAppearance() {
            let pairs: [(AnyClass, Selector, Selector)] = [
                (NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(NSWindow.liveShotIsKey)),
                (NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(NSWindow.liveShotIsMain)),
                (
                    NSWindow.self, #selector(getter: NSWindow.occlusionState),
                    #selector(NSWindow.liveShotOcclusion)
                ),
                (NSApplication.self, #selector(getter: NSApplication.isActive),
                    #selector(NSApplication.liveShotIsActive)),
            ]
            for (type, original, replacement) in pairs {
                guard let a = class_getInstanceMethod(type, original),
                    let b = class_getInstanceMethod(type, replacement)
                else { continue }
                method_exchangeImplementations(a, b)
            }
        }

        static func lends(to window: NSWindow) -> Bool {
            window !== backdrop && window.isVisible
                && (window.styleMask.contains(.titled) || window is NSPanel)
        }

        private static func rect(_ key: String, on screen: NSScreen, fallback: CGSize) -> NSRect {
            let parts = (environment[key] ?? "").split(separator: ",").compactMap { Double($0) }
            let frame = screen.frame
            guard parts.count == 4 else {
                return NSRect(
                    x: frame.midX - fallback.width / 2, y: frame.midY - fallback.height / 2,
                    width: fallback.width, height: fallback.height)
            }
            return NSRect(
                x: frame.minX + parts[0], y: frame.maxY - parts[1] - parts[3], width: parts[2],
                height: parts[3])
        }

        private static func arrange() {
            guard let screen else { return }
            seatBackdrop(on: screen)
            for window in NSApp.windows where window !== backdrop && window.isVisible {
                (window as? NSPanel)?.hidesOnDeactivate = false
                guard window.parent == nil, window.contentView != nil,
                    window.styleMask.contains(.titled)
                else { continue }
                if window === main {
                    place(
                        window, in: rect("TAILSCODE_LIVE_WINDOW", on: screen,
                            fallback: CGSize(width: 1200, height: 760)), key: true)
                } else if window.screen != screen || environment["TAILSCODE_LIVE_SURFACE"] != nil {
                    let fallback = window.frame.size
                    place(
                        window, in: rect("TAILSCODE_LIVE_SURFACE", on: screen, fallback: fallback),
                        key: false)
                }
            }
        }

        private static func place(_ window: NSWindow, in frame: NSRect, key: Bool) {
            if window.frame != frame { window.setFrame(frame, display: true) }
            if placed.insert(ObjectIdentifier(window)).inserted {
                if key { window.makeKeyAndOrderFront(nil) }
                let redraw = NSSelectorFromString("_windowChangedKeyState")
                if window.responds(to: redraw) { window.perform(redraw) }
                window.contentView?.superview?.needsDisplay = true
            }
        }

        private static func seatBackdrop(on screen: NSScreen) {
            guard backdrop == nil else { return }
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false,
                screen: screen)
            window.level = NSWindow.Level(rawValue: -1000)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
            let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.imageScaling = .scaleAxesIndependently
            if let file = environment["TAILSCODE_LIVE_BACKDROP"] {
                view.image = NSImage(contentsOfFile: file)
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            backdrop = window
        }

        private typealias WindowListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) ->
            Unmanaged<CGImage>?

        /// `CGWindowListCreateImage` is withdrawn from the SDK and still answers at run time; a process
        /// is always allowed its own windows, which is the whole of what this reads.
        private static func windowListImage(of bounds: CGRect) -> CGImage? {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
            else { return nil }
            let call = unsafeBitCast(symbol, to: WindowListImage.self)
            let onScreenOnly: UInt32 = 1
            let bestResolution: UInt32 = 1 << 3
            return call(bounds, onScreenOnly, 0, bestResolution)?.takeRetainedValue()
        }

        static func snap(to path: String) { capture(to: path) }

        private static func capture(to path: String) {
            guard let screen,
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else {
                FileHandle.standardError.write(Data("LIVESHOT no such display\n".utf8))
                return
            }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard let image = windowListImage(of: bounds),
                let destination = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else {
                FileHandle.standardError.write(Data("LIVESHOT could not read the display\n".utf8))
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                FileHandle.standardError.write(Data("LIVESHOT could not encode\n".utf8))
                return
            }
            print("LIVESHOT \(path) \(image.width)×\(image.height)")
        }
    }

    extension NSWindow {
        @objc fileprivate func liveShotIsKey() -> Bool {
            LiveShot.lends(to: self) || liveShotIsKey()
        }

        @objc fileprivate func liveShotIsMain() -> Bool {
            LiveShot.lends(to: self) || liveShotIsMain()
        }

        /// A window on the virtual display is reported covered while the real display sleeps, and a
        /// head that draws only for a window somebody can see would never draw: what is drawn on the
        /// virtual display is what is being photographed, so it is what is visible.
        @objc fileprivate func liveShotOcclusion() -> NSWindow.OcclusionState {
            LiveShot.lends(to: self) ? .visible : liveShotOcclusion()
        }
    }

    extension NSApplication {
        @objc fileprivate func liveShotIsActive() -> Bool { true }
    }
#endif
