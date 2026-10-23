import TailscodeCore
import CodingAgentKit
import UIKit

extension ServerDetailViewController {
    func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let showsPermissions = MachinePermissionReading.isShown(permissions)
        snapshot.appendSections(
            Section.allCases.filter {
                ($0 != .permissions || showsPermissions) && ($0 != .preview || (isShowingPreviewHost && !isDemo))
            })
        var info: [Item] = [
            .value(label: String(localized: "Backend"), value: profile.backend.displayName),
            .value(label: String(localized: "Host"), value: profile.baseURL.host ?? "—"),
            .value(
                label: String(localized: "Port"),
                value: profile.baseURL.port.map(String.init) ?? "—"),
        ]
        if let serverVersion {
            info.append(.value(label: String(localized: "Version"), value: serverVersion))
        }
        if let access = ServerAccessReading.line(serverAccess) {
            info.append(.value(label: String(localized: "Access"), value: access))
        }
        if let modelCount {
            info.append(.value(label: String(localized: "Models"), value: String(modelCount)))
        }
        if let sessionCount {
            info.append(.value(label: String(localized: "Sessions"), value: String(sessionCount)))
        }
        snapshot.appendItems(info, toSection: .info)

        var statusItems: [Item] = [.status(statusText)]
        if !isDemo { statusItems.append(.turnWaitAvailability) }
        if profile.backend == .claudeCode, !isDemo {
            statusItems.append(.pushState)
            if let auth { statusItems.append(.account(signedIn: auth.loggedIn)) }
        }
        statusItems.append(.test)
        snapshot.appendItems(statusItems, toSection: .status)

        if !capabilities.rows.isEmpty {
            snapshot.appendItems(capabilities.rows.map { .capability($0.capability) }, toSection: .capabilities)
        }

        if !isDemo { snapshot.appendItems([.software, .updateCenter], toSection: .software) }

        if showsPermissions {
            snapshot.appendItems([.permissions], toSection: .permissions)
        }

        var defaults: [Item] = [
            ConnectionController.shared.activeProfileID == profile.id ? .isDefault : .makeDefault
        ]
        if supportsModelDefaults { defaults.append(.defaultModel) }
        snapshot.appendItems(defaults, toSection: .defaults)

        if !isDemo { snapshot.appendItems([.delegate], toSection: .delegate) }

        if !isDemo, isShowingPreviewHost { snapshot.appendItems([.previewHost], toSection: .preview) }

        var actions: [Item] = isDemo ? [] : [.edit]
        if !isDemo, ServerRestart.isOffered(profile.backend) { actions.insert(.restart, at: 0) }
        actions.append(.remove)
        snapshot.appendItems(actions, toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func capabilityChip(_ row: SetupCapabilityRow) -> UICellAccessory.CustomViewConfiguration {
        let label = UILabel()
        label.text = row.chip
        label.font = Theme.Ramp.font(.rowDetail)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = row.quiet ? Theme.Color.secondaryLabel : row.tone.color
        return UICellAccessory.CustomViewConfiguration(customView: label, placement: .trailing())
    }

    func capabilityReport(for target: SetupTarget) -> [String] {
        guard target.capability == SetupCapability.voice else { return [] }
        return VoiceCallGate.shared.reportLines(for: VoiceSetupSource.endpoint(of: target))
    }

    @objc func pushStatesChanged() { reconfigure([.pushState]) }

    func refresh() async {
        statusText = String(localized: "Checking…")
        sessionCount = nil
        serverVersion = nil
        modelCount = nil
        applySnapshot()
        let policy = ConnectionPolicy(requestTimeout: .seconds(8), resourceTimeout: .seconds(12))
        guard let backend = ConnectionController.shared.makeBackend(for: profile, policy: policy)
        else {
            statusText = String(localized: "No credentials")
            checkSoftware()
            applySnapshot()
            return
        }
        self.backend = backend
        modelChoice = await ChatModelResolver.choice(profileID: profile.id, backend: backend)
        do {
            let health = try await backend.health()
            statusText =
                health.healthy ? String(localized: "Healthy") : String(localized: "Unhealthy")
            serverVersion = health.version
            serverAccess = health.access
            ServerHealthMonitor.record(health.healthy, for: profile.id)
            sessionCount = (try? await backend.listAllSessions(knownDirectories: []))?.count
            if !isDemo {
                turnWaitAvailability = .from(await backend.turnWaitSupport(), agent: profile.backend)
            }
            if profile.backend == .openCode {
                modelCount = try? await backend.availableModels().count
            }
            if profile.backend == .claudeCode, !isDemo {
                auth = try? await (backend as? any AuthenticatingBackend)?.authStatus()
                permissions = try? await (backend as? any PermissionReportingBackend)?
                    .machinePermissions()
                #if DEBUG
                    if ProcessInfo.processInfo.environment["TAILSCODE_FAKE_PERMISSION_WAIT"] != nil {
                        permissions?.requestedAt = Date()
                    }
                #endif
            }
        } catch {
            statusText = String(localized: "Unreachable")
            ServerHealthMonitor.record(false, for: profile.id)
        }
        checkSoftware()
        applySnapshot()
        startPermissionPollingIfNeeded()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SIGNIN"] != nil,
                presentedViewController == nil
            {
                presentSignIn()
            }
        #endif
    }

    /// Asks the monitor about this machine, outside whatever the health probe did.
    ///
    /// A server that never answered still has an answer worth writing down — "it did not answer" —
    /// and hanging the question off a successful `health()` is how the Software row keeps a live
    /// spinner over a state nobody is checking.
    private func checkSoftware() {
        guard !isDemo else { return }
        Task {
            await UpdateMonitor.check(component)
            #if DEBUG
                if ProcessInfo.processInfo.environment["TAILSCODE_RUN_UPDATE"] != nil {
                    await UpdateMonitor.perform(component)
                }
            #endif
        }
    }
}
