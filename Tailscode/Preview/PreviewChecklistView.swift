import CodingAgentKit
import TailscodeCore
import UIKit

/// The checklist a Mac is set up by, drawn from the host's own proof: one card per check, its
/// state on the glyph and the border, the host's progress under a step that is under way, and a
/// button only on a check the host can fix itself. Content on the opaque canvas, never glass.
@MainActor
final class PreviewChecklistView: UIView {
    var onFix: ((String) -> Void)?

    private let stack = UIStackView()
    private var drawn: [PreviewChecklistRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityContainerType = .list
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var rowCount: Int { stack.arrangedSubviews.count }

    func apply(_ rows: [PreviewChecklistRow]) {
        guard rows != drawn else { return }
        drawn = rows
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows {
            let card = PreviewChecklistRowView(row: row)
            card.onFix = { [weak self] fix in self?.onFix?(fix) }
            stack.addArrangedSubview(card)
        }
    }
}

@MainActor
private final class PreviewChecklistRowView: UIView {
    var onFix: ((String) -> Void)?

    private let row: PreviewChecklistRow

    init(row: PreviewChecklistRow) {
        self.row = row
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = Self.border(for: row.state).resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PreviewChecklistRowView, _) in
            view.layer.borderColor =
                Self.border(for: view.row.state).resolvedColor(with: view.traitCollection).cgColor
        }

        let glyph = Self.glyph(for: row)
        let title = UILabel()
        title.text = row.title
        title.font = Theme.Ramp.font(.rowTitleStrong)
        title.textColor = Theme.Color.label
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true

        let words = UIStackView(arrangedSubviews: [title])
        words.axis = .vertical
        words.spacing = Theme.Spacing.xs
        if let detail = row.detail {
            let label = UILabel()
            label.text = detail
            label.font = Theme.Ramp.font(.rowDetail)
            label.textColor = Theme.Color.secondaryLabel
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            words.addArrangedSubview(label)
        }
        if row.working || row.state == .working, let progress = row.progress {
            let bar = UIProgressView(progressViewStyle: .bar)
            bar.progress = Float(min(1, max(0, progress)))
            bar.progressTintColor = Theme.Color.accent
            bar.trackTintColor = Theme.Color.separator
            bar.layer.cornerRadius = 2
            bar.clipsToBounds = true
            words.addArrangedSubview(bar)
        }

        let line = UIStackView(arrangedSubviews: [glyph, words])
        line.axis = .horizontal
        line.alignment = .top
        line.spacing = Theme.Spacing.m

        let column = UIStackView(arrangedSubviews: [line])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        if row.state == .fixable, !row.working, let fix = row.fix {
            column.addArrangedSubview(fixButton(fix: fix))
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
    }

    private func fixButton(fix: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.title = row.fixLabel ?? Localized.text("Fix it")
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Ramp.font(ChatChrome.chipRole)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onFix?(fix)
            }, for: .touchUpInside)
        return button
    }

    private static func border(for state: DoctorCheck.State) -> UIColor {
        switch state {
        case .needsYou: return Theme.Color.warning
        case .failed: return Theme.Color.danger
        case .ok, .working, .fixable: return Theme.Color.separator
        }
    }

    private static func glyph(for row: PreviewChecklistRow) -> UIView {
        if row.working || row.state == .working {
            let badge = ActivityBadgeView(pointSize: 20)
            badge.working(true, spoken: Localized.text("Working"))
            badge.widthAnchor.constraint(equalToConstant: 26).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return badge
        }
        let (symbol, color, spoken) = look(of: row.state)
        let view = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        view.tintColor = color
        view.contentMode = .center
        view.isAccessibilityElement = true
        view.accessibilityLabel = spoken
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.widthAnchor.constraint(equalToConstant: 26).isActive = true
        view.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return view
    }

    private static func look(of state: DoctorCheck.State) -> (String, UIColor, String) {
        switch state {
        case .ok: return ("checkmark.circle.fill", Theme.Color.success, Localized.text("Done"))
        case .working: return ("ellipsis.circle", Theme.Color.secondaryLabel, Localized.text("Working"))
        case .needsYou: return ("exclamationmark.circle.fill", Theme.Color.warning, Localized.text("Needs you"))
        case .fixable: return ("circle.dashed", Theme.Color.secondaryLabel, Localized.text("Not done yet"))
        case .failed: return ("xmark.circle.fill", Theme.Color.danger, Localized.text("Failed"))
        }
    }
}
