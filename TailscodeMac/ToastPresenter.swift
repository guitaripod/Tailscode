import AppKit
import TailscodeCore

/// A floating confirmation — the answer to "did my click do anything". A glass capsule
/// bottom-center over the transcript, above the composer so glass never stacks on glass. Toasts
/// queue: each one gets its own dwell, because two at once is a pile nobody reads and a dropped one
/// is a confirmation that lied.
@MainActor
final class ToastPresenter {
    /// Where a toast lands, resolved per show: the transcript view and the top of the floating
    /// composer layer it must stay above. Late resolution, because the window outlives layouts.
    private let anchor: () -> (host: NSView, above: NSLayoutYAxisAnchor)?
    private var queue: [(text: String, key: String?)] = []
    private var draining = false
    /// The capsule on screen, kept so a keyed toast can rewrite it in place and push its dwell
    /// out. `generation` tells the dismissal that was scheduled for it whether it is still the
    /// latest word.
    private var showing: Capsule?
    private var generations = 0

    /// One capsule on screen. The label's width is a constraint of its own, because a wrapping
    /// label has no width unless it is given one and the glass around it takes its size from it.
    private struct Capsule {
        let label: NSTextField
        let glass: NSView
        let width: NSLayoutConstraint
        let key: String?
        var generation: Int
    }

    init(anchor: @escaping () -> (host: NSView, above: NSLayoutYAxisAnchor)?) {
        self.anchor = anchor
    }

    func show(_ text: String) {
        show(text, replacing: nil)
    }

    /// A keyed toast is one voice that keeps talking rather than a queue of them: it takes over
    /// the capsule already showing the same key, and drops any of its own still waiting, so a
    /// control turned five notches says where it landed rather than reciting every stop.
    func show(_ text: String, replacing key: String?) {
        if let key {
            queue.removeAll { $0.key == key }
            if var current = showing, current.key == key {
                generations += 1
                current.generation = generations
                current.label.stringValue = text
                if let host = current.glass.superview {
                    current.width.constant = Self.width(of: current.label, in: host)
                }
                showing = current
                announce(text, from: current.glass)
                scheduleDismissal(generation: current.generation, text: text)
                return
            }
        }
        queue.append((text, key))
        drain()
    }

    /// The capsule is seen and never focused, so VoiceOver is told the sentence outright — a
    /// "Copied" or a reason something could not happen is the whole of what the action said back.
    private func announce(_ text: String, from host: NSView) {
        NSAccessibility.post(
            element: host.window ?? host, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    /// A pane whose view has not loaded yet has no anchor to hang a capsule on, and what is queued
    /// waits for the next one rather than being thrown away — the confirmations this presenter
    /// carries are sentences, so the capsule wraps rather than cutting one off mid-word.
    private func drain() {
        guard !draining, !queue.isEmpty else { return }
        guard let (host, above) = anchor() else { return }
        let (text, key) = queue.removeFirst()
        draining = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.alignment = .center
        label.isSelectable = false
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        let labelWidth = label.widthAnchor.constraint(
            equalToConstant: Self.width(of: label, in: host))
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            labelWidth,
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -Self.inset),
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -8),
        ])
        padded.layoutSubtreeIfNeeded()
        let glass = MacTheme.glass(around: padded, cornerRadius: padded.fittingSize.height / 2)
        host.addSubview(glass)
        announce(text, from: host)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: above, constant: -MacTheme.Spacing.m),
            glass.widthAnchor.constraint(
                lessThanOrEqualTo: host.widthAnchor, constant: -2 * MacTheme.Spacing.xl),
        ])

        if MotionBudget.animationAllowed {
            glass.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                glass.animator().alphaValue = 1
            }
        }
        generations += 1
        showing = Capsule(
            label: label, glass: glass, width: labelWidth, key: key, generation: generations)
        scheduleDismissal(generation: generations, text: text)
    }

    /// How wide the sentence wants to be: its one-line width, up to what the pane can hold, past
    /// which the label wraps. Measured rather than left to Auto Layout, which gives a wrapping label
    /// no width at all and leaves the capsule a blank pill.
    static func width(of label: NSTextField, in host: NSView) -> CGFloat {
        let available = host.bounds.width > 0 ? host.bounds.width : 600
        let ceiling = max(160, available - 2 * MacTheme.Spacing.xl - 2 * inset)
        label.preferredMaxLayoutWidth = ceiling
        let room = NSRect(x: 0, y: 0, width: ceiling, height: .greatestFiniteMagnitude)
        let wanted = label.cell?.cellSize(forBounds: room).width ?? ceiling
        return min(ceiling, ceil(wanted) + 1)
    }

    private static let inset: CGFloat = 14

    private func scheduleDismissal(generation: Int, text: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwell(text)))
            guard let self, let current = self.showing, current.generation == generation else {
                return
            }
            let glass = current.glass
            self.showing = nil
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                glass.animator().alphaValue = 0
            }
            glass.removeFromSuperview()
            self.draining = false
            self.drain()
        }
    }

    /// How long a capsule stands: long enough to read what it says. Two seconds answers "did my
    /// click do anything", but some of what arrives here is a sentence a server wrote explaining
    /// why it refused something, and a reason that vanished mid-word explained nothing.
    private static func dwell(_ text: String) -> TimeInterval {
        min(6, max(2, Double(text.count) / 22))
    }
}
