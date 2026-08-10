import TailscodeCore
import UIKit

/// Where the phone's force is chosen. A strength setting cannot be judged by reading a
/// percentage, so this screen is built to be felt: the slider plays every stop it passes, the
/// presets land as you pick them, and each named cue can be fired on its own to hear what the
/// app will do with it.
@MainActor
final class HapticsViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let pulse = HapticPulseView()
    private let readout = UILabel()
    private let readoutDetail = UILabel()
    private let slider = HapticStrengthSlider()
    private let enabledSwitch = UISwitch()
    private var presetButtons: [(button: UIButton, value: Double)] = []
    private var cueButtons: [UIButton] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Haptics")
        view.backgroundColor = Theme.Color.groupedBackground
        build()
        syncControls()
        HapticEngine.shared.prepare()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xxl),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])

        stack.addArrangedSubview(heroCard())
        stack.addArrangedSubview(strengthCard())
        stack.addArrangedSubview(presetRow())
        stack.addArrangedSubview(switchCard())
        for group in HapticCue.Group.allCases {
            stack.addArrangedSubview(sectionLabel(group.title))
            stack.addArrangedSubview(cueCard(group.cues))
        }
        stack.addArrangedSubview(footnote())
    }

    private func heroCard() -> UIView {
        readout.font = Theme.Font.display(.title1, weight: .semibold)
        readout.adjustsFontForContentSizeCategory = true
        readout.textAlignment = .center

        readoutDetail.font = Theme.Ramp.font(.panelLabel)
        readoutDetail.textColor = Theme.Color.secondaryLabel
        readoutDetail.textAlignment = .center
        readoutDetail.numberOfLines = 0
        readoutDetail.text = String(
            localized:
                "Sending a prompt means waiting on a machine somewhere else. Tailscode reports that wait to your hand — sent, progress, a question, done — at the strength you set here."
        )

        let column = UIStackView(arrangedSubviews: [pulse, readout, readoutDetail])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Theme.Spacing.s
        return card(column)
    }

    private func strengthCard() -> UIView {
        slider.addTarget(self, action: #selector(strengthChanging), for: .valueChanged)
        slider.addTarget(self, action: #selector(strengthChosen), for: .primaryActionTriggered)
        slider.onPreview = { [weak self] strength in self?.pulse.pulse(strength: strength) }

        let ends = UIStackView(arrangedSubviews: [
            endGlyph("iphone.gen3", size: 11), spacer(), endGlyph("iphone.gen3.radiowaves.left.and.right", size: 17),
        ])
        ends.axis = .horizontal
        ends.alignment = .center

        let column = UIStackView(arrangedSubviews: [slider, ends])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        return card(column)
    }

    private func presetRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        for preset in HapticStrength.presets {
            var config = Theme.Glass.buttonConfiguration()
            config.title = preset.title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = Theme.Ramp.font(.panelDetail)
                return attributes
            }
            let button = UIButton(configuration: config)
            button.addAction(
                UIAction { [weak self] _ in self?.choose(preset.value) }, for: .touchUpInside)
            presetButtons.append((button, preset.value))
            row.addArrangedSubview(button)
        }
        return row
    }

    private func switchCard() -> UIView {
        let title = UILabel()
        title.text = String(localized: "Haptic feedback")
        title.font = Theme.Ramp.font(.cardTitle)

        let subtitle = UILabel()
        subtitle.text = String(localized: "The wait reported to your hand — sent, progress, done")
        subtitle.font = Theme.Ramp.font(.panelDetail)
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 2

        enabledSwitch.addAction(
            UIAction { [weak self] _ in self?.toggleEnabled() }, for: .valueChanged)
        enabledSwitch.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [text, enabledSwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        return card(row)
    }

    private func cueCard(_ cues: [HapticCue]) -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        for cue in cues {
            column.addArrangedSubview(cueRow(cue))
        }
        return card(column)
    }

    private func cueRow(_ cue: HapticCue) -> UIView {
        let title = UILabel()
        title.text = cue.title
        title.font = Theme.Ramp.font(.panelLabel)

        let detail = UILabel()
        detail.text = cue.detail
        detail.font = Theme.Ramp.font(.panelFootnote)
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 1

        var config = Theme.Glass.buttonConfiguration()
        config.title = String(localized: "Play")
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.panelDetail)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "Play \(cue.title)")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addAction(
            UIAction { [weak self] _ in self?.play(cue) }, for: .touchUpInside)
        cueButtons.append(button)

        let row = UIStackView(arrangedSubviews: [text, button])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        return row
    }

    private func footnote() -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text =
            HapticEngine.shared.supportsComposedHaptics
            ? String(
                localized:
                    "Each cue is a composed pattern with a rounded body and a soft attack rather than a canned tap, so it reads as a report and not an alarm. Progress ticks are coalesced: a burst of tool calls is felt as work happening, never as a rattle."
            )
            : String(
                localized:
                    "This device has no Taptic Engine, so cues fall back to the system's canned feedback and the slider can only approximate them."
            )
        return label
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.panelDetail)
        label.textColor = Theme.Color.secondaryLabel
        return label
    }

    private func endGlyph(_ symbol: String, size: CGFloat) -> UIImageView {
        let view = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)))
        view.tintColor = Theme.Color.tertiaryLabel
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// The screen's one surface idiom: content floating on glass, so the card reads as a pane of
    /// the same material the slider is cut from.
    private func card(_ content: UIView) -> UIView {
        let glass = Theme.Glass.view()
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.l),
            content.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Theme.Spacing.l),
            content.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }

    @objc private func strengthChanging() {
        updateReadout()
        updatePresetSelection()
    }

    @objc private func strengthChosen() {
        AppPreferences.hapticIntensity = slider.value
        updateReadout()
        updatePresetSelection()
    }

    private func choose(_ value: Double) {
        AppPreferences.hapticIntensity = value
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            self.slider.value = value
            self.slider.layoutIfNeeded()
        }
        HapticEngine.shared.play(.send, strength: value)
        pulse.pulse(strength: value)
        updateReadout()
        updatePresetSelection()
    }

    private func play(_ cue: HapticCue) {
        HapticEngine.shared.play(cue, strength: AppPreferences.hapticIntensity)
        pulse.pulse(strength: AppPreferences.hapticIntensity)
    }

    private func toggleEnabled() {
        AppPreferences.hapticsEnabled = enabledSwitch.isOn
        if enabledSwitch.isOn {
            HapticEngine.shared.prepare()
            HapticEngine.shared.play(.send, strength: AppPreferences.hapticIntensity)
            pulse.pulse(strength: AppPreferences.hapticIntensity)
        }
        syncControls()
    }

    private func syncControls() {
        enabledSwitch.isOn = AppPreferences.hapticsEnabled
        slider.value = AppPreferences.hapticIntensity
        updateReadout()
        updatePresetSelection()
        let live = AppPreferences.hapticsEnabled
        slider.isEnabled = live
        slider.alpha = live ? 1 : 0.4
        for button in cueButtons {
            button.isEnabled = live
        }
        for preset in presetButtons {
            preset.button.isEnabled = live
        }
    }

    private func updateReadout() {
        guard AppPreferences.hapticsEnabled else {
            readout.text = String(localized: "Off")
            return
        }
        readout.text = "\(HapticStrength.percent(slider.value))% · \(HapticStrength.label(slider.value))"
    }

    /// The chip that matches is filled rather than merely marked: at a glance the row should say
    /// which stop you are on, not which stops exist.
    private func updatePresetSelection() {
        for (button, value) in presetButtons {
            let selected = abs(value - slider.value) < 0.001
            var config =
                selected
                ? Theme.Glass.buttonConfiguration(prominent: true)
                : Theme.Glass.buttonConfiguration()
            config.title = button.configuration?.title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = Theme.Ramp.font(.panelDetail)
                return attributes
            }
            button.configuration = config
        }
    }
}
