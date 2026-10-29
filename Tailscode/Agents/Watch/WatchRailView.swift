import TailscodeCore
import UIKit

/// A small pill in a rail: how something ended, or what runs past the wall's six tiles.
final class WatchChipView: UIView {
    enum Kind: Equatable {
        case recent(String)
        case listed(String)
        case count
    }

    let label = WatchLabel()
    private(set) var kind = Kind.count

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.borderWidth = 1
        layer.cornerCurve = .continuous
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(text: String, kind next: Kind, ink: UIColor, font: UIFont, palette: WallPalette) {
        kind = next
        label.set(text, font: font, ink: ink, lines: 1, alignment: .center)
        backgroundColor = palette.text.color(0.06)
        layer.borderColor = palette.rule.color(0.8).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: min(10, bounds.width * 0.1), dy: 0)
    }
}

/// What a rail asks to be drawn: one chip, in the words it says.
struct WatchChipSpec {
    var kind: WatchChipView.Kind
    var text: String
    var ink: WallInk
}

/// Recent endings and the sessions running past the cap, as chips along the foot of the wall. A rail
/// shows as many as fit and a `+N` chip for the rest; a narrow rail shows Recent and one
/// `+N also running` chip, so nothing is ever cut in half.
@MainActor
final class WatchRailView: UIView {
    private let recentTitle = WatchLabel()
    private let listedTitle = WatchLabel()
    private var chips: [WatchChipView] = []
    private(set) var targets: [(kind: WatchChipView.Kind, frame: CGRect)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(recentTitle)
        addSubview(listedTitle)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ context: WatchWordsContext) {
        let layout = context.layout
        let wall = context.wall
        targets = []
        guard context.style.showsRails, let recent = layout.recentRail, recent.width > 0 else {
            hideAll()
            return
        }
        let palette = context.palette
        let now = context.now
        let size = min(context.scale.type(1.7, floor: 11), recent.height * 0.5)
        let font = WatchFont.text(size, .medium)
        let recents = wall.recent.map { chip in
            WatchChipSpec(
                kind: .recent(chip.id), text: Self.recentWords(chip, now: now),
                ink: Self.outcomeInk(chip.outcome, palette))
        }
        let runningCount = wall.listed.count + wall.listedOverflow
        let listedRail = layout.listedRail
        var used = 0
        if listedRail.map({ $0.width >= 190 }) ?? false, let listedRail {
            let caption = min(size, 12)
            used = placeRail(
                recents, tail: nil, title: recentTitle, words: String(localized: "Recent"), in: recent,
                font: font, caption: caption, palette: palette, from: 0)
            let specs = wall.listed.map { chip in
                WatchChipSpec(kind: .listed(chip.id), text: Self.listedWords(chip), ink: palette.working)
            }
            let overflow = wall.listedOverflow > 0
                ? WatchChipSpec(kind: .count, text: "+\(wall.listedOverflow)", ink: palette.dim) : nil
            used = placeRail(
                specs, tail: overflow, title: listedTitle, words: String(localized: "Also running"),
                in: listedRail, font: font, caption: caption, palette: palette, from: used)
        } else {
            let whole = listedRail.map {
                WallRect(x: recent.x, y: recent.y, width: $0.maxX - recent.x, height: recent.height)
            } ?? recent
            let tail = runningCount > 0
                ? WatchChipSpec(
                    kind: .count, text: String(localized: "+\(runningCount) also running"), ink: palette.working)
                : nil
            recentTitle.isHidden = true
            listedTitle.isHidden = true
            used = place(recents, tail: tail, in: whole, font: font, palette: palette, from: 0)
        }
        for chip in chips.dropFirst(used) { chip.isHidden = true }
    }

    private func hideAll() {
        recentTitle.isHidden = true
        listedTitle.isHidden = true
        for chip in chips { chip.isHidden = true }
    }

