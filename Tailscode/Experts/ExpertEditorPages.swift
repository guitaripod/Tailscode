import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// One part of an expert opened from the editor's front page: the editor fills it, and fills it
/// again whenever what it shows changes.
@MainActor
final class ExpertEditorPageViewController: UIViewController {
    private let rebuilds: Bool
    private let build: (UIStackView) -> Void
    private let closed: () -> Void
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private var built = false

    init(title: String, rebuilds: Bool, build: @escaping (UIStackView) -> Void, closed: @escaping () -> Void) {
        self.rebuilds = rebuilds
        self.build = build
        self.closed = closed
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        (scroll, column) = MachinePage.install(in: self)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        closed()
    }

    /// A page holding a text view being typed in is filled once, so the keyboard is never taken
    /// from under the person.
    func reload() {
        guard isViewLoaded, rebuilds || !built else { return }
        built = true
        let offset = scroll.contentOffset
        MachinePage.clear(column)
        build(column)
        view.layoutIfNeeded()
        scroll.contentOffset = offset
    }
}

/// One device or service on an expert's bench.
@MainActor
final class ExpertBenchEditorViewController: UIViewController {
    private var item: ExpertBenchItem
    private let canDelete: Bool
    private let done: (ExpertBenchItem?) -> Void
    private var scroll: UIScrollView!
    private var column: UIStackView!

    init(item: ExpertBenchItem, canDelete: Bool, done: @escaping (ExpertBenchItem?) -> Void) {
        self.item = item
        self.canDelete = canDelete
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name.isEmpty ? ExpertWords.addBenchItem : item.name
        (scroll, column) = MachinePage.install(in: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ExpertWords.save, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.finish() }, menu: nil)
        render()
    }

    private var canSave: Bool { !item.name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func syncSave() {
        navigationItem.rightBarButtonItem?.isEnabled = canSave
    }

    private func render() {
        MachinePage.clear(column)
        syncSave()
        let kinds: [ExpertBenchItem.Kind] = [.appleDevice, .command, .port]
        let kind = UISegmentedControl(items: [Localized.text("Device"), Localized.text("Probe"), Localized.text("Port")])
        kind.selectedSegmentIndex = kinds.firstIndex(of: item.kind) ?? 0
        kind.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl else { return }
            self.item.kind = kinds[control.selectedSegmentIndex]
            self.render()
        }, for: .valueChanged)
        var parts: [UIView] = [kind, field(Localized.text("Name"), item.name, "iPad Pro M1") { [weak self] in self?.item.name = $0 }]
        switch item.kind {
        case .appleDevice:
            parts.append(field(Localized.text("UDID, device identifier or name"), item.identifier ?? "", "00008103-…") {
                [weak self] in self?.item.identifier = $0.isEmpty ? nil : $0
            })
        case .command:
            parts.append(field(Localized.text("Command that exits 0 when it is there"), item.command ?? "", "pg_isready") {
                [weak self] in self?.item.command = $0
            })
        case .port:
            parts.append(field(Localized.text("Host"), item.host ?? "", "127.0.0.1") { [weak self] in
                self?.item.host = $0.isEmpty ? nil : $0
            })
            let port = field(Localized.text("Port"), item.port.map(String.init) ?? "", "8443") { [weak self] in
                self?.item.port = Int($0)
            }
            port.textField.keyboardType = .numberPad
            parts.append(port)
        }
        parts.append(field(Localized.text("Lock file (optional)"), item.lock ?? "", "/tmp/ipad.lock") { [weak self] in
            self?.item.lock = $0.isEmpty ? nil : $0
        })
        let stack = UIStackView(arrangedSubviews: parts)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        let card = MachineCardView()
        let holder = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        card.add(holder)
        column.addArrangedSubview(card)
        column.addArrangedSubview(
            MachinePage.footnote(Localized.text("The machine proves it whenever the expert's page opens and when a task starts. A task holds the lock around anything it installs or runs there, so two tasks never share a device.")))
        if canDelete {
            column.addArrangedSubview(MachinePage.pill(Localized.text("Remove")) { [weak self] in
                self?.done(nil)
                self?.navigationController?.popViewController(animated: true)
            })
        }
    }

    private func field(_ title: String, _ text: String, _ placeholder: String, onChange: @escaping (String) -> Void) -> FormField {
        let field = FormField(title: title, placeholder: placeholder)
        field.textField.text = text
        field.textField.addAction(UIAction { [weak self] action in
            onChange((action.sender as? UITextField)?.text ?? "")
            self?.syncSave()
        }, for: .editingChanged)
        return field
    }

    private func finish() {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        done(item)
        navigationController?.popViewController(animated: true)
    }
}

