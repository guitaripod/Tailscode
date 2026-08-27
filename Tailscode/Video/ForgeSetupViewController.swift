import TailscodeCore
import UIKit

/// Pointing the app at the machine that makes videos, held to the standard adding a server is held
/// to.
///
/// Every word, every rule and every button on this screen is `ForgeSetup`'s: what this phone's own
/// tailnet address is, what the typed line will be used as, whether anything answered there, why it
/// did not and the one tap that fixes it, whether a machine that said nothing may be saved anyway,
/// and which machines this phone has used before. The controller owns two text fields, a list and a
/// dock, and decides nothing.
@MainActor
final class ForgeSetupViewController: UIViewController {
    private let runner = ForgeRunner.shared
    private var setup: ForgeSetup

    private let intro = UILabel()
    private let tailnetIcon = UIImageView()
    private let tailnetLabel = UILabel()
    private let discover = UIButton(type: .system)
    private let discoverNote = UILabel()
    private let discoverBlock = DiagnosisCardView()
    private let knownTitle = UILabel()
    private let knownEmpty = UILabel()
    private let knownStack = UIStackView()
    private let address = FormField(
        title: ForgeSetup.addressLabel, placeholder: ForgeSetup.addressPlaceholder, keyboard: .URL,
        returnKey: .continue)
    private let addressHelp = UILabel()
    private let hint = UILabel()
    private let name = FormField(title: ForgeSetup.nameLabel, placeholder: "", returnKey: .done)
    private let statusTitle = UILabel()
    private let statusDetail = UILabel()
    private let diagnosisCard = DiagnosisCardView()
    private let secondary = SecondaryButton(title: "")
    private let secondaryNote = UILabel()
    private let dock = Theme.Glass.view()
    private let primary = PrimaryButton(title: "")
    private let scroll = UIScrollView()
    /// The failure already on screen, so a redraw does not yank the scroll under a reader who has
    /// gone looking for the address bar.
    private var shownDiagnosis: ConnectDiagnosis?
    /// The reason the scan cannot run, already on screen. The card announces itself to VoiceOver
    /// every time it is shown, and a keystroke is not news.
    private var shownBlock: ConnectDiagnosis?
    private var check: Task<Void, Never>?

    init() {
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            tailnet: TailnetStatus.reading, deviceName: DeviceWord.thisDevice)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ForgeSetup.title
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        buildUI()
        wire()
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Coming back from Tailscale is the one thing that changes the answer this screen was built
    /// with, and it is exactly what the blocked scan's own button sends people to do — so the
    /// tailnet is asked again rather than left saying what was true when the screen opened.
    @objc private func didBecomeActive() {
        setup.tailnet = TailnetStatus.reading
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            switch ProcessInfo.processInfo.environment["TAILSCODE_VIDEO_OPEN"] {
            case "sweep": sweep()
            case "check": perform(setup.primary.action)
            default: break
            }
        #endif
    }

    // MARK: - Building

