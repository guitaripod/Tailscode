import AppKit
import TailscodeCore

/// A key cap: a small outlined box with the key in it, drawn the same in the header, the hint and
/// the empty state.
@MainActor
enum BrainKeyCap {
    static let height: CGFloat = 16

    static func width(_ key: String, painter: BrainRowPainter) -> CGFloat {
        max(16, painter.fonts.width(key, painter.fonts.cap) + 8)
    }

    /// Draws the cap with its left edge at `x`, centred on `midY`, and returns its width.
    @discardableResult
    static func draw(
        _ key: String, x: CGFloat, midY: CGFloat, painter: BrainRowPainter, hot: Bool = false
    ) -> CGFloat {
        let width = width(key, painter: painter)
        let shape = NSBezierPath(
            roundedRect: CGRect(x: x + 0.5, y: midY - height / 2 + 0.5, width: width - 1, height: height - 1),
            xRadius: 4, yRadius: 4)
        shape.lineWidth = 1
        (hot ? painter.colors.accent : painter.colors.rule2).setStroke()
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: painter.fonts.cap, .foregroundColor: painter.colors.dim,
        ]
        let size = (key as NSString).size(withAttributes: attributes)
        (key as NSString).draw(
            at: CGPoint(x: x + (width - size.width) / 2, y: midY - size.height / 2),
            withAttributes: attributes)
        return width
    }
}

/// The one-line hint under the rows: four verbs with their key caps. The last, "? keys", is the
/// way a pointer opens the legend.
@MainActor
final class BrainListHint: NSView {
    private unowned let owner: BrainListView
    private var keysRect = CGRect.zero
    private var hot = false
    private var tracking: NSTrackingArea?

    init(owner: BrainListView) {
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(NeuralBrowse.hint)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let now = keysRect.contains(convert(event.locationInWindow, from: nil))
        guard now != hot else { return }
        hot = now
        needsDisplay = true
        if now { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard hot else { return }
        hot = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard keysRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        owner.toggleLegend()
    }

    override func draw(_ dirtyRect: NSRect) {
        let painter = owner.painter
        let fonts = painter.fonts
        let mid = bounds.midY
        var x: CGFloat = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.status, .foregroundColor: painter.colors.dim,
        ]
        func item(_ keys: [String], _ verb: String, hot: Bool = false) -> CGRect {
            let start = x
            for key in keys {
                x += BrainKeyCap.draw(key, x: x, midY: mid, painter: painter, hot: hot) + 3
            }
            x += 3
            let size = (verb as NSString).size(withAttributes: attributes)
            (verb as NSString).draw(at: CGPoint(x: x, y: mid - size.height / 2), withAttributes: attributes)
            x += ceil(size.width)
            let rect = CGRect(x: start, y: 0, width: x - start, height: bounds.height)
            x += 14
            return rect
        }
        _ = item(["\u{2191}", "\u{2193}"], BrainListWords.browseVerb)
        _ = item(["/"], BrainListWords.filterVerb)
        _ = item(["c"], BrainListWords.copyVerb)
        keysRect = item(["?"], BrainListWords.keysVerb, hot: hot)
    }
}

/// What lies over the rows without being one of them: the focus ring, the pill that says the list
/// stopped following a running turn, and the empty-filter state that names what matched nothing
/// and the way out. It passes every press that is not on a button of its own down to the rows.
@MainActor
final class BrainListOverlay: NSView {
    private unowned let owner: BrainListView
    private var hot: Target?
    private var tracking: NSTrackingArea?

    enum Target: Equatable {
        case pill
        case clear
    }

