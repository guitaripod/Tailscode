import AppKit
import TailscodeCore

/// The machine, on one surface: which one, whether it answers, the six model files file by file, the
/// version and the queue, when it was last looked at — and the two things a person does here, look
/// again and point somewhere else. It is a popover from the toolbar's pill, so what it says is read
/// off the same studio the pill reads and the two can never disagree. Every word is Core's.
@MainActor
final class StudioMachineSheet: NSViewController, NSTextFieldDelegate {
    private let studio: MacImageStudio
    private let heading = StudioTheme.label(.panelTitle, color: MacTheme.Color.label)
    private let address = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private let summary = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    private let inherited = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 3)
    private let dot = NSImageView()
    private var factRows: [(label: NSTextField, value: NSTextField)] = []
    private var fileRows: [(mark: NSImageView, role: NSTextField, name: NSTextField, state: NSTextField)] = []
    private let filesHeading = StudioTheme.label(.sectionLabel, color: MacTheme.Color.secondaryLabel)
    private let check = NSButton(title: "", target: nil, action: nil)
    private let change = NSButton(title: ImageGenMachineWords.change, target: nil, action: nil)
    private let field = NSTextField()
    private let complaint = StudioTheme.label(.panelFootnote, color: MacTheme.Color.danger, lines: 3)
    private let apply = NSButton(title: ImageGenWords.applyTitle, target: nil, action: nil)
    private let cancel = NSButton(title: ImageGenWords.cancelTitle, target: nil, action: nil)
    private var editing = false

    private static let width: CGFloat = 400
    private static let pad: CGFloat = 18

    init(studio: MacImageStudio) {
        self.studio = studio
        super.init(nibName: nil, bundle: nil)
        studio.watch(self) { [weak self] _ in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { studio.unwatch(self) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 460))
        for view in [heading, address, summary, inherited, dot, filesHeading, check, change, field, complaint, apply, cancel] as [NSView] {
            root.addSubview(view)
        }
        for key in ["address", "version", "checked", "queue"] {
            let label = StudioTheme.label(.rowTitle, color: MacTheme.Color.secondaryLabel)
            let value = StudioTheme.label(.rowDetail, color: MacTheme.Color.label)
            value.alignment = .right
            value.setAccessibilityLabel(key)
            root.addSubview(label)
            root.addSubview(value)
            factRows.append((label, value))
        }
        for _ in ImageGenModelFile.all {
            let mark = NSImageView()
            let role = StudioTheme.label(.rowTitle, color: MacTheme.Color.label)
            let name = StudioTheme.label(.rowMeta, color: MacTheme.Color.secondaryLabel)
            name.lineBreakMode = .byTruncatingMiddle
            let state = StudioTheme.label(.rowDetail, color: MacTheme.Color.secondaryLabel)
            state.alignment = .right
            for view in [mark, role, name, state] as [NSView] { root.addSubview(view) }
            fileRows.append((mark, role, name, state))
        }
        filesHeading.stringValue = ImageGenMachineWords.modelsTitle.uppercased()
        check.bezelStyle = .rounded
        check.target = self
        check.action = #selector(checkPressed)
        change.bezelStyle = .rounded
        change.target = self
        change.action = #selector(changePressed)
        field.placeholderString = ImageGenMachineWords.addressLabel
        field.font = MacTheme.Ramp.font(.panelLabel)
        field.delegate = self
        field.target = self
        field.action = #selector(applyPressed)
        apply.bezelStyle = .rounded
        apply.target = self
        apply.action = #selector(applyPressed)
        apply.keyEquivalent = "\r"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        dot.imageScaling = .scaleProportionallyDown
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        studio.checkMachine(force: studio.sighting == nil)
    }

    private var sighting: ImageGenSighting? { studio.sighting }

    func reload() {
        guard isViewLoaded else { return }
        heading.stringValue = studio.endpoint.shortName
        address.stringValue = studio.endpoint.displayHost
        summary.stringValue = ImageGenMachineWords.summary(sighting)
        let door = ImageGenDoor(endpoint: studio.endpoint, inherited: studio.door.inherited, sighting: sighting)
        inherited.stringValue = door.inherited ? ImageGenMachineWords.inherited : ""
        inherited.isHidden = !door.inherited
        let tone = door.tone
        let ok = sighting != nil && tone == nil
        dot.image = StudioTheme.symbol(ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 20)
        dot.contentTintColor = sighting == nil ? MacTheme.Color.tertiaryLabel : (ok ? MacTheme.Color.success : (tone == .attention ? MacTheme.Color.warning : MacTheme.Color.tertiaryLabel))
        let keys = [
            (ImageGenMachineWords.addressLabel, studio.endpoint.displayHost),
            (ImageGenMachineWords.versionLabel, sighting?.version ?? ImageGenMachineWords.unknown),
            (
                ImageGenMachineWords.checkedLabel,
                sighting.map { ImageGenLibraryWords.ago($0.at) } ?? ImageGenMachineWords.neverChecked
            ),
            (
                ImageGenMachineWords.queueLabel,
                sighting?.running.map { ImageGenMachineWords.queue(running: $0) }
                    ?? ImageGenMachineWords.unknown
            ),
        ]
        for (row, fact) in zip(factRows, keys) {
            row.label.stringValue = fact.0
            row.value.stringValue = fact.1
            row.value.setAccessibilityLabel("\(fact.0), \(fact.1)")
        }
        for (row, file) in zip(fileRows, ImageGenModelFile.all) {
            let held = sighting?.holds(file)
            row.role.stringValue = file.role
            row.name.stringValue = file.name
            let word =
                held == true
                ? ImageGenMachineWords.present
                : held == false ? ImageGenMachineWords.missing : ImageGenMachineWords.unknown
            row.state.stringValue = word
            row.mark.image = StudioTheme.symbol(
                held == true ? "checkmark.circle.fill" : held == false ? "xmark.circle.fill" : "questionmark.circle",
                size: 14)
            row.mark.contentTintColor =
                held == true
                ? MacTheme.Color.success : held == false ? MacTheme.Color.danger : MacTheme.Color.tertiaryLabel
            row.mark.setAccessibilityLabel("\(file.role), \(file.name), \(word)")
        }
        check.title = studio.checking ? ImageGenMachineWords.checking : ImageGenMachineWords.checkAgain
        check.isEnabled = !studio.checking
        field.isHidden = !editing
        apply.isHidden = !editing
        cancel.isHidden = !editing
        change.isHidden = editing
        complaint.isHidden = !editing || complaint.stringValue.isEmpty
        layoutAll()
    }

    private func layoutAll() {
        let pad = Self.pad
        let width = Self.width - 2 * pad
        var y: CGFloat = Self.height(of: view) - pad
        func place(_ view: NSView, height: CGFloat, x: CGFloat = pad, width w: CGFloat? = nil) {
            y -= height
            view.frame = NSRect(x: x, y: y, width: w ?? width, height: height)
        }
        place(heading, height: 22, width: width - 30)
        dot.frame = NSRect(x: Self.width - pad - 24, y: y - 1, width: 24, height: 24)
        place(address, height: 16)
        y -= 6
        place(summary, height: 18)
        if !inherited.isHidden {
            let size = inherited.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: 100), options: [.usesLineFragmentOrigin])
            y -= 4
            place(inherited, height: ceil(size.height) + 2)
        }
        y -= 14
        for row in factRows {
            place(row.label, height: 18, width: 120)
            row.value.frame = NSRect(x: pad + 120, y: y, width: width - 120, height: 18)
            y -= 2
        }
        y -= 10
        place(filesHeading, height: 14)
        y -= 6
        for row in fileRows {
            y -= 34
            row.mark.frame = NSRect(x: pad, y: y + 10, width: 16, height: 16)
            row.role.frame = NSRect(x: pad + 26, y: y + 17, width: width - 26 - 70, height: 16)
            row.name.frame = NSRect(x: pad + 26, y: y + 1, width: width - 26 - 70, height: 14)
            row.state.frame = NSRect(x: Self.width - pad - 70, y: y + 9, width: 70, height: 16)
        }
        y -= 12
        if editing {
            place(field, height: 24)
            y -= 6
            if !complaint.isHidden {
                let size = complaint.attributedStringValue.boundingRect(
                    with: NSSize(width: width, height: 100), options: [.usesLineFragmentOrigin])
                place(complaint, height: ceil(size.height) + 2)
                y -= 6
            }
            y -= 28
            apply.frame = NSRect(x: Self.width - pad - 90, y: y, width: 90, height: 28)
            cancel.frame = NSRect(x: Self.width - pad - 90 - 8 - 90, y: y, width: 90, height: 28)
        } else {
            y -= 28
            check.frame = NSRect(x: pad, y: y, width: 130, height: 28)
            change.frame = NSRect(x: pad + 138, y: y, width: 170, height: 28)
        }
        y -= pad
        let total = Self.height(of: view) - y
        if abs(total - view.frame.height) > 0.5 {
            preferredContentSize = NSSize(width: Self.width, height: total)
            view.frame.size.height = total
            layoutAll()
        }
    }

    private static func height(of view: NSView) -> CGFloat { view.frame.height }

    @objc private func checkPressed() {
        studio.checkMachine(force: true)
    }

    @objc private func changePressed() {
        editing = true
        complaint.stringValue = ""
        field.stringValue = studio.endpoint.address
        reload()
        view.window?.makeFirstResponder(field)
    }

    @objc private func cancelPressed() {
        editing = false
        reload()
    }

    @objc private func applyPressed() {
        let reading = ImageGenEndpoint.read(field.stringValue)
        switch reading {
        case .endpoint(let endpoint):
            ImageGenStore.remember(endpoint)
            studio.point(at: endpoint)
            editing = false
            complaint.stringValue = ""
        case .empty:
            ImageGenStore.remember(nil)
            if let door = ImageGenDoor.current().endpoint { studio.point(at: door) }
            editing = false
            complaint.stringValue = ""
        default:
            complaint.stringValue = ImageGenEndpoint.complaint(reading) ?? ""
        }
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !complaint.stringValue.isEmpty else { return }
        complaint.stringValue = ""
        reload()
    }
}
