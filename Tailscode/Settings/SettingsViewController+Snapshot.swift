import TailscodeCore
import UIKit

extension SettingsViewController {
    private func allItems() -> [(Section, [Item])] {
        var connectionItems: [Item] = []
        if ServerHealthMonitor.verdict() != .fine { connectionItems.append(.connectionAlert) }
        connectionItems += facts.profiles.map { Item.profile($0) }
        connectionItems += [.addConnection, .discover]
        if ConnectionController.shared.isDemoMode { connectionItems.append(.leaveDemo) }

        var notificationItems: [Item] = [
            .notificationPermission, .backgroundRefresh, .toggle(.notifyTurnComplete),
            .toggle(.notifyApprovals), .toggle(.notifyUsage), .toggle(.notifyRunningLow),
            .toggle(.liveActivities), .toggle(.serverPush),
        ]
        notificationItems += pushCapableProfiles.map { Item.pushState($0.id) }
        notificationItems.append(.testNotification)

        let usageItems: [Item] = [.usage, .ollamaKey, .deepseekKey]

        return [
            (.midgar, [.midgar]),
            (.connections, connectionItems),
            (.software, [.software]),
            (.tailnet, [.tailnetStatus, .tailnetToken, .tailnetScan]),
            (.notifications, notificationItems),
            (.usage, usageItems),
            (
                .chat,
                [
                    .toggle(.promptEnhancement), .toggle(.autoExpandThinking),
                    .streamRenderer, .haptics,
                    .toggle(.compactActivity), .toggle(.responseStats), .toggle(.linkEmbeds),
                    .toggle(.sendOnReturn), .toggle(.autoResume),
                    .keyboardShortcuts,
                ]
            ),
            (.appearance, [.appearance, .chatDensity, .activityStyle, .toggle(.presenceOrb)]),
            (.pro, [.pro]),
            (.diagnostics, [.viewLogs, .testAll, .copyDiagnostics, .emailDiagnostics]),
            (.about, [.version, .rate, .share, .source, .privacy, .support, .licenses]),
        ]
    }

    /// A change that arrives from outside, such as a server answering a health probe or the update
    /// driver finishing a step, is applied once on a later turn of the run loop however many came
    /// together, and not while the list is moving: reconfiguring every row under a scroll is a
    /// frame the scroll does not get back. It lands the moment the list has been still.
    func scheduleSnapshot() {
        guard !hasDeferredSnapshot else { return }
        hasDeferredSnapshot = true
        retryDeferredSnapshot(after: .milliseconds(1))
    }

