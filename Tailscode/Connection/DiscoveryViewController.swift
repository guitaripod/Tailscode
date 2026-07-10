import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class DiscoveryViewController: UIViewController {
    var onConnected: (() -> Void)?

    private let keychain = KeychainSecretStore()
    private let tokenKey = "tailscale.token"

    private var apiToken: String { (try? keychain.value(for: tokenKey)) ?? "" }

    private var hasCreds: Bool { !apiToken.isEmpty }

    private let statusLabel = UILabel()
    private let scanButton = PrimaryButton(title: "Scan tailnet")
    private let configureButton = PrimaryButton(title: "Set up tailnet access")
    private let resultsHeader = UILabel()
    private let resultsContainer = UIView()
    private let emptyLabel = UILabel()
    private let scanActivity = UIActivityIndicatorView(style: .medium)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ListItem>!
    private var suggestions: [TailnetScanner.Suggestion] = []
    private var devices: [TailscaleDevice] = []
    private var resultsHeightConstraint: NSLayoutConstraint?
    private var lastDeviceCount: Int?
    private var didAutoScan = false

    private enum Section: Int, CaseIterable { case servers, devices }
    private enum ListItem: Hashable {
        case server(SuggestionItem)
        case device(DeviceItem)
    }
    private struct SuggestionItem: Hashable {
        let suggestion: TailnetScanner.Suggestion
    }
    private struct DeviceItem: Hashable {
        let device: TailscaleDevice
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Discover"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        buildUI()
        refreshState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasCreds {
            presentCredentialForm()
            return
        }
        if suggestions.isEmpty && !didAutoScan {
            didAutoScan = true
            scanTapped()
        }
    }

    private func buildUI() {
        let header = UILabel()
        header.text = "Uses the Tailscale API to list your devices, then checks which ones are running supported coding agent servers."
        header.font = Theme.Font.subheadline()
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        statusLabel.font = Theme.Font.caption()
        statusLabel.numberOfLines = 0
        statusLabel.textColor = Theme.Color.secondaryLabel

        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        configureButton.addTarget(self, action: #selector(configureTapped), for: .touchUpInside)

        resultsHeader.font = Theme.Font.caption()
        resultsHeader.textColor = Theme.Color.secondaryLabel
        resultsHeader.isHidden = true

        emptyLabel.font = Theme.Font.subheadline()
        emptyLabel.textColor = Theme.Color.secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true

        scanActivity.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [header, statusLabel, configureButton, scanButton, scanActivity, resultsHeader, resultsContainer, emptyLabel])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])

        configureResultsList()
    }

    private func configureResultsList() {
        let config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInset = .zero
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self

        let suggestionCell = UICollectionView.CellRegistration<UICollectionViewListCell, SuggestionItem> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            content.text = item.suggestion.recommendedProfileName
            var secondary = item.suggestion.backend.displayName
            if let v = item.suggestion.version {
                secondary += " \(v)"
            }
            if let os = item.suggestion.os {
                secondary += " · \(os)"
            }
            if item.suggestion.requiresAuth {
                secondary += " · needs password"
            }
            content.secondaryText = secondary
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: item.suggestion.backend == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right")
            content.imageProperties.tintColor = item.suggestion.requiresAuth ? Theme.Color.danger : Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let deviceCell = UICollectionView.CellRegistration<UICollectionViewListCell, DeviceItem> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            let label = { () -> String in
                if !item.device.hostname.isEmpty { return item.device.hostname }
                if let n = item.device.name, !n.isEmpty { return n }
                return item.device.addresses.first ?? "Unknown"
            }()
            content.text = label
            var parts: [String] = []
            if !item.device.hostname.isEmpty, let n = item.device.name, !n.isEmpty, n != item.device.hostname {
                parts.append(n)
            }
            if let os = item.device.os { parts.append(os) }
            if let user = item.device.user, !user.isEmpty { parts.append(user) }
            if let lastSeen = item.device.lastSeen { parts.append(lastSeen) }
            if !item.device.addresses.isEmpty {
                parts.append(item.device.addresses.prefix(2).joined(separator: ", "))
            }
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "desktopcomputer")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, item in
            switch item {
            case .server(let s):
                return cv.dequeueConfiguredReusableCell(using: suggestionCell, for: ip, item: s)
            case .device(let d):
                return cv.dequeueConfiguredReusableCell(using: deviceCell, for: ip, item: d)
            }
        }

        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        resultsHeightConstraint = collectionView.heightAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
            resultsHeightConstraint!,
        ])
        resultsContainer.isHidden = true
    }

    private func refreshState() {
        if hasCreds {
            if suggestions.isEmpty && devices.isEmpty {
                statusLabel.text = "Tap Scan to discover servers on your tailnet."
            }
            configureButton.configuration?.title = "Update token"
            scanButton.isHidden = false
        } else {
            statusLabel.text = "Add a Tailscale API access token to discover servers."
            configureButton.configuration?.title = "Add access token"
            scanButton.isHidden = true
        }
        let hasResults = !suggestions.isEmpty || (!devices.isEmpty && suggestions.isEmpty)
        resultsContainer.isHidden = !hasResults
        resultsHeader.isHidden = !hasResults
        if !hasResults && lastDeviceCount == nil {
            emptyLabel.isHidden = true
        }
    }

    @objc private func configureTapped() {
        presentCredentialForm()
    }

    private func presentCredentialForm() {
        let formVC = UIViewController()
        formVC.title = "Tailscale Token"
        formVC.view.backgroundColor = Theme.Color.groupedBackground

        let header = UILabel()
        header.text = "Generate an API access token (Devices read) on the Tailscale keys page. One paste is all you need."
        header.font = Theme.Font.subheadline()
        header.textColor = Theme.Color.secondaryLabel
        header.numberOfLines = 0

        let tokenField = FormField(title: "API access token", placeholder: "tskey-api-...", secure: true)
        tokenField.setText(apiToken)

        let openButton = UIButton(type: .system)
        openButton.setTitle("Open Keys page to generate token", for: .normal)
        openButton.titleLabel?.font = Theme.Font.caption()
        openButton.addAction(UIAction { _ in
            if let url = URL(string: "https://login.tailscale.com/admin/settings/keys") {
                UIApplication.shared.open(url)
            }
        }, for: .touchUpInside)

        let note = UILabel()
        note.text = "Stored only in the keychain. Used solely to list your Tailscale devices."
        note.font = Theme.Font.caption()
        note.textColor = Theme.Color.tertiaryLabel
        note.numberOfLines = 0

        let saveButton = PrimaryButton(title: "Save")
        saveButton.addAction(UIAction { [weak self, weak formVC] _ in
            guard let self else { return }
            let token = tokenField.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                do {
                    try self.keychain.setValue(token, for: self.tokenKey)
                } catch {
                    Theme.Haptics.error()
                    let alert = UIAlertController(
                        title: "Couldn't save token",
                        message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    formVC?.present(alert, animated: true)
                    return
                }
                AppLogger.connection.info("tailscale token saved")
                self.refreshState()
                if self.suggestions.isEmpty {
                    self.scanTapped()
                }
            }
            formVC?.dismiss(animated: true)
        }, for: .touchUpInside)

        let clearButton = UIButton(type: .system)
        clearButton.setTitle("Clear token", for: .normal)
        clearButton.setTitleColor(Theme.Color.danger, for: .normal)
        clearButton.addAction(UIAction { [weak self, weak formVC] _ in
            guard let self else { return }
            try? self.keychain.removeValue(for: self.tokenKey)
            AppLogger.connection.info("tailscale token cleared")
            self.refreshState()
            formVC?.dismiss(animated: true)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [header, openButton, tokenField, note, saveButton, clearButton])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        formVC.view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: formVC.view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: formVC.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: formVC.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: formVC.view.keyboardLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: formVC.view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: formVC.view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.widthAnchor.constraint(equalTo: formVC.view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])

        let nav = UINavigationController(rootViewController: formVC)
        formVC.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissForm))
        present(nav, animated: true)
    }

    private var scanTask: Task<Void, Never>?

    @objc private func scanTapped() {
        guard hasCreds, scanTask == nil else { return }
        scanButton.setLoading(true)
        scanActivity.startAnimating()
        statusLabel.text = "Fetching devices and probing servers…"
        lastDeviceCount = nil
        devices = []
        suggestions = []
        emptyLabel.isHidden = true
        applyResultsSnapshot()
        resultsContainer.isHidden = false

        scanTask = Task {
            defer { scanTask = nil }
            do {
                let client = TailscaleClient()
                let fetched = try await client.fetchDevices(with: apiToken)
                guard !Task.isCancelled else { return }
                AppLogger.connection.info("fetched \(fetched.count) tailscale devices")
                lastDeviceCount = fetched.count
                devices = fetched
                AppLogger.connection.info("stored \(devices.count) devices for fallback; first hostname=\(devices.first?.hostname ?? "nil") name=\(devices.first?.name ?? "nil")")
                statusLabel.text = "Checking \(fetched.count) devices…"
                let scanner = TailnetScanner()
                let found = await scanner.scan(devices: fetched)
                guard !Task.isCancelled else { return }
                suggestions = found.sorted { $0.recommendedProfileName < $1.recommendedProfileName }
                AppLogger.connection.info("scanner returned \(found.count) unique suggestions after dedup")
                let countText = found.isEmpty ? "No supported servers found" : "Found \(found.count) server(s)"
                statusLabel.text = lastDeviceCount.map { "Scanned \($0) devices. \(countText)" } ?? countText
            } catch let error as AgentError {
                if case .http(let status, _) = error, status == 401 || status == 403 {
                    statusLabel.text = "Invalid Tailscale token. Update it and try again."
                } else {
                    statusLabel.text = "Scan failed: \(error.localizedDescription)"
                }
                AppLogger.connection.error("tailnet scan failed: \(error.localizedDescription)")
                suggestions = []
            } catch {
                AppLogger.connection.error("tailnet scan failed: \(error.localizedDescription)")
                statusLabel.text = "Scan failed: \(error.localizedDescription)"
                suggestions = []
            }
            scanButton.setLoading(false)
            scanActivity.stopAnimating()
            scanButton.setTitle("Scan again")
            applyResultsSnapshot()
            refreshState()
        }
    }

    private func applyResultsSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()
        snapshot.appendSections([.servers, .devices])
        snapshot.appendItems(suggestions.map { .server(SuggestionItem(suggestion: $0)) }, toSection: .servers)
        let showDeviceFallback = suggestions.isEmpty && !devices.isEmpty
        if showDeviceFallback {
            AppLogger.connection.info("showing device fallback: \(devices.count) devices")
            snapshot.appendItems(devices.map { .device(DeviceItem(device: $0)) }, toSection: .devices)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        collectionView.layoutIfNeeded()
        let h = max(collectionView.contentSize.height, 44)
        resultsHeightConstraint?.constant = min(h, 420)
        view.layoutIfNeeded()

        if !suggestions.isEmpty {
            let count = lastDeviceCount ?? suggestions.count
            resultsHeader.text = "Scanned \(count) devices, \(suggestions.count) servers found"
            resultsHeader.isHidden = false
            emptyLabel.isHidden = true
        } else if showDeviceFallback {
            resultsHeader.text = "No servers detected. Tap a device to connect manually:"
            resultsHeader.isHidden = false
            emptyLabel.isHidden = true
        } else if let count = lastDeviceCount {
            resultsHeader.isHidden = true
            emptyLabel.text = "Scanned \(count) devices.\nNo opencode or Claude Code servers found.\nMake sure the servers are running and listening on ports 4096/4098."
            emptyLabel.isHidden = false
        } else {
            resultsHeader.isHidden = true
            emptyLabel.isHidden = true
        }
    }

    private func selectSuggestion(_ s: TailnetScanner.Suggestion) {
        if s.requiresAuth {
            promptForPassword(for: s)
        } else {
            connect(with: s, password: nil)
        }
    }

    private func promptForPassword(for s: TailnetScanner.Suggestion) {
        let alert = UIAlertController(title: "Password for \(s.baseURL.host ?? "")", message: "This server requires authentication.", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Password"
            tf.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            let pw = alert.textFields?.first?.text?.isEmpty == false ? alert.textFields?.first?.text : nil
            self?.connect(with: s, password: pw)
        })
        present(alert, animated: true)
    }

    /// Verifies the credentials with a live probe before saving — a mistyped
    /// password must fail here, not as a wall of generic errors later.
    private func connect(with suggestion: TailnetScanner.Suggestion, password: String?) {
        view.endEditing(true)
        statusLabel.text = "Verifying \(suggestion.baseURL.host ?? "server")…"
        Task {
            let username = suggestion.backend == .openCode ? "opencode" : "claude"
            let credentials = password.map { BasicCredentials(username: username, password: $0) }
            let outcome = await ConnectionProbe().probe(
                baseURL: suggestion.baseURL, credentials: credentials,
                policy: ConnectionPolicy(requestTimeout: .seconds(10), resourceTimeout: .seconds(15)))
            switch outcome {
            case .ok, .notAnAgentServer:
                saveVerified(suggestion, password: password)
            case .authFailed:
                Theme.Haptics.error()
                statusLabel.text = "Wrong password for \(suggestion.baseURL.host ?? "server")."
                promptForPassword(for: suggestion)
            case .unreachable(let detail):
                Theme.Haptics.error()
                statusLabel.text = "Unreachable: \(detail)"
            }
        }
    }

    private func saveVerified(_ suggestion: TailnetScanner.Suggestion, password: String?) {
        let profName = suggestion.recommendedProfileName.isEmpty
            ? (suggestion.baseURL.host ?? "Server")
            : suggestion.recommendedProfileName
        let profile = ConnectionProfile(
            id: UUID().uuidString, name: profName, backend: suggestion.backend,
            baseURL: suggestion.baseURL)
        do {
            try ConnectionController.shared.save(profile, password: password)
            AppLogger.connection.info("connected via discovery to \(suggestion.backend.displayName)")
            Theme.Haptics.success()
            dismiss(animated: true) { [onConnected] in onConnected?() }
        } catch {
            statusLabel.text = "Save failed: \(error.localizedDescription)"
            Theme.Haptics.error()
        }
    }

    @objc private func done() {
        scanTask?.cancel()
        dismiss(animated: true)
    }

    @objc private func dismissForm() {
        presentedViewController?.dismiss(animated: true)
    }
}

extension DiscoveryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .server(let s):
            selectSuggestion(s.suggestion)
        case .device(let d):
            presentManualConnect(for: d.device)
        }
    }

    private func presentManualConnect(for device: TailscaleDevice) {
        let formVC = ManualConnectViewController(device: device, keychain: keychain, tokenKey: tokenKey)
        formVC.onConnected = { [weak self] in
            guard let self else { return }
            let root = self.presentingViewController
            root?.dismiss(animated: true) { self.onConnected?() }
        }
        let nav = UINavigationController(rootViewController: formVC)
        formVC.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissForm))
        present(nav, animated: true)
    }
}
