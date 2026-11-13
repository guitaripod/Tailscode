import TailscodeCore
import UIKit

extension SettingsViewController {
    /// What one page holds, group by group. Groups that would be empty are left for the snapshot to
    /// drop, so a page reads the same whether or not a server is in trouble.
    /// Dictation's rows, on a device whose engine exists: iOS 26 and later.
    private var dictationSection: [(Section, [Item])] {
        guard DictationEngines.shared.isSupported else { return [] }
        return [(.dictation, [.dictationLanguage, .toggle(.dictationChatWords)])]
    }

    func sections(of page: Page) -> [(Section, [Item])] {
        switch page {
        case .root: return rootSections()
        case .connections:
            var demo: [Item] = []
            if ConnectionController.shared.isDemoMode { demo.append(.leaveDemo) }
            return [
                (.alerts, alertItems),
                (.servers, facts.profiles.map { Item.profile($0) }),
                (.addServer, [.addConnection, .discover]),
                (.demo, demo),
                (.testServers, [.testAll]),
            ]
        case .tailnet:
            return [
                (.tailnetStatus, [.tailnetStatus]),
                (.discovery, [.tailnetToken, .tailnetScan]),
            ]
        case .notifications:
            var muted: [Item] = []
            if !AppPreferences.noticeRules.muted.isEmpty { muted = [.unmuteAll] }
            return [
                (.permission, [.notificationPermission, .backgroundRefresh]),
                (.finished, [.noticeFinish, .noticeMinimum]),
                (.needsYou, [.toggle(.notifyApprovals)]),
                (.muted, muted),
                (.usageAlerts, [.toggle(.notifyUsage), .toggle(.notifyRunningLow)]),
                (.liveActivities, [.toggle(.liveActivities)]),
                (.push, [.toggle(.serverPush)] + pushCapableProfiles.map { Item.pushState($0.id) }),
                (.testNotice, [.testNotification]),
            ]
        case .chat:
            return [
                (.composer, [.toggle(.sendOnReturn), .toggle(.promptEnhancement), .keyboardShortcuts]),
            ] + dictationSection + [
                (
                    .agentSteps,
                    [.activityStyle, .toggle(.compactActivity), .toggle(.autoExpandThinking)]
                ),
                (.answers, [.streamRenderer, .toggle(.responseStats), .toggle(.linkEmbeds)]),
                (.resume, [.toggle(.autoResume)]),
            ]
        case .appearance:
            return [
                (.theme, [.appearance]),
                (.density, [.chatDensity]),
                (.orb, [.toggle(.presenceOrb)]),
            ]
        case .keys:
            return [(.keys, [.ollamaKey, .deepseekKey])]
        case .diagnostics:
            return [
                (.logs, [.viewLogs]),
                (.report, [.copyDiagnostics, .emailDiagnostics]),
            ]
        case .about:
            return [
                (.version, [.version]),
                (.feedback, [.rate, .share]),
                (.legal, [.source, .privacy, .support, .licenses]),
            ]
        }
    }

    private func rootSections() -> [(Section, [Item])] {
        var alerts = alertItems
        if !facts.updates.standing.isEmpty { alerts.append(.software) }
        return [
            (.midgar, [.midgar]),
            (.alerts, alerts),
            (.network, [.page(.connections), .page(.tailnet), .softwareUpdate]),
            (.experience, [.page(.notifications), .page(.chat), .page(.appearance), .haptics]),
            (.accounts, [.usage, .page(.keys)]),
            (.pro, [.pro]),
            (.support, [.page(.diagnostics), .page(.about)]),
        ]
    }

    private var alertItems: [Item] {
        ServerHealthMonitor.verdict() == .fine ? [] : [.connectionAlert]
    }

    /// Every row a search can reach, each under the page it lives on and each once: the trouble
    /// banner stands on the first page and on Servers, and the first page's is the one shown. The
    /// Midgar card is a card, not a setting, and a search for it lists nothing.
    private func searchResults() -> [(Section, [Item])] {
        var seen: Set<Item> = [.midgar]
        return Page.allCases.map { page in
            let items = sections(of: page).flatMap(\.1).filter {
                matches(query, $0) && seen.insert($0).inserted
            }
            return (Section.results(page), items)
        }
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
        for (section, items) in query.isEmpty ? sections(of: page) : searchResults() {
            guard !items.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshFooters()
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
        refreshFooters()
    }

    /// Opens a page on an already-open Settings, from its first page and with any search cleared:
    /// a deep link arriving while the person has the screen filtered, or three pages in, would
    /// otherwise appear to do nothing.
    func reveal(page: Page) {
        if !query.isEmpty {
            navigationItem.searchController?.searchBar.text = ""
            navigationItem.searchController?.isActive = false
            query = ""
            applySnapshot()
        }
        navigationController?.popToViewController(self, animated: false)
        guard page != .root else { return }
        open(page, animated: true)
    }

    func open(_ page: Page, highlighting item: Item? = nil, animated: Bool) {
        let next = SettingsViewController(page: page, highlight: item)
        navigationController?.pushViewController(next, animated: animated)
    }

    /// Puts the row a search led to in the middle of its page and lights it for a moment, the way
    /// the iPhone's own Settings points at what was searched for.
    func flash(_ item: Item) {
        guard let path = dataSource.indexPath(for: item) else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collectionView.selectItem(at: path, animated: false, scrollPosition: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.collectionView.deselectItem(at: path, animated: true)
        }
    }

    private func matches(_ query: String, _ item: Item) -> Bool {
        guard !query.isEmpty else { return true }
        return keywords(for: item).localizedCaseInsensitiveContains(query)
    }

    private func keywords(for item: Item) -> String {
        switch item {
        case .page(let page): return page.title
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
        case .software, .softwareUpdate:
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
        case .toggle(let toggle): return "\(toggle.title) \(toggle.keywords)"
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
        case .dictationLanguage:
            return "\(DictationReading.settingsTitle) \(DictationReading.languageTitle) "
                + Localized.text("dictation dictate voice speech microphone mic talk language")
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
        case .noticeFinish:
            return "\(NoticeRulesWords.finishTitle) "
                + String(
                    localized: "notifications finished done turn ends spam background work every",
                    comment: "search keywords")
        case .noticeMinimum:
            return "\(NoticeRulesWords.minimumTitle) "
                + String(
                    localized: "notifications minimum length long short quick", comment: "search keywords")
        case .unmuteAll:
            return "\(NoticeRulesWords.mutedTitle) "
                + String(localized: "mute unmute silence chats quiet", comment: "search keywords")
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
                localized: "pro purchase upgrade restore week servers delegate", comment: "search keywords")
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

    /// A moment already past, never "in 0 seconds": a check that landed while this line was being
    /// written is stamped a hair after the clock it is read against.
    static func relative(_ date: Date) -> String {
        let now = Date()
        return RelativeDateFormat.string(for: min(date, now), relativeTo: now, style: .full)
    }
}
