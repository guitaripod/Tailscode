import TailscodeCore
import UIKit

/// A ring filled to a share, as an image: the chip wears it small before the words, the sheet
/// wears it large with the share inside. One painter for both so they are the same picture.
enum ContextRing {
    static func image(fraction: Double, ink: UIColor, diameter: CGFloat, stroke: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let inset = stroke / 2 + 0.5
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let track = UIBezierPath(ovalIn: circle)
            track.lineWidth = stroke
            ink.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let share = min(max(fraction, 0), 1)
            guard share > 0 else { return }
            let start = -CGFloat.pi / 2
            let fill = UIBezierPath(
                arcCenter: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                startAngle: start, endAngle: start + share * 2 * .pi, clockwise: true)
            fill.lineWidth = stroke
            fill.lineCapStyle = .round
            ink.setStroke()
            fill.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The whole window behind the chip's one ring: how much of it the conversation holds, what kind
/// of tokens hold it, what is left, where the number came from, and the one thing to do about it.
///
/// Every number and word is `ContextFill`'s — the same sections the desks draw, in a sheet, because
/// a phone has no band to hang a popover from. This decides only how round the ring is and how wide
/// each band of the bar.
final class ContextViewController: UIViewController {
    private let fill: ContextFill
    private let chatTitle: String
    private let compact: (() -> Void)?
    private let scroll = UIScrollView()
    private var rail: ReadableRail?
    private let column = UIStackView()

    private static let heroSize: CGFloat = 132

    init(fill: ContextFill, title: String, compact: (() -> Void)?) {
        self.fill = fill
        self.chatTitle = title
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = fill.title
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.xl,
            trailing: Theme.Spacing.m)

        column.addArrangedSubview(hero())
        if !fill.slices.isEmpty { column.addArrangedSubview(bands()) }
        column.addArrangedSubview(facts())
        let source = label(fill.source, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
        column.addArrangedSubview(source)
        if compact != nil { column.addArrangedSubview(compactButton()) }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        rail = ReadableRail(
            host: view,
            compact: [column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)],
            regular: [column.widthAnchor.constraint(equalTo: view.readableContentGuide.widthAnchor)])
    }

    private var ink: UIColor {
        switch fill.tone {
        case .quiet: return Theme.Color.accent
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        }
    }

    /// The ring with the share inside it, the headline beside it, the sentence under both, and the
    /// advice — when there is any — in the register the fill is in.
    private func hero() -> UIView {
        let name = label(chatTitle, role: .panelDetail, color: Theme.Color.secondaryLabel)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail

        let ring = UIImageView(
            image: ContextRing.image(
                fraction: fill.fraction ?? 0, ink: ink, diameter: Self.heroSize, stroke: 11))
        ring.translatesAutoresizingMaskIntoConstraints = false
        let share = label(
            fill.percent.map { "\($0)%" } ?? StatusFacts.tokens(fill.used), role: .metricLarge,
            color: Theme.Color.label)
        share.textAlignment = .center
        let caption = label(
            (fill.percent == nil ? String(localized: "tokens") : String(localized: "in use")).uppercased(),
            role: .metricLabel, color: Theme.Color.tertiaryLabel)
        caption.textAlignment = .center
        let centre = UIStackView(arrangedSubviews: [share, caption])
        centre.axis = .vertical
        centre.alignment = .center
        centre.spacing = 0
        centre.translatesAutoresizingMaskIntoConstraints = false
        let dial = UIView()
        dial.translatesAutoresizingMaskIntoConstraints = false
        dial.addSubview(ring)
        dial.addSubview(centre)
        dial.isAccessibilityElement = true
        dial.accessibilityLabel = fill.accessibilityLabel
        NSLayoutConstraint.activate([
            dial.widthAnchor.constraint(equalToConstant: Self.heroSize),
            dial.heightAnchor.constraint(equalToConstant: Self.heroSize),
            ring.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: dial.centerYAnchor),
            centre.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            centre.centerYAnchor.constraint(equalTo: dial.centerYAnchor),
            centre.widthAnchor.constraint(lessThanOrEqualTo: dial.widthAnchor, constant: -28),
        ])

        let headline = label(fill.headline, role: .metricLarge, color: Theme.Color.label)
        headline.adjustsFontSizeToFitWidth = true
        headline.minimumScaleFactor = 0.7
        let summary = label(fill.summary, role: .panelDetail, color: Theme.Color.secondaryLabel)
        let words = UIStackView(arrangedSubviews: [headline, summary])
        words.axis = .vertical
        words.spacing = 4
        let row = UIStackView(arrangedSubviews: [dial, words])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.l

        var views: [UIView] = [name, row]
        if let advice = fill.advice {
            views.append(
                label(
                    advice, role: .panelDetail,
                    color: fill.tone == .danger ? Theme.Color.danger : Theme.Color.warning))
        }
        return card(views)
    }

