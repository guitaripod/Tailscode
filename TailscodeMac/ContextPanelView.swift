import AppKit
import TailscodeCore

/// A ring filled to a share, as an image: the band wears it small before the words, the panel
/// wears it large with the share inside. One painter for both so they are the same picture.
enum ContextRing {
    static func image(fraction: Double, ink: NSColor, diameter: CGFloat, stroke: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = stroke / 2 + 0.5
            let circle = rect.insetBy(dx: inset, dy: inset)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = stroke
            ink.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let share = min(max(fraction, 0), 1)
            guard share > 0 else { return true }
            let fill = NSBezierPath()
            fill.lineWidth = stroke
            fill.lineCapStyle = .round
            fill.appendArc(
                withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                startAngle: 90, endAngle: 90 - share * 360, clockwise: true)
            ink.setStroke()
            fill.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The whole window behind the band's one ring, in a popover off the ring itself: how much of it
/// the conversation holds, what kind of tokens hold it, what is left, where the number came from,
/// and the one thing to do about it. Every number and word is `ContextFill`'s; this decides only
/// how round the ring is and how wide each band of the bar.
@MainActor
final class ContextPanelViewController: NSViewController {
    private let fill: ContextFill
    private let chatTitle: String
    private let compact: (() -> Void)?

    private static let heroSize: CGFloat = 104
    private static let trackWidth: CGFloat = 368

    init(fill: ContextFill, title: String, compact: (() -> Void)?) {
        self.fill = fill
        self.chatTitle = title
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        column.addArrangedSubview(hero())
        if !fill.slices.isEmpty { column.addArrangedSubview(bands()) }
        column.addArrangedSubview(facts())
        let source = RowKit.label(
            fill.source, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
        source.lineBreakMode = .byWordWrapping
        source.maximumNumberOfLines = 0
        column.addArrangedSubview(source)
        column.addArrangedSubview(actions())
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m)
                .isActive = true
        }

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 400),
        ])
        view = container
    }

    private var ink: NSColor {
        switch fill.tone {
        case .quiet: return MacTheme.Color.accent
        case .attention: return MacTheme.Color.warning
        case .danger: return MacTheme.Color.danger
        }
    }

    /// The ring with the share inside it, the headline beside it, the sentence under both, and the
    /// advice — when there is any — in the register the fill is in.
    private func hero() -> NSView {
        let name = RowKit.label(
            chatTitle, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        name.lineBreakMode = .byTruncatingTail

        let ring = NSImageView(
            image: ContextRing.image(
                fraction: fill.fraction ?? 0, ink: ink, diameter: Self.heroSize, stroke: 9))
        ring.translatesAutoresizingMaskIntoConstraints = false
        let share = RowKit.label(
            fill.percent.map { "\($0)%" } ?? StatusFacts.tokens(fill.used),
            font: MacTheme.Ramp.font(.metricLarge), color: MacTheme.Color.label)
        let caption = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: (fill.percent == nil ? Localized.text("tokens") : Localized.text("in use"))
                    .uppercased(),
                attributes: MacTheme.Ramp.attributes(.metricLabel, color: MacTheme.Color.tertiaryLabel)))
        let centre = NSStackView(views: [share, caption])
        centre.orientation = .vertical
        centre.alignment = .centerX
        centre.spacing = 0
        centre.translatesAutoresizingMaskIntoConstraints = false
        let dial = NSView()
        dial.translatesAutoresizingMaskIntoConstraints = false
        dial.addSubview(ring)
        dial.addSubview(centre)
        NSLayoutConstraint.activate([
            dial.widthAnchor.constraint(equalToConstant: Self.heroSize),
            dial.heightAnchor.constraint(equalToConstant: Self.heroSize),
            ring.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: dial.centerYAnchor),
            centre.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            centre.centerYAnchor.constraint(equalTo: dial.centerYAnchor),
        ])

        let headline = RowKit.label(
            fill.headline, font: MacTheme.Ramp.font(.metricLarge), color: MacTheme.Color.label)
        let summary = RowKit.label(
            fill.summary, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel)
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 0
        summary.preferredMaxLayoutWidth = 220
        let words = NSStackView(views: [headline, summary])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        let row = NSStackView(views: [dial, words])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.l

        var views: [NSView] = [name, row]
        if let advice = fill.advice {
            let label = RowKit.label(
                advice, font: MacTheme.Ramp.font(.panelDetail),
                color: fill.tone == .danger ? MacTheme.Color.danger : MacTheme.Color.warning)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = Self.trackWidth
            views.append(label)
        }
        return card(views: views)
    }

    private static func bandColor(_ id: String) -> NSColor {
        switch id {
        case "cacheRead": return MacTheme.Color.info
        case "cacheWrite": return MacTheme.Color.info.withAlphaComponent(0.55)
        case "input": return MacTheme.Color.accent
        default: return MacTheme.Color.warning
        }
    }

    /// The window as one bar, banded by what kind of tokens fill it, with a legend row per band.
    private func bands() -> NSView {
        var views: [NSView] = [
            heading(
                Localized.text("What fills it"),
                trailing: fill.window.map { Localized.text("of %@", StatusFacts.tokens($0)) })
        ]
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = MacTheme.Color.separator.cgColor
        track.layer?.cornerRadius = 4
        track.layer?.masksToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        var offset: CGFloat = 0
        for slice in fill.slices {
            let band = NSView()
            band.wantsLayer = true
            band.layer?.backgroundColor = Self.bandColor(slice.id).cgColor
            band.toolTip = "\(slice.label) · \(StatusFacts.tokens(slice.tokens))"
            band.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(band)
            let width = max(2, Self.trackWidth * min(max(slice.share, 0), 1))
            NSLayoutConstraint.activate([
                band.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: offset),
                band.topAnchor.constraint(equalTo: track.topAnchor),
                band.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                band.widthAnchor.constraint(equalToConstant: width),
            ])
            offset += width + 1
        }
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Self.trackWidth),
            track.heightAnchor.constraint(equalToConstant: 10),
        ])
        views.append(track)

        for slice in fill.slices {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = Self.bandColor(slice.id).cgColor
            swatch.layer?.cornerRadius = 2
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10),
            ])
            let name = RowKit.label(
                slice.label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
            let share = RowKit.label(
                StatusFacts.share(slice.share), font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.tertiaryLabel)
            share.setContentHuggingPriority(.required, for: .horizontal)
            let count = RowKit.label(
                StatusFacts.tokens(slice.tokens), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label)
            count.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [swatch, name, RowKit.spacer(), share, count])
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            row.alignment = .centerY
            views.append(row)
        }
        return card(views: views)
    }

    private func facts() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.l
        row.alignment = .top
        for fact in fill.facts {
            let caption = NSTextField(
                labelWithAttributedString: NSAttributedString(
                    string: fact.label.uppercased(),
                    attributes: MacTheme.Ramp.attributes(.metricLabel, color: MacTheme.Color.tertiaryLabel)))
            caption.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSStackView(views: [
                RowKit.label(fact.value, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label),
                caption,
            ])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 1
            row.addArrangedSubview(cell)
        }
        return card(views: [row])
    }

    private func actions() -> NSView {
        var views: [NSView] = [RowKit.spacer()]
        if let compact {
            let button = RowKit.ActionButton(title: Localized.text("Compact…"), action: compact)
            button.keyEquivalent = "\r"
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func heading(_ text: String, trailing: String?) -> NSView {
        let title = RowKit.label(text, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        var views: [NSView] = [title, RowKit.spacer()]
        if let trailing {
            views.append(
                RowKit.label(
                    trailing, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    private func card(views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = MacTheme.Radius.control
        stack.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        return stack
    }
}