/// One guard: the command that has to keep passing, and — for a measured one — the number it
/// reads and its line.
@MainActor
final class ExpertGuardEditorViewController: UIViewController {
    private var item: ExpertGuard
    private let canDelete: Bool
    private let done: (ExpertGuard?) -> Void
    private var scroll: UIScrollView!
    private var column: UIStackView!

    init(item: ExpertGuard, canDelete: Bool, done: @escaping (ExpertGuard?) -> Void) {
        self.item = item
        self.canDelete = canDelete
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name.isEmpty ? ExpertWords.addGuard : item.name
        (scroll, column) = MachinePage.install(in: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ExpertWords.save, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.finish() }, menu: nil)
        render()
    }

    private var canSave: Bool { !item.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !item.command.trimmingCharacters(in: .whitespaces).isEmpty }

    private func syncSave() {
        navigationItem.rightBarButtonItem?.isEnabled = canSave
    }

    private func render() {
        MachinePage.clear(column)
        syncSave()
        var parts: [UIView] = [
            field(Localized.text("Name"), item.name, "PadLayoutTests") { [weak self] in self?.item.name = $0 },
            field(Localized.text("Command"), item.command, "xcodebuild test …") { [weak self] in self?.item.command = $0 },
            field(ExpertWords.folder, item.directory ?? "", Localized.text("The expert's folder")) { [weak self] in
                self?.item.directory = $0.isEmpty ? nil : $0
            },
            field(Localized.text("Minutes it may run"), item.timeout.map { String($0 / 60) } ?? "", "30") { [weak self] in
                self?.item.timeout = Int($0).map { $0 * 60 }
            },
        ]
        let measures = UISwitch()
        measures.accessibilityLabel = Localized.text("Measures a number")
        measures.isOn = item.metric != nil
        measures.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            self.item.metric = toggle.isOn ? ExpertGuardMetric(pattern: "([0-9.]+) ms", atMost: 100, unit: "ms") : nil
            self.render()
        }, for: .valueChanged)
        let measureRow = MachineRowView(
            title: Localized.text("Measures a number"),
            detail: Localized.text("The last match of the pattern's first group, held under or over a line."))
        measureRow.trail(measures)
        parts.append(measureRow)
        if let metric = item.metric {
            parts.append(field(Localized.text("Pattern"), metric.pattern, "first frame ([0-9.]+) ms") { [weak self] in
                self?.item.metric?.pattern = $0
            })
            parts.append(field(Localized.text("At most"), metric.atMost.map { $0.formatted() } ?? "", "100") { [weak self] in
                self?.item.metric?.atMost = Double($0.replacingOccurrences(of: ",", with: "."))
            })
            parts.append(field(Localized.text("At least"), metric.atLeast.map { $0.formatted() } ?? "", "") { [weak self] in
                self?.item.metric?.atLeast = Double($0.replacingOccurrences(of: ",", with: "."))
            })
            parts.append(field(Localized.text("Unit"), metric.unit ?? "", "ms") { [weak self] in
                self?.item.metric?.unit = $0.isEmpty ? nil : $0
            })
        }
        let stack = UIStackView(arrangedSubviews: parts)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        let holder = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        let card = MachineCardView()
        card.add(holder)
        column.addArrangedSubview(card)
        if canDelete {
            column.addArrangedSubview(MachinePage.pill(Localized.text("Remove")) { [weak self] in
                self?.done(nil)
                self?.navigationController?.popViewController(animated: true)
            })
        }
    }

    private func field(_ title: String, _ text: String, _ placeholder: String, onChange: @escaping (String) -> Void) -> FormField {
        let field = FormField(title: title, placeholder: placeholder)
        field.textField.text = text
        field.textField.addAction(UIAction { [weak self] action in
            onChange((action.sender as? UITextField)?.text ?? "")
            self?.syncSave()
        }, for: .editingChanged)
        return field
    }

    private func finish() {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty,
            !item.command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        done(item)
        navigationController?.popViewController(animated: true)
    }
}
