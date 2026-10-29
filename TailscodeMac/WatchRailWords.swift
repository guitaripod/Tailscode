import AppKit
import TailscodeCore

/// A chip in a rail: the outcome's own mark, a title and how long ago, or what is running past the
/// watch cap. A recent one opens its chat and a listed one is watched when it is pressed, which
/// reads the session first-hand and changes nothing in it.
@MainActor
final class WatchChipView: NSView {
    let label = WatchLabel()
    private(set) var chip: WallChip?
    private(set) var isCount = false
    var onPress: ((WallChip) -> Void)?
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isCount ? nil : (frame.contains(point) ? self : nil)
    }

    private func wear(_ face: WatchFace, live: Bool) {
        layer?.backgroundColor = face.palette.text.watchColor(alpha: live ? 0.07 : 0.03).cgColor
        layer?.borderColor = face.palette.text.watchColor(alpha: live ? 0.16 : 0.08).cgColor
    }

    private static func mark(_ outcome: WallOutcome?, palette: WallPalette) -> (String, WallInk) {
        switch outcome {
        case .done?: return ("✓", palette.finished)
        case .failed?: return ("✕", palette.failed)
        case .stopped?: return ("■", palette.dim)
        case .unknown?: return ("–", palette.dim)
        case nil: return ("●", palette.working)
        }
    }

    func apply(_ next: WallChip, face: WatchFace, now: Date) {
        chip = next
        isCount = false
        let palette = face.palette
        let font = face.type.prose(1.7)
        let (glyph, ink) = Self.mark(next.outcome, palette: palette)
        var words = next.title
        if next.outcome != nil, let at = next.at {
            words += " · " + AgentsWords.ago(at, now: now)
        } else if !next.machine.isEmpty {
            words += " · " + next.machine
        }
        if next.outcome == nil, let agents = next.agentsLine { words += " · " + agents }
        let line = NSMutableAttributedString(
            string: glyph + "  ",
            attributes: [.font: font, .foregroundColor: ink.lifted(0.1).watchColor()])
        line.append(
            NSAttributedString(
                string: words, attributes: [.font: font, .foregroundColor: palette.text.watchColor()]))
        label.show(line)
        wear(face, live: true)
        toolTip = next.outcome == nil ? Localized.text("Watch this one") : Localized.text("Open this chat")
        setAccessibilityLabel(next.title + ", " + words)
    }

    func apply(count: Int, listed: Bool, face: WatchFace) {
        chip = nil
        isCount = true
        let font = face.type.prose(1.7)
        let words = listed ? Localized.text("+%d listed", count) : Localized.text("+%d more", count)
        label.show(words, font: font, ink: face.palette.dim.watchColor())
        wear(face, live: false)
        toolTip = nil
        setAccessibilityLabel(words)
    }

    var naturalWidth: CGFloat {
        label.naturalWidth + 2 * max(8, CGFloat(0.9 * (label.font?.pointSize ?? 12)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
        guard let font = label.font else { return }
        let inset = max(8, CGFloat(0.9 * font.pointSize))
        let height = WatchText.lineHeight(font) + 2
        label.frame = CGRect(
            x: inset, y: max(0, (newSize.height - height) / 2), width: max(0, newSize.width - 2 * inset),
            height: height)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = !isCount
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed, let chip else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(chip) }
    }
}

/// The two rails under the grid: the last endings, and the sessions running past the watch cap. A
/// layout that has one rail (a window wider than it is tall) gets both in it, one after the other.
@MainActor
final class WatchRailWords {
    static let poolSize = 8

    let recentTitle = WatchLabel()
    let listedTitle = WatchLabel()
    let recentChips: [WatchChipView]
    let listedChips: [WatchChipView]
    private(set) var shown = (recent: 0, listed: 0)

    init() {
        recentChips = (0..<Self.poolSize).map { _ in WatchChipView() }
        listedChips = (0..<Self.poolSize).map { _ in WatchChipView() }
    }

