import AppKit
import CodingAgentKit
import TailscodeCore
import os

/// The checklist an app would show on first run, asked once from wherever a Mac server is met —
/// the servers window's per-server section and first run's own step both embed this same view,
/// so the words, the poll and the states cannot drift between them. Every word is
/// `MachinePermissionReading`'s; this view only lays the words out and drives the backend.
@MainActor
final class MachinePermissionsView: NSView {
    private static let log = Logger(subsystem: "com.guitaripod.tailscode", category: "connection")

    /// Called once when a grant this view watched go from off to on, which is what lets first run
    /// finish by itself on the person's good news.
    var onGranted: (() -> Void)?

    private let backend: any PermissionReportingBackend
    private let thisHost: String?
    private let showsHeader: Bool
    private let column = FillingStack()
    private var current: MachinePermissions?
    private var watching = false
    private var watchToken = 0
    private var requestFailedKinds: Set<MachinePermissions.Grant.Kind> = []
    private var localFallback: (kind: MachinePermissions.Grant.Kind, at: Date)?

    init(
        backend: any PermissionReportingBackend,
        thisHost: String? = ProcessInfo.processInfo.hostName,
        showsHeader: Bool = true,
        initial: MachinePermissions? = nil
    ) {
        self.backend = backend
        self.thisHost = thisHost
        self.showsHeader = showsHeader
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.spacing = MacTheme.Spacing.m
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        if let initial { apply(initial) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        watch()
    }

    /// Refreshes once, then keeps asking every `MachinePermissionReading.pollInterval` for as
    /// long as this view is on screen and a grant is still missing — a switch flipped on the
    /// Mac's own screen is noticed without anyone coming back to press refresh.
    private func watch() {
        guard !watching else { return }
        watching = true
        watchToken += 1
        let token = watchToken
        Task { [weak self] in
            while let owner = self, owner.window?.isVisible == true, token == owner.watchToken {
                await owner.refresh()
                guard let owner = self, owner.window?.isVisible == true, token == owner.watchToken,
                    let permissions = owner.current, MachinePermissionReading.isShown(permissions),
                    !permissions.isComplete
                else { break }
                try? await Task.sleep(for: MachinePermissionReading.pollInterval)
            }
            self?.watching = false
        }
    }

    private func refresh() async {
        do {
            apply(try await backend.machinePermissions())
        } catch {
            Self.log.error(
                "machinePermissions failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func apply(_ permissions: MachinePermissions?) {
        let previous = current
        current = permissions
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let permissions, MachinePermissionReading.isShown(permissions) else {
            isHidden = true
            return
        }
        isHidden = false
        if showsHeader {
            column.addArrangedSubview(
                MacDialogs.sectionHeader(MachinePermissionReading.sectionTitle(permissions)))
        }
        let local = MachinePermissionReading.isLocal(permissions, thisHost: thisHost)
        for grant in permissions.known {
            column.addArrangedSubview(
                grantRow(grant, permissions: permissions, local: local, previous: previous))
        }
    }

    private func grantRow(
        _ grant: MachinePermissions.Grant, permissions: MachinePermissions, local: Bool,
        previous: MachinePermissions?
    ) -> NSView {
        guard let kind = grant.kind else { return NSView() }
        let stack = FillingStack()
        stack.spacing = 4

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: MachinePermissionReading.symbol(grant), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.contentTintColor =
            grant.state == .granted ? MacTheme.Color.success : MacTheme.Color.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let title = RowKit.label(
            MachinePermissionReading.title(kind), font: MacTheme.Ramp.font(.panelLabel),
            color: MacTheme.Color.label)
        let state = RowKit.label(
            MachinePermissionReading.state(grant), font: MacTheme.Ramp.font(.panelFootnote),
            color: grant.state == .granted ? MacTheme.Color.success : MacTheme.Color.secondaryLabel)
        let header = NSStackView(views: [icon, title, RowKit.spacer(), state])
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(
            RowKit.wrapping(
                MachinePermissionReading.purpose(kind), font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel))

        let justCompleted =
            grant.state == .granted
            && previous?.grants.first(where: { $0.id == grant.id })?.state == .missing
        if justCompleted {
            onGranted?()
            stack.addArrangedSubview(
                RowKit.wrapping(
                    MachinePermissionReading.done(permissions), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.success))
        } else if grant.state == .missing {
            addMissingContent(
                to: stack, kind: kind, permissions: permissions, local: local)
        }

        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(MachinePermissionReading.accessibility(grant))
        return stack
    }

    private func addMissingContent(
        to stack: FillingStack, kind: MachinePermissions.Grant.Kind, permissions: MachinePermissions,
        local: Bool
    ) {
        let waiting =
            MachinePermissionReading.isWaiting(permissions)
            || (localFallback?.kind == kind
                && Date().timeIntervalSince(localFallback!.at) < MachinePermissionReading.waitingWindow)
        let button = RowKit.ActionButton(
            title: MachinePermissionReading.action(permissions, local: local)
        ) { [weak self] in
            self?.request(kind)
        }
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)
        for (index, step) in MachinePermissionReading.steps(permissions, local: local).enumerated()
        where waiting {
            stack.addArrangedSubview(
                RowKit.wrapping(
                    "\(index + 1). \(step)", font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        if requestFailedKinds.contains(kind) {
            stack.addArrangedSubview(
                RowKit.wrapping(
                    MachinePermissionReading.requestFailed, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.warning))
        }
    }

    /// The preferred road is always the server's own — it opens the pane on the machine that has
    /// it and records `requestedAt`, which is what lets a phone across the room show the same
    /// steps. Only a local client, and only once that road fails, falls back to opening System
    /// Settings on this very screen itself.
    private func request(_ kind: MachinePermissions.Grant.Kind) {
        guard let permissions = current else { return }
        let local = MachinePermissionReading.isLocal(permissions, thisHost: thisHost)
        requestFailedKinds.remove(kind)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let updated = try await self.backend.requestMachinePermission(kind) else {
                    throw AgentError.connection("the server has no answer for this request")
                }
                self.apply(updated)
            } catch {
                Self.log.error(
                    "requestMachinePermission(\(kind.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
                )
                if local {
                    self.openLocally(permissions)
                    self.localFallback = (kind, Date())
                    self.apply(permissions)
                } else {
                    self.requestFailedKinds.insert(kind)
                    self.apply(permissions)
                }
            }
        }
    }

    private func openLocally(_ permissions: MachinePermissions) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) {
            NSWorkspace.shared.open(url)
        }
        if let executable = permissions.executable, !executable.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: executable)])
        }
    }
}
