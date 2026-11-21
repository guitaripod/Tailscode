import AppKit
import TailscodeCore

/// The one line the welcome says about how the app looks: the look a newcomer starts in beside
/// the system's own, a press apart. Everything else about themes is in Settings.
@MainActor
final class WelcomeLookRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let control = NSSegmentedControl()
    private let caption = NSTextField(labelWithString: "")
    private var look = ThemeSelection.welcomeLook

    init() {
        super.init(frame: .zero)
        title.font = MacTheme.Ramp.font(.panelFootnote)
        title.textColor = MacTheme.Color.secondaryLabel
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        caption.textColor = MacTheme.Color.tertiaryLabel
        caption.alignment = .center
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.target = self
        control.action = #selector(chosen)
        control.setAccessibilityIdentifier("welcome.look")
        let line = NSStackView(views: [title, control])
        line.orientation = .horizontal
        line.spacing = MacTheme.Spacing.s
        let column = NSStackView(views: [line, caption])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MacTheme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        restate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func restate() {
        look = ThemeSelection.welcomeLook
        title.stringValue = look.title
        caption.stringValue = look.caption
        control.segmentCount = look.choices.count
        for (index, choice) in look.choices.enumerated() {
            control.setLabel(choice.title, forSegment: index)
            control.setSelected(choice.isChosen, forSegment: index)
        }
    }

    @objc private func chosen() {
        let index = control.selectedSegment
        guard look.choices.indices.contains(index), !look.choices[index].isChosen else { return }
        ThemeSelection.setThemeID(look.choices[index].id)
        MacTheme.Chrome.apply()
    }

    /// The titles on the row, for a check that has no eyes.
    var choiceTitles: [String] { look.choices.map(\.title) }
}