    init(owner: BrainListView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return target(at: local) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    var pillRect: CGRect {
        let painter = owner.painter
        let text = painter.fonts.width(BrainListWords.followingPaused, painter.fonts.pill)
        let width = text + 12 + 8 + BrainKeyCap.width("End", painter: painter) + 12
        return CGRect(x: (bounds.width - width) / 2, y: bounds.height - 8 - 26, width: width, height: 26)
    }

    private var clearGroup: (button: CGRect, orX: CGFloat, orWidth: CGFloat, capX: CGFloat) {
        let painter = owner.painter
        let fonts = painter.fonts
        let button = fonts.width(BrainListWords.clearFilters, fonts.status) + 24
        let orWidth = fonts.width(BrainListWords.orPress, fonts.status)
        let cap = BrainKeyCap.width("esc", painter: painter)
        let total = button + 12 + orWidth + 6 + cap
        let x = (bounds.width - total) / 2
        let y = bounds.height / 2 + 6
        let rect = CGRect(x: x, y: y, width: button, height: 26)
        return (rect, rect.maxX + 12, orWidth, rect.maxX + 12 + orWidth + 6)
    }

    var clearRect: CGRect { clearGroup.button }

    func target(at point: CGPoint) -> Target? {
        let list = owner.snapshot.list
        if list.visibleCount == 0, list.total > 0 {
            return clearRect.contains(point) ? .clear : nil
        }
        if list.showsFollowPill, pillRect.contains(point) { return .pill }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let found = target(at: convert(event.locationInWindow, from: nil))
        guard found != hot else { return }
        hot = found
        needsDisplay = true
        if found != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard hot != nil else { return }
        hot = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        switch target(at: convert(event.locationInWindow, from: nil)) {
        case .pill: owner.jumpToLatest()
        case .clear: owner.clearAllFilters()
        case nil: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let painter = owner.painter
        let list = owner.snapshot.list
        if list.visibleCount == 0, list.total > 0 { drawEmpty(painter, list: list) }
        if list.showsFollowPill { drawPill(painter) }
        if owner.isFocused { drawFocusRing(painter) }
    }

    private func drawFocusRing(_ painter: BrainRowPainter) {
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ring.lineWidth = 1
        painter.colors.accent.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    private func drawPill(_ painter: BrainRowPainter) {
        let rect = pillRect
        let shape = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        painter.colors.card.withAlphaComponent(0.97).setFill()
        shape.fill()
        (hot == .pill ? painter.colors.accent : painter.colors.rule2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: painter.fonts.pill, .foregroundColor: painter.colors.ink,
        ]
        let text = BrainListWords.followingPaused as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: rect.minX + 12, y: rect.midY - size.height / 2), withAttributes: attributes)
        BrainKeyCap.draw("End", x: rect.minX + 12 + ceil(size.width) + 8, midY: rect.midY, painter: painter)
    }

    private func drawEmpty(_ painter: BrainRowPainter, list: NeuralStepList) {
        let fonts = painter.fonts
        let message = BrainListWords.noMatch(BrainListWords.filterDescription(list.filter)) as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.title, .foregroundColor: painter.colors.ink, .paragraphStyle: paragraph,
        ]
        let height = fonts.lineHeight(fonts.title)
        message.draw(
            with: CGRect(x: 8, y: bounds.height / 2 - 22 - height / 2, width: bounds.width - 16, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        let group = clearGroup
        let shape = NSBezierPath(
            roundedRect: group.button.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        painter.colors.card.setFill()
        shape.fill()
        (hot == .clear ? painter.colors.accent : painter.colors.rule2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let label = BrainListWords.clearFilters as NSString
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.status, .foregroundColor: painter.colors.ink,
        ]
        let size = label.size(withAttributes: labelAttributes)
        label.draw(
            at: CGPoint(x: group.button.midX - size.width / 2, y: group.button.midY - size.height / 2),
            withAttributes: labelAttributes)
        let orAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.status, .foregroundColor: painter.colors.dim,
        ]
        let orText = BrainListWords.orPress as NSString
        let orSize = orText.size(withAttributes: orAttributes)
        orText.draw(
            at: CGPoint(x: group.orX, y: group.button.midY - orSize.height / 2), withAttributes: orAttributes)
        BrainKeyCap.draw("esc", x: group.capX, midY: group.button.midY, painter: painter)
    }
}
