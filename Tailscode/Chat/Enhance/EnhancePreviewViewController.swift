#if DEBUG
import UIKit

/// DEBUG-only harness for eyeballing the enhancement overlay without a live
/// Apple-Intelligence model or a real session. Launched via `--enhance-preview`
/// (mock cards) so the card deck, peeking, paging and glass can be screenshot
/// on a simulator. Also logs the real on-device availability for diagnostics.
@MainActor
final class EnhancePreviewViewController: UIViewController, PromptEnhanceOverlayDelegate {
    private let overlay = PromptEnhanceOverlay()
    private let probe = PromptEnhancer()
    private let controller = PromptEnhancementController()
    private let liveInput = "add a dark mode toggle to the settings screen and remember it"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        addFauxTranscript()

        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
        ])

        switch probe.availability {
        case .available:
            AppLogger.ui.info("enhance preview: Foundation Model AVAILABLE on this device")
        case .unavailable(let reason):
            AppLogger.ui.info("enhance preview: Foundation Model unavailable — \(reason)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let args = CommandLine.arguments
        if args.contains("--enhance-preview-skeleton") {
            overlay.render(.generating, original: liveInput)
            overlay.animateIn(fromButtonCenter: previewButtonCenter())
            return
        }
        if args.contains("--enhance-preview-live") {
            controller.onStatusChange = { [weak self] status in
                guard let self else { return }
                self.overlay.render(status, original: self.liveInput)
            }
            overlay.render(.generating, original: liveInput)
            overlay.animateIn(fromButtonCenter: previewButtonCenter())
            controller.requestNow(for: liveInput)
            return
        }
        overlay.render(.ready(Self.mock), original: liveInput)
        overlay.animateIn(fromButtonCenter: previewButtonCenter())
        if args.contains("--enhance-preview-mid") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.overlay.debugScroll(toCard: 1)
            }
        }
    }

    private func addFauxTranscript() {
        let lines: [(String, Bool)] = [
            ("Can you add a settings screen?", true),
            ("Done — I added a grouped settings list with theme, haptics, and account rows.", false),
            ("Now wire up persistence for each toggle", true),
            ("Each toggle now writes through to UserDefaults and restores on launch.", false),
        ]
        var last: UIView?
        for (text, isUser) in lines {
            let bubble = UILabel()
            bubble.text = text
            bubble.numberOfLines = 0
            bubble.font = Theme.Font.body()
            bubble.textColor = isUser ? .white : Theme.Color.label
            bubble.backgroundColor = isUser ? Theme.Color.accent : Theme.Color.assistantBubble
            bubble.textAlignment = .natural
            bubble.layer.cornerRadius = Theme.Radius.bubble
            bubble.layer.cornerCurve = .continuous
            bubble.clipsToBounds = true
            bubble.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let pad = UIView()
            pad.translatesAutoresizingMaskIntoConstraints = false
            bubble.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(bubble)
            view.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
                container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
                container.topAnchor.constraint(
                    equalTo: last?.bottomAnchor ?? view.safeAreaLayoutGuide.topAnchor,
                    constant: Theme.Spacing.m),
                bubble.topAnchor.constraint(equalTo: container.topAnchor),
                bubble.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                bubble.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.8),
                isUser
                    ? bubble.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                    : bubble.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ])
            last = container
        }
    }

    static let mock: [EnhancedPrompt] = [
        EnhancedPrompt(
            id: 0, label: "More specific",
            text: "Add a \"Dark Mode\" toggle to the Settings screen. Persist the choice in "
                + "UserDefaults and apply it app-wide on the next launch via "
                + "window.overrideUserInterfaceStyle."),
        EnhancedPrompt(
            id: 1, label: "Adds constraints",
            text: "Implement a dark-mode switch in Settings that (1) persists across launches, "
                + "(2) updates every already-open screen live, and (3) falls back to the system "
                + "appearance when the user has never set it."),
        EnhancedPrompt(
            id: 2, label: "Step by step",
            text: "1. Add a darkMode preference to AppPreferences. 2. Add a UISwitch row in "
                + "Settings bound to it. 3. On change, set the window's overrideUserInterfaceStyle. "
                + "4. Restore the saved value at launch."),
    ]

    private func previewButtonCenter() -> CGPoint {
        overlay.layoutIfNeeded()
        return CGPoint(x: overlay.bounds.width - 44, y: overlay.bounds.height + 24)
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        AppLogger.ui.info("enhance preview: chose \(prompt.label)")
    }
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {}
    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {}
    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {}

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
}
#endif
