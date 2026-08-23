import CodingAgentKit
import TailscodeCore
import UIKit

/// Finding the machine with the card instead of asking somebody to type its address.
///
/// Everything this app renders on is already on the tailnet, so the address is one the phone can go
/// and look for: `ForgeSweep` asks every machine the agent scan would ask whether anything answers
/// on ComfyUI's port, and `ForgeSweepReading` turns the wait into the same dial the server scan
/// draws — every machine in its own stable place before a probe lands, lit when it answers, gone
/// from the sky when it never did.
///
/// The one thing this screen owns that Core cannot is the way a phone gets a peer list at all: it
/// has no `tailscale` binary to ask, so the list comes from the Tailscale API with the token the
/// server flow already keeps in the Keychain. That gate is the only decision made here.
@MainActor
final class ForgeSweepViewController: UIViewController {
    var onAdopt: ((ForgeCandidate) -> Void)?

    /// What stands between this phone and a scan. Only the middle case is a decision — the key is
    /// the one thing a desktop never needs and a phone always does, and a key that was refused is
    /// the same decision rather than a second dead end: both are settled on the same screen, so
    /// both are one case that knows which sentence it is.
    private enum Gate: Equatable {
        case ready
        case needsKey(rejected: Bool)
        case trouble(String)
    }

    private let current: ForgeEndpoint?
    private var reading = ForgeSweepReading()
    private var gate: Gate = .ready
    private var found: [ForgeCandidate] = []
    private var scan: Task<Void, Never>?
    private var didAutoScan = false

    private let radar = TailnetRadarView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let action = PrimaryButton(title: "")
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ForgeCandidate>!