    private func buildUI() {
        intro.numberOfLines = 0
        addressHelp.numberOfLines = 0
        hint.numberOfLines = 0
        discoverNote.numberOfLines = 0
        knownEmpty.numberOfLines = 0
        statusTitle.numberOfLines = 0
        statusDetail.numberOfLines = 0
        secondaryNote.numberOfLines = 0
        tailnetLabel.numberOfLines = 0
        tailnetIcon.contentMode = .center
        tailnetIcon.setContentHuggingPriority(.required, for: .horizontal)

        configureKnownStack()

        let tailnetRow = UIStackView(arrangedSubviews: [tailnetIcon, tailnetLabel])
        tailnetRow.axis = .horizontal
        tailnetRow.alignment = .firstBaseline
        tailnetRow.spacing = Theme.Spacing.s

        let column = UIStackView(arrangedSubviews: [
            intro, tailnetRow, discover, discoverNote, discoverBlock, knownTitle, knownEmpty,
            knownStack, address, addressHelp, hint, name, statusTitle, statusDetail, diagnosisCard,
            secondary, secondaryNote,
        ])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.alignment = .fill
        column.setCustomSpacing(Theme.Spacing.l, after: tailnetRow)
        column.setCustomSpacing(Theme.Spacing.xs, after: discover)
        column.setCustomSpacing(Theme.Spacing.l, after: discoverNote)
        column.setCustomSpacing(Theme.Spacing.l, after: discoverBlock)
        column.setCustomSpacing(Theme.Spacing.xs, after: knownTitle)
        column.setCustomSpacing(Theme.Spacing.l, after: knownStack)
        column.setCustomSpacing(Theme.Spacing.xs, after: address)
        column.setCustomSpacing(Theme.Spacing.xs, after: addressHelp)
        column.setCustomSpacing(Theme.Spacing.l, after: hint)
        column.setCustomSpacing(Theme.Spacing.l, after: name)
        column.setCustomSpacing(Theme.Spacing.xs, after: statusTitle)
        column.setCustomSpacing(Theme.Spacing.xs, after: secondary)
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        dock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dock)
        dock.contentView.addSubview(primary)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: dock.topAnchor),
            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            column.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            primary.topAnchor.constraint(
                equalTo: dock.contentView.topAnchor, constant: Theme.Spacing.s),
            primary.bottomAnchor.constraint(
                equalTo: dock.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            primary.leadingAnchor.constraint(
                equalTo: dock.contentView.leadingAnchor, constant: Theme.Spacing.l),
            primary.trailingAnchor.constraint(
                equalTo: dock.contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    /// The machines this phone has already pointed at, as rows rather than a paragraph: one tap
    /// puts a known address back in the field, and the mark beside it stops it being offered again.
    private func configureKnownStack() {
        knownStack.axis = .vertical
        knownStack.spacing = Theme.Spacing.xs
        knownStack.alignment = .fill
    }

    private func wire() {
        address.textField.addAction(
            UIAction { [weak self] _ in self?.addressChanged() }, for: .editingChanged)
        address.onSubmit = { [weak self] in self?.name.textField.becomeFirstResponder() }
        name.textField.addAction(
            UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        name.onSubmit = { [weak self] in self?.primaryTapped() }
        primary.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)
        secondary.addAction(
            UIAction { [weak self] _ in self?.secondaryTapped() }, for: .touchUpInside)
        discover.translatesAutoresizingMaskIntoConstraints = false
        discover.addAction(
            UIAction { [weak self] _ in self?.discoverTapped() }, for: .touchUpInside)
        diagnosisCard.onAction = { [weak self] in self?.diagnosisActionTapped() }
        discoverBlock.onAction = { [weak self] in self?.discoverBlockTapped() }
    }

    // MARK: - Editing

    private func addressChanged() {
        setup.type(address.text)
        render()
    }

    private func nameChanged() {
        setup.rename(name.text)
        render()
    }

    private func primaryTapped() {
        Theme.Haptics.tap()
        perform(setup.primary.action)
    }

    private func secondaryTapped() {
        Theme.Haptics.tap()
        guard let action = setup.secondary?.action else { return }
        perform(action)
    }

    private func discoverTapped() {
        Theme.Haptics.tap()
        perform(setup.discovery.action)
    }

    private func perform(_ action: ForgeSetupAction) {
        switch action {
        case .nothing:
            return
        case .check(let endpoint):
            ask(endpoint)
        case .save(let renderer):
            save(renderer)
        case .scan:
            sweep()
        case .fix(let fix):
            apply(fix)
        }
    }

    /// Asks the port directly rather than making a request: ComfyUI is socket-activated, so
    /// something listening is the only thing that can be known cheaply, and the first render pays
    /// for the rest either way.
    private func ask(_ endpoint: ForgeEndpoint) {
        view.endEditing(true)
        check?.cancel()
        setup.checking()
        render()
        check = Task { [weak self] in
            let verdict = await endpoint.reach()
            guard let self, !Task.isCancelled else { return }
            self.setup.reached(verdict)
            Theme.Haptics.received()
            self.render()
        }
    }

    private func save(_ renderer: ForgeRenderer) {
        view.endEditing(true)
        runner.use(renderer)
        Theme.Haptics.success()
        dismiss(animated: true)
    }

    private func sweep() {
        view.endEditing(true)
        let scan = ForgeSweepViewController(current: setup.current)
        scan.onAdopt = { [weak self] candidate in self?.adopt(candidate) }
        present(UINavigationController(rootViewController: scan), animated: true)
    }

    /// A machine a scan found answered the same question the button asks, so it arrives already
    /// checked — the form only has to show what was found and offer to keep it.
    private func adopt(_ candidate: ForgeCandidate) {
        setup.adopt(candidate)
        Theme.Haptics.selection()
        render()
        UIAccessibility.post(notification: .announcement, argument: setup.status.title)
    }

    /// Forgetting the machine in force stops renders going anywhere at all, so it is asked rather
    /// than done — the words are Core's, and the way out is the platform's own.
    private func confirmForget(_ renderer: ForgeRenderer) {
        let sheet = UIAlertController(
            title: ForgeSetup.forgetTitle, message: renderer.detail, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: ForgeSetup.forgetTitle, style: .destructive) { [weak self] _ in
                self?.forget(renderer)
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func forget(_ renderer: ForgeRenderer) {
        runner.forgetRenderer(renderer.id)
        setup = ForgeSetup(
            current: ForgeStore.endpoint(), known: ForgeStore.renderers(),
            tailnet: TailnetStatus.reading, deviceName: DeviceWord.thisDevice)
        setup.type(address.text)
        setup.rename(name.text)
        Theme.Haptics.warning()
        render()
    }

    private func use(_ renderer: ForgeRenderer) {
        setup.type(renderer.endpoint.displayHost)
        setup.rename(renderer.name ?? "")
        Theme.Haptics.selection()
        render()
    }

    private func apply(_ fix: ConnectDiagnosis.Fix) {
        switch fix {
        case .openTailscale:
            TailnetStatus.openTailscaleApp()
        case .openAppSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .retry:
            perform(setup.primary.action)
        case .copyCommand(let command):
            UIPasteboard.general.string = command
            Theme.Haptics.success()
            ToastView(message: command).flash(in: view, above: dock.topAnchor, duration: 3)
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            address.setText(url.absoluteString)
            addressChanged()
            perform(setup.primary.action)
        case .revealPassword, .seePro, .none:
            return
        }
    }

    private func diagnosisActionTapped() {
        guard let fix = setup.status.diagnosis?.fix else { return }
        Theme.Haptics.tap()
        apply(fix)
    }

    private func discoverBlockTapped() {
        guard let fix = setup.discoveryBlock?.fix else { return }
        Theme.Haptics.tap()
        apply(fix)
    }

    // MARK: - Drawing

    private func render() {
        renderIntro()
        renderDiscovery()
        renderKnown()
        renderFields()
        renderStatus()
        renderButtons()
    }

    private func renderIntro() {
        intro.attributedText = NSAttributedString(
            string: ForgeSetup.detail,
            attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.secondaryLabel))
        let up = setup.tailnet?.isUp ?? false
        tailnetIcon.image = UIImage(
            systemName: up ? "wifi" : "wifi.exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        tailnetIcon.tintColor = up ? Theme.Color.success : Theme.Color.warning
        tailnetLabel.attributedText = NSAttributedString(
            string: setup.tailnetLine,
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: up ? Theme.Color.secondaryLabel : Theme.Color.warning))
    }

    /// Typing an address is the fallback, so the scan wears the prominence for as long as there is
    /// nothing to check — which is exactly the state somebody opening this screen the first time is
    /// in. Once a line is in the field the dock's button is the one to press, and this steps back.
    /// A scan that cannot run never wears it: prominence on a dead control invites a press that
    /// does nothing.
    private var leadsWithDiscovery: Bool { !setup.primary.isEnabled && setup.discovery.isEnabled }

    private func renderDiscovery() {
        var config = Theme.Glass.buttonConfiguration(prominent: leadsWithDiscovery)
        config.title = setup.discovery.title
        config.image = UIImage(systemName: "dot.radiowaves.left.and.right")
        config.imagePadding = Theme.Spacing.s
        config.cornerStyle = .large
        config.buttonSize = .large
        if !leadsWithDiscovery { config.baseForegroundColor = Theme.Color.label }
        discover.configuration = config
        discover.isEnabled = setup.discovery.isEnabled
        discoverNote.attributedText = NSAttributedString(
            string: ForgeSweepReading().detail,
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
        renderDiscoveryBlock()
    }

    /// A scan this device cannot run says why and offers the press that would let it, in place of
    /// the line about what scanning does — which, over a greyed-out button, states neither the
    /// reason nor a way out.
    private func renderDiscoveryBlock() {
        guard let block = setup.discoveryBlock else {
            discoverNote.isHidden = false
            discoverBlock.hide()
            shownBlock = nil
            return
        }
        discoverNote.isHidden = true
        guard shownBlock != block else { return }
        shownBlock = block
        discoverBlock.show(block)
    }

    private func renderKnown() {
        knownTitle.attributedText = NSAttributedString(
            string: ForgeSetup.knownTitle,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        knownEmpty.attributedText = NSAttributedString(
            string: ForgeSetup.knownEmpty,
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
        knownEmpty.isHidden = !setup.known.isEmpty
        knownStack.isHidden = setup.known.isEmpty
        knownStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for renderer in setup.known {
            let row = ForgeRendererRow(renderer: renderer, current: setup.isCurrent(renderer))
            row.onUse = { [weak self] in self?.use(renderer) }
            row.onForget = { [weak self] in self?.confirmForget(renderer) }
            knownStack.addArrangedSubview(row)
        }
    }

    private func renderFields() {
        if address.text != setup.typed { address.setText(setup.typed) }
        if name.text != setup.name { name.setText(setup.name) }
        addressHelp.attributedText = NSAttributedString(
            string: ForgeSetup.addressHelp,
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
        let line = setup.hint
        hint.isHidden = line == nil
        hint.attributedText = NSAttributedString(
            string: line ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote,
                color: setup.endpoint == nil ? Theme.Color.warning : Theme.Color.secondaryLabel))
    }

    private func renderStatus() {
        let status = setup.status
        statusTitle.attributedText = NSAttributedString(
            string: status.title,
            attributes: Theme.Ramp.attributes(.panelLabel, color: status.tone.color))
        statusTitle.isHidden = status.title.isEmpty
        statusDetail.attributedText = NSAttributedString(
            string: status.detail,
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.secondaryLabel))
        statusDetail.isHidden = status.detail.isEmpty
        guard let diagnosis = status.diagnosis else {
            diagnosisCard.hide()
            shownDiagnosis = nil
            return
        }
        statusTitle.isHidden = true
        statusDetail.isHidden = true
        diagnosisCard.show(carded(diagnosis), tint: Theme.Color.danger)
        guard shownDiagnosis != diagnosis else { return }
        shownDiagnosis = diagnosis
        scrollIntoView(diagnosisCard)
    }

    /// The card does not repeat the dock. When a failure's own remedy is the press the button at
    /// the foot already offers, the card states what is wrong and lets that button carry the act.
    private func carded(_ diagnosis: ConnectDiagnosis) -> ConnectDiagnosis {
        guard diagnosis.actionTitle == setup.primary.title else { return diagnosis }
        return ConnectDiagnosis(
            symbol: diagnosis.symbol, title: diagnosis.title, detail: diagnosis.detail,
            fix: diagnosis.fix, actionTitle: nil)
    }

    private func renderButtons() {
        primary.setTitle(setup.primary.title)
        primary.setLoading(setup.status.stage == .checking)
        primary.isEnabled = setup.primary.isEnabled
        secondary.isHidden = setup.secondary == nil
        secondary.setTitle(setup.secondary?.title ?? "")
        secondaryNote.isHidden = setup.secondaryNote == nil
        secondaryNote.attributedText = NSAttributedString(
            string: setup.secondaryNote ?? "",
            attributes: Theme.Ramp.attributes(.panelFootnote, color: Theme.Color.tertiaryLabel))
    }

    /// A sentence the keyboard is covering is the same as no sentence, which is what a status line
    /// at the foot of a scroll amounts to on a phone.
    private func scrollIntoView(_ target: UIView) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            let frame = target.convert(target.bounds, to: self.scroll)
            self.scroll.scrollRectToVisible(
                frame.insetBy(dx: 0, dy: -Theme.Spacing.m), animated: true)
        }
    }
}

/// One machine this phone has rendered on, offered back.
///
/// A renderer is an address and a name and nothing else, so the row is the whole record: what the
/// tailnet calls it, where it answers, whether it is the one in force, and the one destructive act
/// there is — which is spelled out rather than hidden behind a swipe, because a list of two
/// machines is not a list anybody swipes through.
@MainActor
private final class ForgeRendererRow: UIControl {
    var onUse: (() -> Void)?
    var onForget: (() -> Void)?

    init(renderer: ForgeRenderer, current: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        addAction(UIAction { [weak self] _ in self?.onUse?() }, for: .touchUpInside)

        let icon = UIImageView(
            image: UIImage(
                systemName: "desktopcomputer",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)))
        icon.tintColor = current ? Theme.Color.success : Theme.Color.info
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.attributedText = NSAttributedString(
            string: renderer.title,
            attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
        let detail = UILabel()
        detail.attributedText = NSAttributedString(
            string: renderer.detail,
            attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel))
        let words = UIStackView(arrangedSubviews: [title, detail])
        words.axis = .vertical
        words.spacing = 1

        let badge = UILabel()
        badge.attributedText = NSAttributedString(
            string: ForgeRenderer.badge(current: current) ?? "",
            attributes: Theme.Ramp.attributes(.rowMeta, color: Theme.Color.success))
        badge.isHidden = !current
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let forget = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "trash",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        config.baseForegroundColor = Theme.Color.tertiaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.s, bottom: 0, trailing: 0)
        forget.configuration = config
        forget.accessibilityLabel = ForgeSetup.forgetTitle
        forget.setContentHuggingPriority(.required, for: .horizontal)
        forget.translatesAutoresizingMaskIntoConstraints = false
        forget.addAction(UIAction { [weak self] _ in self?.onForget?() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [icon, words, badge])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(forget)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: forget.leadingAnchor, constant: -Theme.Spacing.s),
            forget.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            forget.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [renderer.title, renderer.detail].joined(separator: ", ")
        accessibilityValue = ForgeRenderer.badge(current: current)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: ForgeSetup.forgetTitle) { [weak self] _ in
                self?.onForget?()
                return true
            }
        ]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
