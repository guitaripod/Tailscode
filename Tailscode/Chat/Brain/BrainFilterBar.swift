import TailscodeCore
import UIKit

/// The zone filters as a row of glyph-and-count chips under the head: SAID first, which is the
/// only chip that carries its word, then the zones the turn has steps in. A press turns a zone's
/// filter on or off and a long press shows only that zone. In a narrow row the failed toggle is the
/// last chip; beside the head it lives in the list's header.
@MainActor
final class BrainFilterBar: UIView {
    var onZone: ((NeuralZone, Bool) -> Void)?
    var onFailed: (() -> Void)?

    private let scroll = UIScrollView()
    private var chips: [BrainZoneChip] = []
    private let failed = BrainFailedChip()
    private var signature = ""
    private var includesFailed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.clipsToBounds = false
        addSubview(scroll)
        failed.onTap = { [weak self] in self?.onFailed?() }
        scroll.addSubview(failed)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The chips for a list. `showsFailed` puts the failed toggle at the end of the row.
    func configure(list: NeuralStepList, showsFailed: Bool) {
        let items = list.zoneChips
        let key = items.map { "\($0.zone)\($0.count)\($0.isOn)" }.joined(separator: ",")
            + "|\(showsFailed)|\(list.failedCount)|\(list.filter.failedOnly)"
        guard key != signature else { return }
        signature = key
        includesFailed = showsFailed && list.offersFailedFilter
        while chips.count < items.count {
            let chip = BrainZoneChip(height: 28)
            scroll.addSubview(chip)
            chips.append(chip)
        }
        for (index, chip) in chips.enumerated() {
            guard index < items.count else {
                chip.isHidden = true
                continue
            }
            let item = items[index]
            chip.isHidden = false
            chip.configure(
                BrainZoneChip.Content(
                    zone: item.zone, count: item.count, tone: .zone, showsWord: item.zone == .say,
                    isOn: item.isOn, word: item.label))
            chip.onTap = { [weak self] in self?.onZone?(item.zone, false) }
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.35
            chip.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.forEach {
                chip.removeGestureRecognizer($0)
            }
            chip.addGestureRecognizer(hold)
            chip.tag = item.zone.rawValue
        }
        failed.isHidden = !includesFailed
        failed.configure(count: list.failedCount, isOn: list.filter.failedOnly)
        setNeedsLayout()
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let zone = NeuralZone(rawValue: gesture.view?.tag ?? -1) else { return }
        Theme.Haptics.notch()
        onZone?(zone, true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        var x: CGFloat = 0
        for chip in chips where !chip.isHidden {
            let size = chip.intrinsicContentSize
            chip.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 6
        }
        if includesFailed {
            let size = failed.intrinsicContentSize
            failed.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width
        }
        scroll.contentSize = CGSize(width: max(x, bounds.width), height: bounds.height)
        scroll.isScrollEnabled = x > bounds.width + 1
    }
}

/// The failed toggle: a cross and how many steps stayed failed, filling when it is on.
@MainActor
final class BrainFailedChip: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()
    private var isOn = false
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        icon.contentMode = .center
        label.isUserInteractionEnabled = false
        addSubview(icon)
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        Theme.Haptics.selection()
        onTap?()
    }

    func configure(count: Int, isOn on: Bool) {
        isOn = on
        icon.image = BrainCanvas.image("xmark", size: 10, weight: .bold)?
            .withTintColor(Theme.Color.danger.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        label.attributedText = NSAttributedString(
            string: String(count), attributes: Theme.Ramp.attributes(.chip, color: Theme.Color.label))
        layer.borderColor = (on ? Theme.Color.danger : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        backgroundColor = on ? Theme.Color.danger.wash(0.14) : .clear
        accessibilityLabel = Localized.text("Failed steps, %lld", count)
        accessibilityTraits = on ? [.button, .selected] : .button
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 12 + 14 + 5 + ceil(label.attributedText?.size().width ?? 8) + 10, height: 28)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 8, y: 0, width: 14, height: bounds.height)
        let size = label.attributedText?.size() ?? .zero
        label.frame = CGRect(x: 27, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 1, height: ceil(size.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }
}