    init(current: ForgeEndpoint?) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ForgeSweepReading().title
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        buildUI()
        gate = Self.canScan ? .ready : .needsKey(rejected: false)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard gate == .ready, !didAutoScan else { return }
        didAutoScan = true
        startScan()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || isMovingFromParent else { return }
        scan?.cancel()
    }

    private func buildUI() {
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        action.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [radar, titleLabel, detailLabel, action])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.l, after: radar)
        column.setCustomSpacing(Theme.Spacing.l, after: detailLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        configureResults()

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            radar.heightAnchor.constraint(equalToConstant: 168),
            collectionView.topAnchor.constraint(equalTo: column.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureResults() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ForgeCandidate> {
            [weak self] cell, _, candidate in
            var content = cell.defaultContentConfiguration()
            content.text = candidate.title
            content.secondaryText = candidate.detail
            content.textProperties.font = Theme.Ramp.font(.rowTitleStrong)
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowDetail)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "desktopcomputer")
            content.imageProperties.tintColor = Theme.Color.success
            cell.contentConfiguration = content
            cell.accessories = self?.accessories(for: candidate) ?? [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            view, indexPath, candidate in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: candidate)
        }
    }

    /// The word the machine renders already go to wears, so a scan of a tailnet somebody has
    /// already set up reads as a list with one answer already chosen rather than as four strangers.
    private func accessories(for candidate: ForgeCandidate) -> [UICellAccessory] {
        guard candidate.endpoint == current, let badge = ForgeRenderer.badge(current: true) else {
            return [.disclosureIndicator()]
        }
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: badge,
            attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.secondaryLabel))
        return [
            .customView(configuration: .init(customView: label, placement: .trailing())),
            .disclosureIndicator(),
        ]
    }

    private func actionTapped() {
        Theme.Haptics.tap()
        switch gate {
        case .needsKey:
            openTokenEditor()
        case .ready, .trouble:
            startScan()
        }
    }

    private func openTokenEditor() {
        let editor = TailnetTokenViewController()
        editor.onChange = { [weak self] in
            guard let self, TailnetCredentials.hasToken else { return }
            self.gate = .ready
            self.render()
            self.startScan()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    /// Whether a scan can start at all, which on a phone is a question about the token rather
    /// than about the tailnet — there is no `tailscale` binary here to ask for a peer list.
    private static var canScan: Bool {
        #if DEBUG
            if stagedDevices != nil { return true }
        #endif
        return TailnetCredentials.hasToken
    }

    /// Asks the tailnet, or lands on the key when there is none to ask with — a phone has no
    /// `tailscale` binary, so the peer list is a request somebody has to have authorised first, and
    /// a scan that cannot be authorised is the key's state rather than a dial that finds nothing.
    private func startScan() {
        guard scan == nil else { return }
        #if DEBUG
            if let staged = Self.stagedDevices {
                begin { (staged, Self.stagedProbe) }
                return
            }
        #endif
        guard TailnetCredentials.hasToken, let token = TailnetCredentials.token else {
            gate = .needsKey(rejected: false)
            render()
            return
        }
        begin { (try await TailscaleClient().fetchDevices(with: token), ForgeSweep.liveProbe) }
    }

    /// One scan, however the peer list was got. The list is the only thing a phone cannot ask for
    /// itself, so it arrives as a closure and everything after it is the same walk.
    private func begin(
        _ peers: @escaping @Sendable () async throws -> ([TailscaleDevice], ForgeSweep.Probe)
    ) {
        gate = .ready
        found = []
        reading = ForgeSweepReading()
        render()
        scan = Task { [weak self] in
            await self?.sweep(peers)
            self?.scan = nil
        }
    }

    /// One walk of the tailnet, given up on when Core says a person has watched long enough. The
    /// walk itself checks for cancellation between machines, so the deadline stops the scan
    /// spreading rather than abandoning probes that are already out.
    private func sweep(
        _ peers: @escaping @Sendable () async throws -> ([TailscaleDevice], ForgeSweep.Probe)
    ) async {
        let devices: [TailscaleDevice]
        let probe: ForgeSweep.Probe
        do {
            (devices, probe) = try await peers()
        } catch {
            gate = Self.gate(for: error)
            AppLogger.connection.error("forge sweep could not list devices: \(error.localizedDescription)")
            render()
            return
        }
        guard !Task.isCancelled else { return }
        let targets = ForgeSweep.targets(devices)
        reading.began(targets, at: TailnetRadarView.now)
        render()
        let walk = Task { [weak self] in
            await ForgeSweep.run(
                targets: targets, probe: probe,
                onProgress: { [weak self] checked, total in
                    Task { @MainActor in self?.advanced(checked: checked, total: total) }
                },
                onFound: { [weak self] candidate in
                    Task { @MainActor in self?.light(candidate) }
                })
        }
        let watchdog = Task {
            try? await Task.sleep(for: ForgeSweep.deadline)
            walk.cancel()
        }
        _ = await walk.value
        watchdog.cancel()
        guard !Task.isCancelled else { return }
        reading.finished()
        found = reading.found
        if !found.isEmpty { Theme.Haptics.received() }
        render()
        UIAccessibility.post(notification: .announcement, argument: reading.title)
    }

    private func advanced(checked: Int, total: Int) {
        reading.advanced(checked: checked, total: total)
        render()
    }

    /// A machine answering lights its own place on the dial and takes its row at once, so the list
    /// grows while the scan is still out rather than appearing all at once at the end.
    private func light(_ candidate: ForgeCandidate) {
        reading.found(candidate, at: TailnetRadarView.now)
        found = reading.found
        Theme.Haptics.step()
        render()
    }

    private func render() {
        radar.show(blips: reading.blips, scanning: reading.isScanning)
        titleLabel.attributedText = NSAttributedString(
            string: headline,
            attributes: Theme.Ramp.attributes(.panelTitle, color: ink ?? Theme.Color.label))
        titleLabel.isHidden = headline.isEmpty
        detailLabel.attributedText = NSAttributedString(
            string: detail,
            attributes: Theme.Ramp.attributes(
                .panelDetail, color: ink ?? Theme.Color.secondaryLabel))
        action.isHidden = actionTitle == nil
        action.setTitle(actionTitle ?? "")
        action.setLoading(reading.isScanning)
        var snapshot = NSDiffableDataSourceSnapshot<Int, ForgeCandidate>()
        snapshot.appendSections([0])
        snapshot.appendItems(found, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    /// What the screen is called right now. A scan nobody has started needs no heading — the
    /// navigation bar already carries Core's own — but a scan that cannot start does: the state it
    /// is in is the whole of what the screen is about.
    private var headline: String {
        switch gate {
        case .needsKey(let rejected): return Self.key(rejected).title
        case .ready, .trouble: return reading.stage == .rest ? "" : reading.title
        }
    }

    /// What the screen is saying under that: Core's own line for the scan, or Core's line for the
    /// key when a key is what the scan is waiting on.
    private var detail: String {
        switch gate {
        case .ready: return reading.detail
        case .needsKey(let rejected): return Self.key(rejected).detail
        case .trouble(let words): return words
        }
    }

    /// The key as the screen has it: never given, or given and refused. Both sentences are Core's,
    /// because a phone needing a key to list a tailnet is the renderer scan's own condition rather
    /// than this screen's opinion.
    private static func key(_ rejected: Bool) -> ForgeSweepKey {
        rejected ? .rejected : .missing
    }

    /// Colour is spent on the two things worth interrupting a reader for — nothing answered, and
    /// the scan could not run — and on nothing else. A count of machines asked is progress, and
    /// progress painted green reads as a result that has not happened yet.
    private var ink: UIColor? {
        if case .trouble = gate { return Theme.Color.danger }
        if case .needsKey(let rejected) = gate { return Self.key(rejected).tone.color }
        switch reading.tone {
        case .attention, .danger: return reading.tone.color
        case .live, .quiet: return nil
        }
    }

    private var actionTitle: String? {
        switch gate {
        case .needsKey(let rejected): return Self.key(rejected).actionTitle
        case .ready: return reading.actionTitle
        case .trouble: return ForgeSweepReading().actionTitle
        }
    }

    /// What a failed listing leaves the screen in. A key Tailscale would not accept is not a scan
    /// that failed — scanning again with the same key fails identically for as long as the app is
    /// up — so it lands on the key rather than on the dial.
    private static func gate(for error: Error) -> Gate {
        guard let agent = error as? AgentError, case .http(let status, _) = agent,
            status == 401 || status == 403
        else { return .trouble(String(localized: "Scan failed: \(error.localizedDescription)")) }
        return .needsKey(rejected: true)
    }
}

extension ForgeSweepViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let candidate = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.tap()
        onAdopt?(candidate)
        dismiss(animated: true)
    }
}

#if DEBUG
    extension ForgeSweepViewController {
        /// A tailnet with nothing on the other end, so the dial turning, the count and the rows a
        /// scan produces can all be photographed on a simulator. `TAILSCODE_FORGE_SWEEP=staged`
        /// names it, and it is the only way any of this reaches the screen without a real token
        /// and a real machine answering on the port.
        nonisolated static var stagedDevices: [TailscaleDevice]? {
            guard ProcessInfo.processInfo.environment["TAILSCODE_FORGE_SWEEP"] == "staged" else {
                return nil
            }
            return [
                TailscaleDevice(
                    name: "arch.tail1234.ts.net", hostname: "arch", addresses: ["100.64.0.3"],
                    os: "linux"),
                TailscaleDevice(
                    name: "studio.tail1234.ts.net", hostname: "studio", addresses: ["100.64.0.5"],
                    os: "macOS"),
                TailscaleDevice(
                    name: "nas.tail1234.ts.net", hostname: "nas", addresses: ["100.64.0.7"],
                    os: "linux"),
                TailscaleDevice(
                    name: "thinkpad.tail1234.ts.net", hostname: "thinkpad",
                    addresses: ["100.64.0.9"], os: "linux"),
                TailscaleDevice(
                    name: "phone.tail1234.ts.net", hostname: "phone", addresses: ["100.64.0.2"],
                    os: "iOS"),
            ]
        }

        /// One machine answers and the rest do not, at a pace a person would actually watch.
        nonisolated static let stagedProbe: ForgeSweep.Probe = { host, _ in
            try? await Task.sleep(for: .milliseconds(host == "arch.tail1234.ts.net" ? 700 : 1600))
            return host.hasPrefix("arch") ? .listening : .timedOut
        }
    }
#endif