    private func retryDeferredSnapshot(after delay: DispatchTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hasDeferredSnapshot else { return }
            guard !self.isScrolling else { return self.retryDeferredSnapshot(after: .milliseconds(150)) }
            self.applySnapshot()
        }
    }

    var isScrolling: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
            || CACurrentMediaTime() - lastScrollAt < Self.stillnessInterval
    }

    private static let stillnessInterval: CFTimeInterval = 0.15

    func applySnapshot() {
        hasDeferredSnapshot = false
        facts = facts.refreshingStores()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for (section, items) in allItems() {
            let matching = items.filter { matches(query, $0) }
            guard !matching.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(matching, toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(itemCount: snapshot.numberOfItems)
    }

    private func updateEmptyState(itemCount: Int) {
        guard itemCount == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.search()
        config.text = String(localized: "No settings match \"\(query)\"")
        contentUnavailableConfiguration = config
    }

    func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Brings a section into view on an already-open Settings, clearing any
    /// active search first — a deep link arriving while the user has the screen
    /// filtered would otherwise appear to do nothing.
    func reveal(section: Section) {
        if !query.isEmpty {
            navigationItem.searchController?.searchBar.text = ""
            query = ""
            applySnapshot()
        }
        scroll(to: section)
    }

    /// Lands on the section's header rather than its first row: scrolling the row
    /// to the top parks the header underneath the pinned search bar, so a deep
    /// link arrives with no visible indication of which section it chose.
    func scroll(to section: Section) {
        let snapshot = dataSource.snapshot()
        guard let index = snapshot.sectionIdentifiers.firstIndex(of: section),
            snapshot.numberOfItems(inSection: section) > 0
        else { return }
        let path = IndexPath(item: 0, section: index)
        guard
            let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: path)
        else {
            collectionView.scrollToItem(at: path, at: .top, animated: true)
            return
        }
        let inset = collectionView.adjustedContentInset.top
        let limit = collectionView.contentSize.height - collectionView.bounds.height + inset
        let target = min(max(header.frame.minY - inset, -inset), max(limit, -inset))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    private func matches(_ query: String, _ item: Item) -> Bool {
        guard !query.isEmpty else { return true }
        return keywords(for: item).localizedCaseInsensitiveContains(query)
    }

    private func keywords(for item: Item) -> String {
        switch item {
        case .midgar:
            return String(localized: "midgar apps portal more apps", comment: "search keywords")
        case .connectionAlert:
            return String(localized: "unreachable tailscale offline servers", comment: "search keywords")
        case .profile(let profile):
            return "\(profile.name) \(profile.backend.displayName) \(profile.baseURL.host ?? "") "
                + String(localized: "server connection", comment: "search keywords")
        case .addConnection:
            return String(localized: "add connection server new", comment: "search keywords")
        case .discover:
            return String(localized: "discover tailnet scan servers", comment: "search keywords")
        case .leaveDemo: return String(localized: "leave demo sample", comment: "search keywords")
        case .software:
            return String(
                localized: "update updates software version build bridge upgrade newest release",
                comment: "search keywords")
        case .tailnetStatus:
            return String(
                localized: "tailscale tailnet vpn status connected address", comment: "search keywords")
        case .tailnetToken:
            return String(
                localized: "tailscale api token key keychain discovery", comment: "search keywords")
        case .tailnetScan:
            return String(
                localized: "last discovery scan devices tailnet", comment: "search keywords")
        case .notificationPermission:
            return String(
                localized: "notifications permission authorization alerts allow",
                comment: "search keywords")
        case .backgroundRefresh:
            return String(
                localized: "background app refresh wait turn ends closed",
                comment: "search keywords")
        case .toggle(let toggle): return "\(toggle.title) \(toggle.subtitle ?? "")"
        case .pushState(let id):
            let name = facts.profiles.first { $0.id == id }?.name ?? ""
            return String(localized: "push notifications bridge", comment: "search keywords")
                + " \(name)"
        case .testNotification:
            return String(localized: "test notification send check", comment: "search keywords")
        case .usage:
            return String(
                localized: "usage limits quota gauges plan spend", comment: "search keywords")
        case .ollamaKey:
            return String(
                localized: "ollama cloud api key plan session weekly windows",
                comment: "search keywords")
        case .deepseekKey:
            return String(
                localized: "deepseek api key balance prepaid token", comment: "search keywords")
        case .keyboardShortcuts:
            return String(
                localized: "keyboard shortcuts keys hardware cheatsheet rebind",
                comment: "search keywords")
        case .streamRenderer:
            return String(
                localized:
                    "streaming stream reveal cascade aurora metal gpu renderer typing animation alpha",
                comment: "search keywords")
        case .haptics:
            return String(
                localized: "haptics vibration taptic strength intensity feedback buzz",
                comment: "search keywords")
        case .appearance:
            return String(
                localized:
                    "theme appearance dark light mode colour color palette rose pine tokyo night everforest gruvbox nord solarized phosphor",
                comment: "search keywords")
        case .chatDensity:
            return "\(ChatDensitySetting.title) "
                + String(
                    localized: "density compact comfortable spacing rows tight airy",
                    comment: "search keywords")
        case .activityStyle:
            return "\(ActivityStyleSetting.title) "
                + Localized.text("megatron brain head lines tools thinking activity neural nodes style")
        case .pro:
            return String(
                localized: "pro purchase upgrade supporter restore tip", comment: "search keywords")
        case .viewLogs:
            return String(
                localized: "logs diagnostics view file debug", comment: "search keywords")
        case .testAll:
            return String(
                localized: "test all connections health reachability", comment: "search keywords")
        case .copyDiagnostics:
            return String(
                localized: "copy diagnostics report bug support", comment: "search keywords")
        case .emailDiagnostics:
            return String(
                localized: "email diagnostics support bug report", comment: "search keywords")
        case .version: return String(localized: "version build number", comment: "search keywords")
        case .source:
            return String(
                localized: "source code github open source gpl", comment: "search keywords")
        case .privacy: return String(localized: "privacy policy data", comment: "search keywords")
        case .support: return String(localized: "support help contact", comment: "search keywords")
        case .rate:
            return String(localized: "rate review app store stars", comment: "search keywords")
        case .share:
            return String(localized: "share tell a friend link", comment: "search keywords")
        case .licenses:
            return String(
                localized: "acknowledgements licenses third party open source",
                comment: "search keywords")
        }
    }

    static var versionString: String {
        let info = { (key: String) in Bundle.main.object(forInfoDictionaryKey: key) as? String }
        let version = info("CFBundleShortVersionString") ?? "?"
        let build = info("CFBundleVersion") ?? "?"
        return "\(version) (\(build))"
    }

    static var copyright: String { "© 2026 Midgar Oy" }

    static func relative(_ date: Date) -> String {
        RelativeDateFormat.string(for: date, style: .full)
    }
}
