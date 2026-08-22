import TailscodeCore
import UIKit

/// Where the renderer lives, typed once.
///
/// The whole configuration is an address — there is no account, no key and no project — so the
/// screen is one field and the two questions worth asking about it: can this be read as a machine
/// at all, and is anything listening there. Both answers are Core's sentences; nothing here invents
/// a word for a failure, and a machine that is merely asleep is still saved, because an address
/// that will be right at nine in the morning is not a mistake.
@MainActor
final class ForgeEndpointViewController: UIViewController {
    var onFinish: (() -> Void)?

    private let runner = ForgeRunner.shared
    private let field = FormField(
        title: ForgeField.endpoint.label, placeholder: "100.x.y.z:8188", keyboard: .URL,
        returnKey: .done)
    private let explain = UILabel()
    private let status = UILabel()
    private let dock = Theme.Glass.view()
    private let save = PrimaryButton(title: String(localized: "Use this renderer"))
    private let check = SecondaryButton(title: String(localized: "Check"))
    private let remove = UIButton(type: .system)
    private var probe: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ForgeField.endpoint.label
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        buildUI()
        field.setText(runner.endpoint?.displayHost ?? "")
        field.textField.addAction(
            UIAction { [weak self] _ in self?.readingChanged() }, for: .editingChanged)
        field.onSubmit = { [weak self] in self?.saveTapped() }
        save.addAction(UIAction { [weak self] _ in self?.saveTapped() }, for: .touchUpInside)
        check.addAction(UIAction { [weak self] _ in self?.checkTapped() }, for: .touchUpInside)
        remove.addAction(UIAction { [weak self] _ in self?.removeTapped() }, for: .touchUpInside)
        readingChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.textField.becomeFirstResponder()
    }

    private func buildUI() {
        explain.attributedText = NSAttributedString(
            string: ForgeFailure.unconfigured.description,
            attributes: Theme.Ramp.attributes(.panelDetail, color: Theme.Color.secondaryLabel))
        explain.numberOfLines = 0
        status.numberOfLines = 0
        remove.setTitle(String(localized: "Forget this renderer"), for: .normal)
        remove.setTitleColor(Theme.Color.danger, for: .normal)
        remove.titleLabel?.font = Theme.Ramp.font(.control)
        remove.isHidden = runner.endpoint == nil

        check.configuration?.buttonSize = .medium
        let checkRow = UIStackView(arrangedSubviews: [check, UIView()])
        checkRow.axis = .horizontal
        let column = UIStackView(arrangedSubviews: [explain, field, status, checkRow, remove])
        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        column.alignment = .fill
        column.setCustomSpacing(Theme.Spacing.s, after: field)
        column.setCustomSpacing(Theme.Spacing.xl, after: checkRow)
        column.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        dock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dock)
        dock.contentView.addSubview(save)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: dock.topAnchor),
            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            save.topAnchor.constraint(equalTo: dock.contentView.topAnchor, constant: Theme.Spacing.s),
            save.bottomAnchor.constraint(
                equalTo: dock.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            save.leadingAnchor.constraint(
                equalTo: dock.contentView.leadingAnchor, constant: Theme.Spacing.l),
            save.trailingAnchor.constraint(
                equalTo: dock.contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private var reading: ForgeEndpoint.Reading {
        ForgeEndpoint.read(field.text)
    }

    /// What is in the box, judged as it is typed. A complaint is shown the moment the reading stops
    /// being an address rather than held back until somebody presses the button.
    private func readingChanged() {
        let reading = reading
        show(ForgeEndpoint.complaint(reading), wrong: true)
        switch reading {
        case .endpoint:
            save.isEnabled = true
            check.isEnabled = true
        case .empty, .bindAll, .unsupportedScheme, .invalid:
            save.isEnabled = false
            check.isEnabled = false
        }
    }

    private func saveTapped() {
        guard case .endpoint(let endpoint) = reading else { return }
        view.endEditing(true)
        runner.point(at: endpoint)
        Theme.Haptics.success()
        onFinish?()
        dismiss(animated: true)
    }

    /// Asks the port directly rather than making a request: the box is socket-activated, so
    /// something listening is the only thing that can be known cheaply, and the first render pays
    /// for the rest either way.
    private func checkTapped() {
        guard case .endpoint(let endpoint) = reading else { return }
        view.endEditing(true)
        probe?.cancel()
        check.setLoading(true)
        show(Localized.text("Checking…"), wrong: false)
        probe = Task { [weak self] in
            let verdict = await endpoint.reach()
            guard let self, !Task.isCancelled else { return }
            self.check.setLoading(false)
            self.show(
                ForgeEndpoint.sentence(for: verdict, host: endpoint.host),
                wrong: verdict != .listening)
        }
    }

    private func removeTapped() {
        runner.point(at: nil)
        Theme.Haptics.warning()
        onFinish?()
        dismiss(animated: true)
    }

    private func show(_ words: String?, wrong: Bool) {
        status.isHidden = words == nil
        status.attributedText = NSAttributedString(
            string: words ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote,
                color: wrong ? Theme.Color.danger : Theme.Color.secondaryLabel))
    }
}
