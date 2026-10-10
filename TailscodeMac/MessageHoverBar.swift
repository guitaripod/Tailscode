import AppKit
import CodingAgentKit
import TailscodeCore

/// The verbs of a message, offered to a pointer resting on it: when it was written, Copy, and —
/// on a prompt a server can wind back to — Undo from here.
///
/// A message's verbs used to live on a right-click nobody was told about, so the transcript read
/// as a page that could not be acted on. They float here as a small glass capsule at the message's
/// top trailing corner, over the room the page leaves between one message and the next, for as long
/// as the pointer is on the message or on the capsule itself. The watch is one tracking area on the
/// scroll view, and the message under the pointer is found by where the rows stand rather than by
/// asking every row, so a pointer crossing a long conversation costs a lookup per move.
@MainActor
final class MessageHoverBar: NSResponder {
    /// A message the pointer is on, and the rows it is drawn as, in the canvas's coordinates.
    struct Target: Equatable {
        var messageID: String
        var isPrompt: Bool
        var block: NSRect
    }

    /// A code block the pointer is on: where it stands in the canvas and what it says, so its
    /// language and its Copy can be offered at its corner without the block carrying a header row.
    struct CodeTarget: Equatable {
        var key: String
        var language: String
        var body: String
        var block: NSRect
    }

    var locate: ((NSPoint) -> Target?)?
    var locateCode: ((NSPoint) -> CodeTarget?)?
    /// Whether something floating over the transcript owns the pointer for now, which puts the
    /// capsules away rather than let them show through it.
    var blocked: (() -> Bool)?
    var message: ((String) -> ChatMessage?)?
    var offersUndo: ((String) -> Bool)?
    var undo: ((String) -> Void)?
    var toast: ((String) -> Void)?

    private weak var host: NSView?
    private weak var scrollView: NSScrollView?
    private weak var canvas: NSView?
    private let capsule = BarCapsule()
    private let stack = NSStackView()
    private let stamp = NSTextField(labelWithString: "")
    private var glass: NSView?
    private var shown: Target?
    private var hideWork: DispatchWorkItem?
    private let codeTag = BarCapsule()
    private let codeStack = NSStackView()
    private let codeLabel = NSTextField(labelWithString: "")
    private var codeShown: CodeTarget?
    private var codeHideWork: DispatchWorkItem?

