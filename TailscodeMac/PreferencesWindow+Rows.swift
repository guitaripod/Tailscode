import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UserNotifications

extension PreferencesWindow {
    static var themeTitles: [String] {
        [Localized.text("System — macOS's own colours, under Liquid Glass")]
            + AppTheme.all.map { "\($0.name) — \($0.blurb)" }
    }

    static var themeIndex: Int {
        themeIDs.firstIndex(of: ThemeSelection.themeID) ?? 0
    }

    @objc func themeChanged(_ sender: NSPopUpButton) {
        ThemeSelection.setThemeID(Self.themeIDs[sender.indexOfSelectedItem])
        MacTheme.Chrome.apply()
    }

    @objc func appearanceChanged(_ sender: NSPopUpButton) {
        ThemeSelection.setAppearance(ThemeAppearance.allCases[sender.indexOfSelectedItem])
        MacTheme.Chrome.apply()
    }

    @objc func chatDensityChanged(_ sender: NSPopUpButton) {
        ChatDensitySetting.set(ChatDensity.allCases[sender.indexOfSelectedItem])
    }

    @objc func activityStyleChanged(_ sender: NSPopUpButton) {
        ActivityStyleSetting.set(ActivityStyle.allCases[sender.indexOfSelectedItem])
    }

    func popUpRow(
        title: String, subtitle: String, options: [String], selected: Int, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: options)
        popUp.selectItem(at: min(selected, max(0, options.count - 1)))
        popUp.target = self
        popUp.action = action
        popUp.setAccessibilityLabel(title)
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        popUp.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, popUp])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    func switchRow(
        title: String, subtitle: String, value: Bool, action: Selector
    ) -> NSView {
        let toggle = NSButton(checkboxWithTitle: title, target: self, action: action)
        toggle.state = value ? .on : .off
        toggle.font = MacTheme.Ramp.font(.panelLabel)
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [toggle, indented(detail)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    func stepperRow(
        title: String, subtitle: String, value: Int, lower: Int, upper: Int, step: Int,
        valueLabel: NSTextField, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        valueLabel.stringValue = "\(value)"
        valueLabel.font = MacTheme.Ramp.font(.metricValue)
        valueLabel.alignment = .right
        floorWidth(valueLabel, 44)
        let stepper = NSStepper()
        stepper.minValue = Double(lower)
        stepper.maxValue = Double(upper)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.setAccessibilityLabel(title)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, valueLabel, stepper])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    func sliderRow(
        title: String, subtitle: String, value: Double, valueLabel: NSTextField, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        valueLabel.stringValue = HapticStrength.label(value)
        valueLabel.font = MacTheme.Ramp.font(.metricValue)
        valueLabel.alignment = .right
        floorWidth(valueLabel, 60)
        let slider = NSSlider(
            value: value, minValue: HapticStrength.range.lowerBound,
            maxValue: HapticStrength.range.upperBound, target: self, action: action)
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, valueLabel, slider])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// The chord row, whose detail line is the only place this app can say what the machine did
    /// with the key — a global shortcut that was refused looks exactly like one that works from
    /// everywhere inside the app.
    func chordRow(
        title: String, button: NSButton, detail: NSTextField, monospaced: Bool = true
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        detail.font = MacTheme.Ramp.font(monospaced ? .rowDetail : .panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [row, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    func renderSummon() {
        let state = MacSummon.shared.state
        summonButton.title =
            summonRecorder == nil
            ? SummonSettings.chord.display(on: .apple) : Localized.text("Press a chord…")
        summonState.stringValue =
            [state.line(on: .apple), state.detail(on: .apple), MacSummon.shared.caution]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @objc func summonEnabledChanged(_ sender: NSButton) {
        SummonSettings.setEnabled(sender.state == .on)
        MacSummon.shared.refresh()
    }

    /// A chord is picked by pressing it. The monitor swallows the press rather than letting it
    /// reach the window, which is what makes recording ⌘-anything possible at all, and the press
    /// is judged before it is kept: a chord that would break another app on this Mac is named and
    /// refused rather than quietly claimed.
    @objc func recordSummonChord() {
        guard summonRecorder == nil else {
            stopRecordingSummon()
            return
        }
        summonRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainThread.call { self?.heardSummonChord(event) }
            return nil
        }
        renderSummon()
    }

    private func heardSummonChord(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecordingSummon()
            return
        }
        guard let key = SummonKeys.name(appleKeyCode: UInt32(event.keyCode)) else {
            summonState.stringValue =
                SummonJudge.judge(SummonChord(key: ""), on: .apple).note ?? ""
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags
        let chord = SummonChord(
            control: flags.contains(.control), alt: flags.contains(.option),
            shift: flags.contains(.shift), meta: flags.contains(.command), key: key)
        if case .refused(let reason) = SummonJudge.judge(chord, on: .apple) {
            summonState.stringValue = reason
            NSSound.beep()
            return
        }
        SummonSettings.setChord(chord)
        stopRecordingSummon()
        MacSummon.shared.refresh()
    }

    func stopRecordingSummon() {
        if let summonRecorder { NSEvent.removeMonitor(summonRecorder) }
        summonRecorder = nil
        renderSummon()
    }

    /// A fact with nothing to press: its name, and what it says beneath.
    func infoRow(title: String, detail: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let text = MacDialogs.detailLabel(detail, wraps: true)
        let column = NSStackView(views: [label, text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        text.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    func buttonRow(title: String, subtitle: String, button: NSButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// The gutter that keeps a changing number from shifting the row it sits in. The value labels
    /// outlive the column they are put in — they are the ones the change handlers write to — so a
    /// floor added on one build has to be taken back before the next one, or every presentation
    /// leaves another copy of it behind on the same label.
    private func floorWidth(_ label: NSTextField, _ width: CGFloat) {
        NSLayoutConstraint.deactivate(label.constraints.filter { $0.firstAttribute == .width })
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
    }

    func indented(_ view: NSView, by inset: CGFloat = 20) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        return wrapper
    }

    func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
