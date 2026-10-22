import AppKit
import TailscodeCore

/// Type size in Settings: what each part of the window is set in, seen before it is chosen.
///
/// One slider per area (`TypeArea`) because the reason to enlarge a transcript is not the reason to
/// enlarge a sidebar; a preview that draws a row of each from the same roles the window draws them
/// from, so what is seen here is what the window will do; presets for the person who wants bigger
/// type and not four decisions; and a way back at every level — an area to its normal size, a
/// whole set to the default. The window answers as the hand pauses, the preview answers every
/// notch, and nothing here needs an OK.
@MainActor
final class TypeSettingsView: NSStackView {
    private let preview = TypePreview()
    private let presets = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sliders: [TypeArea: NSSlider] = [:]
    private var values: [TypeArea: NSTextField] = [:]
    private var resets: [TypeArea: NSButton] = [:]
    private let zoomValue = NSTextField(labelWithString: "")
    private let zoomReset = NSButton(title: "", target: nil, action: nil)
    private let resetAll = NSButton(title: "", target: nil, action: nil)
    private nonisolated(unsafe) var watch: (any NSObjectProtocol)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = MacTheme.Spacing.s
        build()
        refresh()
        watch = NotificationCenter.default.addObserver(
            forName: TypeScaleStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.refresh() }
        }
    }

    deinit {
        if let watch { NotificationCenter.default.removeObserver(watch) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Type size")))
        addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        presets.target = self
        presets.action = #selector(presetChosen)
        presets.setAccessibilityLabel(Localized.text("Preset"))
        addArrangedSubview(row(title: Localized.text("Preset"), detail: nil, trailing: presets))

        for area in TypeArea.allCases {
            addArrangedSubview(areaRow(area))
        }

        zoomReset.title = Localized.text("Reset")
        zoomReset.target = self
        zoomReset.action = #selector(resetZoom)
        zoomReset.bezelStyle = .rounded
        zoomReset.controlSize = .small
        zoomReset.widthAnchor.constraint(equalToConstant: 64).isActive = true
        zoomValue.font = MacTheme.Ramp.font(.metricValue)
        zoomValue.alignment = .right
        zoomValue.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let zoom = NSStackView(views: [zoomValue, zoomReset])
        zoom.orientation = .horizontal
        zoom.spacing = MacTheme.Spacing.s
        addArrangedSubview(
            row(
                title: Localized.text("Window zoom"),
                detail: Localized.text(
                    "⌘+ and ⌘− scale everything in the window, on top of the sizes above"),
                trailing: zoom))

        resetAll.title = Localized.text("Reset type")
        resetAll.target = self
        resetAll.action = #selector(resetEverything)
        resetAll.bezelStyle = .rounded
        addArrangedSubview(resetAll)

        for view in arrangedSubviews where view is NSStackView {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    /// A title and its detail on the left, whatever sets the value on the right.
    private func row(title: String, detail: String?, trailing: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [label, filler, trailing])
        line.orientation = .horizontal
        line.spacing = MacTheme.Spacing.s
        var views: [NSView] = [line]
        if let detail { views.append(MacDialogs.detailLabel(detail, wraps: true)) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        for view in views.dropFirst() {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    private func areaRow(_ area: TypeArea) -> NSView {
        let slider = NSSlider(
            value: TypeScaleStore.scale(area), minValue: TypeScale.lowest,
            maxValue: TypeScale.highest, target: self, action: #selector(sliderMoved(_:)))
        slider.isContinuous = true
        slider.altIncrementValue = TypeScale.step
        slider.identifier = NSUserInterfaceItemIdentifier(area.rawValue)
        slider.setAccessibilityLabel(area.title)
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        sliders[area] = slider

        let value = NSTextField(labelWithString: "")
        value.font = MacTheme.Ramp.font(.metricValue)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        values[area] = value

        let reset = NSButton(title: Localized.text("Default"), target: self, action: #selector(areaReset(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier(area.rawValue)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.widthAnchor.constraint(equalToConstant: 64).isActive = true
        resets[area] = reset

        let controls = NSStackView(views: [slider, value, reset])
        controls.orientation = .horizontal
        controls.spacing = MacTheme.Spacing.s
        return row(title: area.title, detail: area.detail, trailing: controls)
    }

    /// Every control, the preview and the presets menu, redrawn from the one answer the store holds.
    private func refresh() {
        let scale = TypeScaleStore.current()
        for area in TypeArea.allCases {
            sliders[area]?.doubleValue = scale[area]
            values[area]?.stringValue = TypeScale.reading(scale.percent(area))
            resets[area]?.isEnabled = !scale.isStandard(area)
        }
        let zoom = Int((MacTheme.UIScale.zoom * 100).rounded())
        zoomValue.stringValue = TypeScale.reading(zoom)
        zoomReset.isEnabled = zoom != 100
        resetAll.isEnabled = !scale.isStandard
        renderPresets(scale)
        preview.render()
    }

    private func renderPresets(_ scale: TypeScale) {
        presets.removeAllItems()
        for preset in TypePreset.allCases {
            presets.addItem(withTitle: preset.title)
            presets.lastItem?.toolTip = preset.detail
            presets.lastItem?.representedObject = preset.rawValue
        }
        if let preset = scale.preset {
            presets.selectItem(at: TypePreset.allCases.firstIndex(of: preset) ?? 0)
        } else {
            presets.menu?.addItem(.separator())
            presets.addItem(withTitle: Localized.text("Custom"))
            presets.select(presets.lastItem)
        }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, let area = TypeArea(rawValue: id) else { return }
        TypeScaleStore.set(area, to: sender.doubleValue)
    }

    @objc private func areaReset(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let area = TypeArea(rawValue: id) else { return }
        TypeScaleStore.set(area, to: TypeScale.standard)
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
            let preset = TypePreset(rawValue: raw)
        else { return }
        TypeScaleStore.set(TypeScale().applying(preset))
    }

    @objc private func resetZoom() {
        MacTheme.UIScale.reset()
        NotificationCenter.default.post(name: TypeScaleStore.didChange, object: nil)
    }

    @objc private func resetEverything() {
        TypeScaleStore.reset()
    }
}

/// A conversation in miniature, set from the roles the real one is set from: a chat row, a prompt
/// and an answer, a tool line, a code line and a shell line. Each is drawn in the area it belongs
/// to, so moving a slider moves exactly the lines that slider owns.
@MainActor
private final class TypePreview: NSView {
    private let rowTitle = NSTextField(labelWithString: "")
    private let rowDetail = NSTextField(labelWithString: "")
    private let rowAge = NSTextField(labelWithString: "")
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let answer = NSTextField(wrappingLabelWithString: "")
    private let tool = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let shell = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.borderWidth = 1

        rowTitle.stringValue = Localized.text("Fix the flaky reconnect test")
        rowTitle.lineBreakMode = .byTruncatingTail
        rowDetail.stringValue = "Fable high · studio"
        rowAge.stringValue = "9m"
        prompt.stringValue = Localized.text("Why does the build fail on CI?")
        answer.stringValue = Localized.text(
            "The linker cannot find the Kit on the runner. Pinning the checkout fixes it, and the test passes locally.")
        tool.stringValue = "▸ Bash  swift test --filter Type"
        code.stringValue = "let size = base * ratio * scale"
        shell.stringValue = "$ swift build"
        for label in [prompt, answer] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.maximumNumberOfLines = 0
        }

        let sidebar = NSStackView(views: [rowTitle, rowAge])
        sidebar.orientation = .horizontal
        sidebar.distribution = .fill
        rowTitle.setContentHuggingPriority(.init(1), for: .horizontal)
        let chat = NSStackView(views: [sidebar, rowDetail])
        chat.orientation = .vertical
        chat.alignment = .leading
        chat.spacing = 0
        sidebar.widthAnchor.constraint(equalTo: chat.widthAnchor).isActive = true

        let column = NSStackView(views: [chat, separator(), prompt, answer, tool, code, shell])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            chat.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m),
            prompt.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m),
            answer.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(Localized.text("Preview"))
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
    }

    /// Re-set every line at the size its area now has, and let the card find its own height.
    func render() {
        paint()
        rowTitle.font = MacTheme.Ramp.font(.rowTitleStrong)
        rowTitle.textColor = MacTheme.Color.label
        rowDetail.font = MacTheme.Ramp.font(.panelFootnote)
        rowDetail.textColor = MacTheme.Color.secondaryLabel
        rowAge.font = MacTheme.Ramp.font(.rowStamp)
        rowAge.textColor = MacTheme.Color.tertiaryLabel
        prompt.attributedStringValue = NSAttributedString(
            string: prompt.stringValue,
            attributes: MacTheme.Ramp.attributes(.prompt, color: MacTheme.Color.label))
        answer.attributedStringValue = NSAttributedString(
            string: answer.stringValue,
            attributes: MacTheme.Ramp.attributes(.answer, color: MacTheme.Color.label))
        tool.font = MacTheme.Ramp.font(.toolName)
        tool.textColor = MacTheme.Color.secondaryLabel
        code.font = MacTheme.Ramp.font(.code)
        code.textColor = MacTheme.Color.label
        shell.font = MacTheme.Ramp.font(.code, in: .terminal)
        shell.textColor = MacTheme.Color.secondaryLabel
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
