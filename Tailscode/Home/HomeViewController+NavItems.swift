import TailscodeCore
import CodingAgentKitApple
import UIKit

extension HomeViewController {
    /// Everything the left of the bar says about what this app is doing, decided in one place.
    ///
    /// The demo is a full, believable two-server world, which is exactly why it needs to say so on
    /// every screen — and why the way out of it belongs here rather than three taps deep in
    /// Settings. The standing update mark rides the same slot, on the gear itself. Two methods
    /// each rebuilding `leftBarButtonItems` from what they found there fought: whichever ran last
    /// won, and the other's item vanished.
    func updateLeftBarItems() {
        guard workspace == nil else {
            navigationItem.leftBarButtonItems =
                ConnectionController.shared.isDemoMode && !Self.demoBadgeHidden ? [demoBadge()] : []
            return
        }
        var items = [settingsItem]
        if let chip = UpdateLedger.rollup().chip {
            updateChip.apply(chip)
            items.append(updateChipItem)
        }
        if ConnectionController.shared.isDemoMode, !Self.demoBadgeHidden {
            items.append(demoBadge())
        }
        navigationItem.leftBarButtonItems = items
    }

    /// The marketing set is shot in the demo world, and a badge that honestly brands every
    /// screenshot as fake would defeat the set's whole purpose — so the screenshot pipeline may
    /// hide it, and only in DEBUG builds.
    static let demoBadgeHidden: Bool = {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_HIDE_DEMO_BADGE"] != nil
        #else
            return false
        #endif
    }()

    /// The chip comes and goes with the fact it stands for, so an answer landing rebuilds the
    /// items rather than repainting one that may not be there.
    @objc func updatesDidChange() {
        updateLeftBarItems()
    }

    @objc func openUpdates() {
        Theme.Haptics.tap()
        UpdateCenterViewController.present(from: self)
    }

