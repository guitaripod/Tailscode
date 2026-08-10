import AppKit
import TailscodeCore

/// A two-second floating confirmation — the answer to "did my click do anything". A glass
/// capsule bottom-center over the transcript, above the composer so glass never stacks on glass.
/// Toasts queue: each one gets its two seconds, because two at once is a pile nobody reads and a
/// dropped one is a confirmation that lied.
@MainActor
final class ToastPresenter {
    /// Where a toast lands, resolved per show: the transcript view and the top of the floating
    /// composer layer it must stay above. Late resolution, because the window outlives layouts.
    private let anchor: () -> (host: NSView, above: NSLayoutYAxisAnchor)?
    private var queue: [String] = []
    private var draining = false

    init(anchor: @escaping () -> (host: NSView, above: NSLayoutYAxisAnchor)?) {
        self.anchor = anchor
    }

    func show(_ text: String) {
        queue.append(text)
        drain()
    }

    private func drain() {
        guard !draining, !queue.isEmpty else { return }
        guard let (host, above) = anchor() else {
            queue = []
            return
        }
        let text = queue.removeFirst()
        draining = true

        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -8),
        ])
        let glass = MacTheme.glass(around: padded, cornerRadius: 18)
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: above, constant: -MacTheme.Spacing.m),
            glass.widthAnchor.constraint(
                lessThanOrEqualTo: host.widthAnchor, constant: -2 * MacTheme.Spacing.xl),
        ])

        glass.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            glass.animator().alphaValue = 1
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                glass.animator().alphaValue = 0
            }
            glass.removeFromSuperview()
            guard let self else { return }
            self.draining = false
            self.drain()
        }
    }
}