    private static func bandColor(_ id: String) -> UIColor {
        switch id {
        case "cacheRead": return Theme.Color.info
        case "cacheWrite": return Theme.Color.info.withAlphaComponent(0.55)
        case "input": return Theme.Color.accent
        default: return Theme.Color.warning
        }
    }

    /// The window as one bar, banded by what kind of tokens fill it, with a legend row per band.
    private func bands() -> UIView {
        var views: [UIView] = [
            heading(
                String(localized: "What fills it"),
                trailing: fill.window.map { String(localized: "of \(StatusFacts.tokens($0))") })
        ]
        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 5
        track.layer.masksToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 10).isActive = true
        var leading = track.leadingAnchor
        var offset: CGFloat = 0
        for slice in fill.slices {
            let band = UIView()
            band.backgroundColor = Self.bandColor(slice.id)
            band.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(band)
            NSLayoutConstraint.activate([
                band.leadingAnchor.constraint(equalTo: leading, constant: offset),
                band.topAnchor.constraint(equalTo: track.topAnchor),
                band.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                band.widthAnchor.constraint(
                    equalTo: track.widthAnchor, multiplier: max(0.005, min(1, slice.share))),
            ])
            leading = band.trailingAnchor
            offset = 1
        }
        track.isAccessibilityElement = true
        track.accessibilityLabel = fill.slices.map { "\($0.label) \(StatusFacts.tokens($0.tokens))" }
            .joined(separator: ", ")
        views.append(track)

        for slice in fill.slices {
            let swatch = UIView()
            swatch.backgroundColor = Self.bandColor(slice.id)
            swatch.layer.cornerRadius = 2
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10),
            ])
            let name = label(slice.label, role: .metricDetail, color: Theme.Color.label)
            let share = label(
                "\(Int((slice.share * 100).rounded()))%", role: .panelFootnote,
                color: Theme.Color.tertiaryLabel)
            share.setContentHuggingPriority(.required, for: .horizontal)
            let count = label(StatusFacts.tokens(slice.tokens), role: .metricValue, color: Theme.Color.label)
            count.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [swatch, name, UIView(), share, count])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = Theme.Spacing.s
            views.append(row)
        }
        return card(views)
    }

    private func facts() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        for fact in fill.facts {
            let cell = UIStackView(arrangedSubviews: [
                label(fact.value, role: .metricValue, color: Theme.Color.label),
                label(fact.label.uppercased(), role: .panelFootnote, color: Theme.Color.tertiaryLabel),
            ])
            cell.axis = .vertical
            cell.spacing = 1
            row.addArrangedSubview(cell)
        }
        return card([row])
    }

    private func compactButton() -> UIView {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = String(localized: "Compact…")
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.compact?() }, for: .touchUpInside)
        return button
    }

    private func heading(_ text: String, trailing: String?) -> UIView {
        var views: [UIView] = [label(text, role: .panelTitle, color: Theme.Color.label), UIView()]
        if let trailing {
            views.append(label(trailing, role: .panelFootnote, color: Theme.Color.tertiaryLabel))
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .firstBaseline
        return row
    }

    private func card(_ views: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        stack.backgroundColor = Theme.Color.secondaryBackground
        stack.layer.cornerRadius = Theme.Radius.card
        stack.layer.cornerCurve = .continuous
        return stack
    }

    private func label(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(role, color: color))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}