    private func demoBadge() -> UIBarButtonItem {
        var config = UIButton.Configuration.tinted()
        config.title = String(localized: "DEMO")
        config.baseForegroundColor = Theme.Color.warning
        config.baseBackgroundColor = Theme.Color.warning
        config.cornerStyle = .capsule
        config.buttonSize = .mini
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.metricLabel)
            return out
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "Demo mode. Sample data, no real servers.")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "Set up my machine"), image: UIImage(systemName: "server.rack")
            ) { [weak self] _ in self?.presentSetup() },
            UIAction(
                title: String(localized: "Leave the demo"), image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { _ in
                Theme.Haptics.warning()
                ConnectionController.shared.leaveDemoMode()
            },
        ])
        return UIBarButtonItem(customView: button)
    }

    /// Opens the add-server flow from wherever the app is, so the Home screen
    /// quick action reaches the same screen as the demo-mode menu's own entry.
    func presentServerSetup() {
        presentSetup()
    }

    func presentSetup() {
        Theme.Haptics.tap()
        let setup = ServerSetupViewController(mode: .addServer)
        let nav = UINavigationController(rootViewController: setup)
        nav.navigationBar.prefersLargeTitles = true
        setup.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        setup.onConnected = { [weak nav] in nav?.dismiss(animated: true) }
        present(nav, animated: true)
    }

    /// Home's bar carries one button for everything that is not the board: the tools. The composer
    /// is the new chat, so a pencil that only focused a box already on screen is gone from the
    /// phone; with several servers the menu opens with the choice of machine, which keeps its
    /// one-tap home. A render that is out is the exception, because the light round its button is
    /// how the app says where a clip or a picture is — that button stays in the bar for as long as
    /// the light is lit. The iPad keeps its pencil: beside a chat list, where no box is in reach,
    /// starting a chat is the list's own action.
    func updateComposeButton() {
        let servers = viewModel.servers
        let door = ImageGenDoor.current()
        let rendering = ForgeRunner.shared.light != .dark
        let painting = ImageStudio.shared.isPainting
        let state =
            servers.map { "\($0.id)|\($0.name)|\($0.backend.rawValue)" }.joined(separator: "\u{1}")
            + "\u{1}image=\(door.isOpen)\u{1}columns=\(workspace != nil)"
            + "\u{1}render=\(rendering)\u{1}paint=\(painting)"
        guard state != appliedComposeButtonState else { return }
        appliedComposeButtonState = state
        guard workspace == nil else {
            navigationItem.rightBarButtonItems = [newChatItem(for: servers)]
            return
        }
        var items = [toolsItem(for: servers, imageOpen: door.isOpen)]
        if rendering { items.append(videoItem) }
        if painting { items.append(imageItem) }
        navigationItem.rightBarButtonItems = items
    }

    private func newChatItem(for servers: [ConnectionProfile]) -> UIBarButtonItem {
        let compose = UIImage(systemName: "square.and.pencil")
        let item: UIBarButtonItem
        if servers.count > 1 {
            item = UIBarButtonItem(
                image: compose,
                menu: UIMenu(
                    title: String(localized: "New chat on…"), children: newChatActions(for: servers)))
        } else {
            item = UIBarButtonItem(
                image: compose,
                primaryAction: UIAction { [weak self] _ in
                    guard let self, let profile = self.viewModel.servers.first else { return }
                    self.startChat(on: profile)
                })
        }
        item.accessibilityLabel = String(localized: "New chat")
        return item
    }

    private func newChatActions(for servers: [ConnectionProfile]) -> [UIMenuElement] {
        servers.map { profile in
            UIAction(
                title: profile.name, subtitle: profile.backend.displayName,
                image: UIImage(systemName: profile.backend.symbolName)?
                    .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
            ) { [weak self] _ in self?.startChat(on: profile) }
        }
    }

    private func toolsItem(for servers: [ConnectionProfile], imageOpen: Bool) -> UIBarButtonItem {
        var sections: [UIMenuElement] = []
        if servers.count > 1 {
            sections.append(
                UIMenu(
                    title: String(localized: "New chat on…"), options: .displayInline,
                    children: newChatActions(for: servers)))
        }
        var tools: [UIMenuElement] = []
        if let delegate = delegateElement(for: servers) { tools.append(delegate) }
        tools.append(
            UIAction(
                title: ForgeEntryPoint.menuTitle,
                image: UIImage(systemName: ForgeEntryPoint.symbol)
            ) { [weak self] _ in self?.openVideo() })
        if imageOpen {
            tools.append(
                UIAction(
                    title: ImageGenEntryPoint.menuTitle,
                    image: UIImage(systemName: ImageGenEntryPoint.symbol)
                ) { [weak self] _ in self?.openImage() })
        }
        sections.append(UIMenu(options: .displayInline, children: tools))
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: sections))
        item.accessibilityLabel = String(localized: "Tools")
        return item
    }

    /// The dispatcher's door: one server opens its board outright, more than one asks which
    /// machine first. A free copy meets the Pro sheet with the delegate pitch either way.
    private func delegateElement(for servers: [ConnectionProfile]) -> UIMenuElement? {
        let image = UIImage(systemName: DelegateEntryPoint.symbol)
        switch servers.count {
        case 0:
            return nil
        case 1:
            return UIAction(
                title: DelegateEntryPoint.menuTitle, subtitle: BetaWords.label, image: image
            ) { [weak self] _ in
                guard let self, let profile = servers.first else { return }
                DelegateGate.open(from: self, profile: profile)
            }
        default:
            return UIMenu(
                title: DelegateEntryPoint.menuTitle, subtitle: BetaWords.label, image: image,
                children: servers.map { profile in
                    UIAction(
                        title: profile.name, subtitle: ServerLabel.address(profile),
                        image: UIImage(systemName: profile.backend.symbolName)?
                            .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
                    ) { [weak self] _ in
                        guard let self else { return }
                        DelegateGate.open(from: self, profile: profile)
                    }
                })
        }
    }
}