    func install(in host: NSView, over scrollView: NSScrollView, canvas: NSView) {
        self.host = host
        self.scrollView = scrollView
        self.canvas = canvas
        stamp.font = MacTheme.Ramp.font(.panelFootnote)
        stamp.textColor = MacTheme.Color.onGlassSecondary
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: MacTheme.Spacing.s, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: stack, cornerRadius: MacTheme.Radius.control)
        glass.translatesAutoresizingMaskIntoConstraints = false
        capsule.translatesAutoresizingMaskIntoConstraints = true
        capsule.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            glass.topAnchor.constraint(equalTo: capsule.topAnchor),
            glass.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
        ])
        self.glass = glass
        capsule.scrollView = scrollView
        capsule.alphaValue = 0
        capsule.isHidden = true
        capsule.onPointer = { [weak self] inside in
            if inside { self?.cancelHide() } else { self?.refresh() }
        }
        host.addSubview(capsule, positioned: .above, relativeTo: scrollView)
        installCodeTag(in: host, over: scrollView)
        scrollView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { refresh() }
    override func mouseEntered(with event: NSEvent) { refresh() }
    override func mouseExited(with event: NSEvent) { refresh() }

    /// Reads what is under the pointer and shows, moves or lets go of the capsule. Called on every
    /// move and every scroll, and whenever the rows change under a pointer standing still.
    func refresh() {
        guard let host, let window = host.window, let canvas, let scrollView else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if blocked?() == true {
            dismiss()
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        refreshCode(at: location)
        if !capsule.isHidden, capsule.frame.contains(host.convert(location, from: nil)) {
            cancelHide()
            return
        }
        let inClip = scrollView.contentView.convert(location, from: nil)
        guard scrollView.contentView.bounds.contains(inClip),
            let target = locate?(canvas.convert(location, from: nil))
        else {
            scheduleHide()
            return
        }
        cancelHide()
        if target != shown { show(target) }
    }

    /// Takes the capsule down at once — a chat switched, a slot taking the pane.
    func dismiss() {
        cancelHide()
        shown = nil
        capsule.alphaValue = 0
        capsule.isHidden = true
        dismissCode()
    }

    /// The capsule stays the same capsule while the pointer stays on the same message: a message
    /// being written grows under a pointer resting on it, and only the corner it hangs from moves.
    private func show(_ target: Target) {
        guard let host, let canvas, let scrollView, let message = message?(target.messageID)
        else {
            dismiss()
            return
        }
        let firstShow = shown == nil
        let sameMessage =
            shown?.messageID == target.messageID && shown?.isPrompt == target.isPrompt
        shown = target
        if !sameMessage {
            stack.setViews(verbs(for: target, message: message), in: .leading)
            stamp.stringValue = Self.stamp(message.createdAt)
            stamp.toolTip = message.createdAt.formatted(date: .complete, time: .standard)
        }
        capsule.layoutSubtreeIfNeeded()
        let size = capsule.fittingSize
        let block = host.convert(target.block, from: canvas)
        let visible = host.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let top = host.isFlipped ? block.minY : block.maxY
        var origin = NSPoint(
            x: block.maxX - size.width,
            y: host.isFlipped ? top - size.height - 2 : top + 2)
        let ceiling = host.isFlipped
            ? visible.minY + scrollView.contentInsets.top
            : visible.maxY - scrollView.contentInsets.top - size.height
        origin.y = host.isFlipped ? max(origin.y, ceiling) : min(origin.y, ceiling)
        capsule.frame = NSRect(origin: origin, size: size)
        capsule.isHidden = false
        guard firstShow else {
            capsule.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            capsule.animator().alphaValue = 1
        }
    }

    private func verbs(for target: Target, message: ChatMessage) -> [NSView] {
        var views: [NSView] = [stamp]
        let id = target.messageID
        let words = Self.words(of: message)
        if !words.isEmpty {
            views.append(
                Self.button(symbol: "doc.on.doc", tip: Localized.text("Copy")) { [weak self] in
                    RowKit.copyToClipboard(words)
                    self?.toast?(Localized.text("Copied"))
                })
        }
        if target.isPrompt, offersUndo?(id) == true {
            views.append(
                Self.button(symbol: RevertReading.actionSymbol, tip: RevertReading.actionTitle) {
                    [weak self] in self?.undo?(id)
                })
        }
        return views
    }

    static func words(of message: ChatMessage) -> String { MessageHover.words(of: message) }

    static func stamp(_ date: Date, now: Date = Date()) -> String {
        MessageHover.stamp(date, now: now)
    }

    private static func button(symbol: String, tip: String, action: @escaping () -> Void)
        -> NSButton
    {
        let button = RowKit.ActionButton(title: "", action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: (12 * MacTheme.UIScale.factor).rounded(), weight: .medium))
        button.imagePosition = .imageOnly
        button.contentTintColor = MacTheme.Color.onGlass
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        let side = (22 * MacTheme.UIScale.factor).rounded()
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        return button
    }

    /// Crossing the gap between a message and its capsule is not leaving the message.
    private func scheduleHide() {
        guard !capsule.isHidden, hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            self.shown = nil
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.15
                    self.capsule.animator().alphaValue = 0
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.shown == nil else { return }
                        self.capsule.isHidden = true
                    }
                })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    /// Whether the capsule is up, and for which message — for a harness.
    var showing: Target? { capsule.isHidden ? nil : shown }

    private func installCodeTag(in host: NSView, over scrollView: NSScrollView) {
        codeLabel.font = MacTheme.Ramp.font(.codeLabel)
        codeLabel.textColor = MacTheme.Color.onGlassSecondary
        codeStack.orientation = .horizontal
        codeStack.alignment = .centerY
        codeStack.spacing = 2
        codeStack.edgeInsets = NSEdgeInsets(top: 1, left: MacTheme.Spacing.s, bottom: 1, right: 2)
        codeStack.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: codeStack, cornerRadius: MacTheme.Radius.control)
        glass.translatesAutoresizingMaskIntoConstraints = false
        codeTag.translatesAutoresizingMaskIntoConstraints = true
        codeTag.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: codeTag.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: codeTag.trailingAnchor),
            glass.topAnchor.constraint(equalTo: codeTag.topAnchor),
            glass.bottomAnchor.constraint(equalTo: codeTag.bottomAnchor),
        ])
        codeTag.scrollView = scrollView
        codeTag.alphaValue = 0
        codeTag.isHidden = true
        codeTag.onPointer = { [weak self] inside in
            if inside { self?.cancelCodeHide() } else { self?.refresh() }
        }
        host.addSubview(codeTag, positioned: .above, relativeTo: scrollView)
    }

    /// The block under the pointer gets its language and its Copy at its top corner; the pointer
    /// leaving the block lets them go after the same beat the message capsule takes.
    private func refreshCode(at location: NSPoint) {
        guard let host, let canvas, let scrollView else { return }
        if !codeTag.isHidden, codeTag.frame.contains(host.convert(location, from: nil)) {
            cancelCodeHide()
            return
        }
        let inClip = scrollView.contentView.convert(location, from: nil)
        guard scrollView.contentView.bounds.contains(inClip),
            let target = locateCode?(canvas.convert(location, from: nil))
        else {
            scheduleCodeHide()
            return
        }
        cancelCodeHide()
        if target != codeShown { showCode(target) }
    }

    private func showCode(_ target: CodeTarget) {
        guard let host, let canvas else { return }
        let firstShow = codeShown == nil
        let sameBlock = codeShown?.key == target.key && codeShown?.body == target.body
        codeShown = target
        if !sameBlock {
            codeLabel.stringValue = target.language
            let body = target.body
            codeStack.setViews(
                [
                    codeLabel,
                    Self.button(symbol: "doc.on.doc", tip: Localized.text("Copy code")) { [weak self] in
                        RowKit.copyToClipboard(body)
                        self?.toast?(Localized.text("Code copied"))
                    },
                ], in: .leading)
        }
        codeTag.layoutSubtreeIfNeeded()
        let size = codeTag.fittingSize
        let block = host.convert(target.block, from: canvas)
        let inset: CGFloat = 4
        let origin = NSPoint(
            x: block.maxX - size.width - inset,
            y: host.isFlipped ? block.minY + inset : block.maxY - size.height - inset)
        codeTag.frame = NSRect(origin: origin, size: size)
        codeTag.isHidden = false
        guard firstShow else {
            codeTag.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            codeTag.animator().alphaValue = 1
        }
    }

    private func dismissCode() {
        cancelCodeHide()
        codeShown = nil
        codeTag.alphaValue = 0
        codeTag.isHidden = true
    }

    private func scheduleCodeHide() {
        guard !codeTag.isHidden, codeHideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.codeHideWork = nil
            self.codeShown = nil
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.15
                    self.codeTag.animator().alphaValue = 0
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.codeShown == nil else { return }
                        self.codeTag.isHidden = true
                    }
                })
        }
        codeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelCodeHide() {
        codeHideWork?.cancel()
        codeHideWork = nil
    }

    /// Whether the code tag is up, and for which block — for a harness.
    var showingCode: CodeTarget? { codeTag.isHidden ? nil : codeShown }
}

/// The capsule's own frame: it says when the pointer is on it, so the message it belongs to keeps
/// it up, and it hands a scroll straight to the transcript under it rather than swallowing it.
@MainActor
private final class BarCapsule: NSView {
    weak var scrollView: NSScrollView?
    var onPointer: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }

    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
