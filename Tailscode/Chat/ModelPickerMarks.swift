import TailscodeCore
import UIKit

/// What a pick would run at, as the pill draws it: the same five bars, and the level's word in the
/// model's own spelling beside them when there is room.
private final class LevelMark: UIView {
    init(reading: ModelRowLevel, withWord: Bool) {
        let meter = EffortMeterView(
            reading: EffortMeterView.Reading(
                heat: reading.heat, level: reading.level, isPower: reading.isPower,
                isServer: reading.isServer, isEmber: reading.isEmber))
        let size = EffortMeterView.size
        meter.frame = CGRect(x: 0, y: (28 - size.height) / 2, width: size.width, height: size.height)
        var width = size.width
        var label: UILabel?
        if withWord, let word = reading.word {
            let text = UILabel()
            text.attributedText = ModelDialPill.effortWord(
                word, isPower: reading.isPower, font: Theme.Ramp.font(.rowMeta))
            if !reading.isPower {
                text.textColor = Theme.Color.secondaryLabel
            }
            let fitted = text.intrinsicContentSize
            text.frame = CGRect(
                x: size.width + 5, y: (28 - fitted.height) / 2, width: fitted.width, height: fitted.height)
            width += 5 + fitted.width
            label = text
        }
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 28))
        addSubview(meter)
        if let label { addSubview(label) }
        isAccessibilityElement = false
        translatesAutoresizingMaskIntoConstraints = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The right-hand end of a row: what ran out or what it reads, where it runs, the star, and the
/// chevron —
/// laid out once, inside a width it was told about, so nothing is ever drawn on top of anything.
/// Marks are dropped from the least decisive end rather than shrunk, and the row's own name keeps
/// whatever is left; a screen reader still hears all of them from the cell's label.
final class RowMarksView: UIView {
    private static let gap: CGFloat = 5
    private static let slotWidth: CGFloat = 15

    init(
        row: ModelChooserRow, slots: [ModelFact], room: CGFloat, star: UIView?,
        onExpand: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        var tail: [UIView] = []
        if let star { tail.append(star) }
        if row.isSelected {
            let tick = UIImageView(
                image: UIImage(
                    systemName: "checkmark",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 13, weight: .semibold)))
            tick.tintColor = Theme.Color.accent
            tick.accessibilityLabel = String(localized: "Currently chosen")
            tick.frame = CGRect(x: 0, y: 0, width: 20, height: 28)
            tick.contentMode = .center
            tail.append(tick)
        }
        if row.canExpand {
            let chevron = UIButton(type: .system)
            chevron.setImage(
                UIImage(
                    systemName: row.isExpanded ? "chevron.down" : "chevron.right",
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 11, weight: .semibold)), for: .normal)
            chevron.tintColor = Theme.Color.secondaryLabel
            chevron.accessibilityLabel = String(localized: "The other providers that run it")
            chevron.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            chevron.addAction(UIAction { _ in onExpand() }, for: .touchUpInside)
            tail.append(chevron)
        }
        let spoken = max(0, room - tail.reduce(0) { $0 + $1.frame.width + Self.gap })

        var pieces: [UIView] = []
        if let reading = row.reading, reading.takesLevels {
            pieces.append(LevelMark(reading: reading, withWord: spoken >= 150))
        }
        if let capabilities = Self.capabilities(row: row, slots: slots) {
            pieces.append(capabilities)
        }

        var width: CGFloat = 0
        var kept: [UIView] = []
        for piece in pieces {
            let size = piece.frame.width > 0 ? piece.frame.width : piece.intrinsicContentSize.width
            let next = width + size + (kept.isEmpty ? 0 : Self.gap)
            guard next <= spoken else { continue }
            width = next
            kept.append(piece)
        }

        let height: CGFloat = 28
        var x: CGFloat = 0
        for piece in kept + tail {
            let size =
                piece.frame.width > 0
                ? piece.frame.size
                : piece.intrinsicContentSize
            piece.frame = CGRect(
                x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            addSubview(piece)
            x += size.width + Self.gap
        }
        let total = max(0, x - Self.gap)
        isAccessibilityElement = false
        frame = CGRect(x: 0, y: 0, width: total, height: height)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: total),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// One slot per capability the catalog can tell models apart by, empty where a model lacks it,
    /// so the symbols read down the list as a column rather than a huddle that shifts per row.
    private static func capabilities(row: ModelChooserRow, slots: [ModelFact]) -> UIView? {
        guard !slots.isEmpty, case .candidate = row.kind else { return nil }
        let worn = Set(row.facts.filter(\.isCapability))
        let strip = FixedWidthView(
            width: CGFloat(slots.count) * slotWidth + CGFloat(slots.count - 1) * gap, height: 18)
        var x: CGFloat = 0
        for slot in slots {
            defer { x += slotWidth + gap }
            guard worn.contains(slot) else { continue }
            let icon = UIImageView(
                image: UIImage(
                    systemName: slot.symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)))
            icon.tintColor = Theme.Color.tertiaryLabel
            icon.contentMode = .center
            icon.frame = CGRect(x: x, y: 0, width: slotWidth, height: 18)
            strip.addSubview(icon)
        }
        return strip
    }
}