    func apply(
        _ wall: AgentWall, layout: WallLayout, face: WatchFace, now: Date
    ) -> [String: CGRect] {
        guard face.style.showsRails, let recentRail = layout.recentRail else {
            shown = (0, 0)
            return [:]
        }
        let titleFont = face.type.prose(1.6, weight: .semibold)
        recentTitle.show(Localized.text("Recent"), font: titleFont, ink: face.palette.dim.watchColor())
        listedTitle.show(Localized.text("Also running"), font: titleFont, ink: face.palette.dim.watchColor())
        for (index, chip) in recentChips.enumerated() where index < wall.recent.count {
            chip.apply(wall.recent[index], face: face, now: now)
        }
        for (index, chip) in listedChips.enumerated() where index < wall.listed.count {
            chip.apply(wall.listed[index], face: face, now: now)
        }
        var frames: [String: CGRect] = [:]
        let first = recentRail.watchFrame
        let second = layout.listedRail?.watchFrame
        let hasListed = !wall.listed.isEmpty || wall.listedOverflow > 0
        var cursor = first.minX
        let unit = CGFloat(layout.unit)
        if let second {
            let whole = CGRect(x: first.minX, y: first.minY, width: second.maxX - first.minX, height: first.height)
            shown.recent = flow(
                wall.recent.count, chips: recentChips, title: recentTitle, in: hasListed ? first : whole,
                overflow: 0, listed: false, face: face, unit: unit, key: "recent", into: &frames, cursor: &cursor)
            var start = second.minX
            shown.listed = flow(
                wall.listed.count, chips: listedChips, title: listedTitle, in: wall.recent.isEmpty ? whole : second,
                overflow: wall.listedOverflow, listed: true, face: face, unit: unit, key: "listed", into: &frames,
                cursor: &start)
        } else {
            shown.recent = flow(
                wall.recent.count, chips: recentChips, title: recentTitle, in: first, overflow: 0, listed: false,
                face: face, unit: unit, key: "recent", into: &frames, cursor: &cursor)
            var rest = first
            rest.origin.x = min(first.maxX, cursor + 2 * unit)
            rest.size.width = max(0, first.maxX - rest.minX)
            var start = rest.minX
            shown.listed = flow(
                wall.listed.count, chips: listedChips, title: listedTitle, in: rest,
                overflow: wall.listedOverflow, listed: true, face: face, unit: unit, key: "listed", into: &frames,
                cursor: &start)
        }
        return frames
    }

    private func flow(
        _ count: Int, chips: [WatchChipView], title: WatchLabel, in rail: CGRect, overflow: Int, listed: Bool,
        face: WatchFace, unit: CGFloat, key: String, into frames: inout [String: CGRect],
        cursor: inout CGFloat
    ) -> Int {
        guard count > 0 || overflow > 0, rail.width > 0 else { return 0 }
        let height = rail.height
        let titleWidth = title.naturalWidth + 1.4 * unit
        frames["title." + key] = CGRect(x: rail.minX, y: rail.minY, width: titleWidth, height: height)
        var x = rail.minX + titleWidth
        var shown = 0
        var hidden = overflow
        for index in 0..<min(count, chips.count) {
            let width = chips[index].naturalWidth
            let reserve = index < count - 1 || overflow > 0 ? 9 * unit : 0
            if x + width + reserve > rail.maxX {
                hidden += count - index
                break
            }
            frames["chip.\(key).\(index)"] = CGRect(x: x, y: rail.minY, width: width, height: height)
            x += width + 0.9 * unit
            shown += 1
        }
        cursor = x
        if hidden > 0, shown < chips.count {
            let counter = chips[shown]
            counter.apply(count: hidden, listed: listed, face: face)
            let width = counter.naturalWidth
            if x + width <= rail.maxX + 1 {
                frames["chip.\(key).\(shown)"] = CGRect(x: x, y: rail.minY, width: width, height: height)
                cursor = x + width
            }
        }
        return shown
    }
}
