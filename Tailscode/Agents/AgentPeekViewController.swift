import MidgarCore
import TailscodeCore
import UIKit

/// A read-only monitor of one agent: what it is doing in words, its last steps, the agents it has
/// out, the files it has touched and three meters. Opening the chat is its own verb, and a subagent
/// is read here and never opened as a chat of its own. It reads the tower's facts while the agent
/// is watched, and says plainly when it is only listed.
@MainActor
final class AgentPeekViewController: UIViewController {
    var onOpenChat: ((String, String) -> Void)?
    var onDismiss: (() -> Void)?

    let target: AgentsPeekTarget
    let hub: AgentsHub
    var row: AgentRow?
    var facts: AgentFacts?
    var board: AgentBoard?
    var watchRequested = false
    var isBusy = false

    let scrollView = UIScrollView()
    let content = UIStackView()
    let badgeBox = UIView()
    let badge = ActivityBadgeView(pointSize: 18)
    let titleLabel = UILabel()
    let elapsedLabel = UILabel()
    let metaLabel = UILabel()
    let watchButton = AgentsPeekStyle.button(String(localized: "Watch this one"), symbol: "eye")
    let openButton = AgentsPeekStyle.button(String(localized: "Open chat"), prominent: true)
    let stopButton = AgentsPeekStyle.button(String(localized: "Stop"))
    let nudgeButton = AgentsPeekStyle.button(String(localized: "Nudge…"))
    let secondaryRow = UIStackView()
    let statusLabel = UILabel()
    let nudgeBar = UIView()
    let nudgeField = UITextField()
    let nudgeSend = UIButton(type: .system)
    var lastSignature: Signature?

    private var factsTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    var timed: [(Date) -> Void] = []

    init(target: AgentsPeekTarget, hub: AgentsHub) {
        self.target = target
        self.hub = hub
        self.row = target.row
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        buildSkeleton()
        observeScene()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: AgentPeekViewController, _) in controller.render()
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = nudgeBar.isHidden ? 0 : nudgeBar.frame.height
        if scrollView.contentInset.bottom != inset { scrollView.contentInset.bottom = inset }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        stop()
        view.endEditing(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismiss?() }
    }

    func update(board: AgentBoard) {
        self.board = board
        row = board.row(target.key) ?? row
        render()
    }

    private func start() {
        guard factsTask == nil else { return }
        factsTask = Task { [weak self] in
            guard let stream = await self?.hub.facts(for: self?.target.key ?? "") else { return }
            for await next in stream {
                guard !Task.isCancelled, let self else { return }
                self.facts = next
                self.render()
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stop() {
        factsTask?.cancel()
        factsTask = nil
        ticker?.cancel()
        ticker = nil
    }

    private func observeScene() {
        let center = NotificationCenter.default
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(sceneLeft(_:)), name: name, object: nil)
        }
        center.addObserver(
            self, selector: #selector(sceneBack(_:)), name: UIScene.didActivateNotification, object: nil)
    }

    private func ownsScene(_ note: Notification) -> Bool {
        guard let scene = note.object as? UIScene else { return true }
        return scene === viewIfLoaded?.window?.windowScene
    }

    @objc private func sceneLeft(_ note: Notification) {
        guard ownsScene(note) else { return }
        stop()
    }

    @objc private func sceneBack(_ note: Notification) {
        guard ownsScene(note), viewIfLoaded?.window != nil else { return }
        start()
    }

    func tick() {
        let now = Date()
        for update in timed { update(now) }
    }

    func openChat() {
        view.endEditing(true)
        onOpenChat?(target.profileID, target.sessionID)
    }

    func say(_ words: String, failure: Bool = false) {
        statusLabel.text = words
        statusLabel.textColor = failure ? Theme.Color.danger : Theme.Color.secondaryLabel
        statusLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: words)
    }
}