    private func placeRail(
        _ specs: [WatchChipSpec], tail: WatchChipSpec?, title: WatchLabel, words: String, in rail: WallRect,
        font: UIFont, caption: CGFloat, palette: WallPalette, from start: Int
    ) -> Int {
        guard !specs.isEmpty || tail != nil, rail.width > 0 else {
            title.isHidden = true
            return start
        }
        title.set(
            words.uppercased(), font: WatchFont.text(caption, .semibold), ink: palette.dim.color(0.9))
        let titleWidth = title.widthForOneLine() + 8
        let showsTitle = rail.width >= 220
        title.isHidden = !showsTitle
        var room = rail
        if showsTitle {
            title.frame = CGRect(x: rail.x, y: rail.y, width: titleWidth, height: rail.height)
            room = WallRect(
                x: rail.x + titleWidth, y: rail.y, width: rail.width - titleWidth, height: rail.height)
        }
        return place(specs, tail: tail, in: room, font: font, palette: palette, from: start)
    }

    private func width(of spec: WatchChipSpec, font: UIFont, limit: Double) -> CGFloat {
        let probe = WatchLabel()
        probe.set(spec.text, font: font, ink: .clear)
        return min(CGFloat(limit), probe.widthForOneLine() + 24)
    }

    private func place(
        _ specs: [WatchChipSpec], tail: WatchChipSpec?, in rail: WallRect, font: UIFont,
        palette: WallPalette, from start: Int
    ) -> Int {
        let gap: CGFloat = 8
        let tailWidth = tail.map { width(of: $0, font: font, limit: rail.width) } ?? 0
        let budget = CGFloat(rail.width) - (tail == nil ? 0 : tailWidth + gap)
        var widths = specs.map { width(of: $0, font: font, limit: Double(budget)) }
        var count = 0
        var total: CGFloat = 0
        for item in widths {
            let next = total + (count > 0 ? gap : 0) + item
            if next > budget + 0.5 { break }
            total = next
            count += 1
        }
        if count == 0, !specs.isEmpty, budget > 40 {
            widths[0] = budget
            count = 1
            total = budget
        }
        var more: WatchChipSpec? = tail
        if tail == nil, count < specs.count {
            while count > 1, total + gap + 44 > budget + 0.5 {
                count -= 1
                total -= widths[count] + gap
            }
            more = WatchChipSpec(kind: .count, text: "+\(specs.count - count)", ink: palette.dim)
        }
        var x = CGFloat(rail.x)
        var index = start
        let shown = Array(specs.prefix(count)) + (more.map { [$0] } ?? [])
        for (offset, spec) in shown.enumerated() {
            let isMore = offset == count
            let item = isMore ? (tail == nil ? 44 : tailWidth) : widths[offset]
            if x + item > CGFloat(rail.maxX) + 0.5 { break }
            let chip = chipView(at: index)
            let frame = CGRect(x: x, y: CGFloat(rail.y), width: item, height: CGFloat(rail.height)).rounded()
            chip.frame = frame
            chip.isHidden = false
            chip.apply(text: spec.text, kind: spec.kind, ink: spec.ink.color(), font: font, palette: palette)
            if !isMore || tail != nil { targets.append((spec.kind, frame)) }
            x += item + gap
            index += 1
        }
        return index
    }

    private func chipView(at index: Int) -> WatchChipView {
        while chips.count <= index {
            let chip = WatchChipView()
            chips.append(chip)
            addSubview(chip)
        }
        return chips[index]
    }

    static func recentWords(_ chip: WallChip, now: Date) -> String {
        let mark: String
        switch chip.outcome {
        case .done?: mark = "✓"
        case .failed?: mark = "✕"
        case .stopped?: mark = "■"
        case .unknown?, nil: mark = "○"
        }
        guard let at = chip.at else { return "\(mark) \(chip.title)" }
        return "\(mark) \(chip.title) · " + String(localized: "\(AgentsWords.ago(at, now: now)) ago")
    }

    static func listedWords(_ chip: WallChip) -> String {
        guard let agents = chip.agentsLine else { return "● \(chip.title)" }
        return "● \(chip.title) · \(agents)"
    }

    static func outcomeInk(_ outcome: WallOutcome?, _ palette: WallPalette) -> WallInk {
        switch outcome {
        case .done?: return palette.finished
        case .failed?: return palette.failed
        case .stopped?, .unknown?, nil: return palette.dim
        }
    }
}
