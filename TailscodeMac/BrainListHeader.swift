import AppKit
import TailscodeCore

/// The text field of the search box: it says when it takes the keyboard, because a click or a
/// Tab that puts the cursor in it is not a key the browse reducer saw.
@MainActor
final class BrainSearchField: NSTextField {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }
}

/// The search field of the list's header, once it is open: a rounded box with the magnifier, a
/// real text field that filters live, and the key that leaves it.
@MainActor
final class BrainSearchBox: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 240
    static let height: CGFloat = 26

    let field = BrainSearchField()
    private unowned let owner: BrainListView

    init(owner: BrainListView) {
        self.owner = owner
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = BrainListWords.search
        field.delegate = self
        field.setAccessibilityLabel(BrainListWords.searchSteps)
        field.onFocus = { [weak self] entered in self?.owner.searchFocusChanged(entered) }
        addSubview(field)
        retheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func retheme() {
        let painter = owner.painter
        field.font = painter.fonts.control
        field.textColor = painter.colors.ink
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let line = ceil(field.intrinsicContentSize.height)
        let cap = BrainKeyCap.width("esc", painter: owner.painter)
        field.frame = CGRect(
            x: 28, y: (bounds.height - line) / 2, width: max(0, bounds.width - 28 - cap - 14), height: line)
    }

    var isEditing: Bool { field.currentEditor() != nil }

    func controlTextDidChange(_ notification: Notification) {
        owner.searchTextChanged(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        owner.searchFocusChanged(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let key: NeuralBrowse.Key
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): key = .enter
        case #selector(NSResponder.cancelOperation(_:)): key = .escape
        case #selector(NSResponder.moveUp(_:)): key = .up
        case #selector(NSResponder.moveDown(_:)): key = .down
        default: return false
        }
        owner.searchKey(key, event: NSApp.currentEvent)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        owner.window?.makeFirstResponder(field)
    }

    override func draw(_ dirtyRect: NSRect) {
        let painter = owner.painter
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        painter.colors.canvas.setFill()
        shape.fill()
        let focused = field.currentEditor() != nil
        (focused ? painter.colors.accent : painter.colors.rule2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        BrainRowGlyphs.magnifier(
            at: CGPoint(x: 9, y: bounds.midY - 1), color: focused ? painter.colors.ink : painter.colors.dim)
        let cap = BrainKeyCap.width("esc", painter: painter)
        BrainKeyCap.draw("esc", x: bounds.width - cap - 8, midY: bounds.midY, painter: painter)
    }
}

/// The header of the step list, 36 points: a quiet "Search /" button until `/` opens the field, the
/// failed toggle when the turn has a failure, and the count at the right.
@MainActor
final class BrainListHeader: NSView {
    enum Target: Equatable {
        case search
        case failed
    }

    static let height: CGFloat = 36

    private unowned let owner: BrainListView
    let box: BrainSearchBox
    private var hover: Target?
    private var tracking: NSTrackingArea?

    init(owner: BrainListView) {
        self.owner = owner
        box = BrainSearchBox(owner: owner)
        super.init(frame: .zero)
        box.isHidden = true
        addSubview(box)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        box.frame = CGRect(
            x: 0, y: (bounds.height - BrainSearchBox.height) / 2,
            width: min(BrainSearchBox.width, max(0, bounds.width - 70)), height: BrainSearchBox.height)
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

    override func accessibilityChildren() -> [Any]? {
        var made: [Any] = []
        if !owner.searchOpen {
            let button = BrainChipElement()
            button.setAccessibilityRole(.button)
            button.setAccessibilityParent(self)
            button.setAccessibilityLabel(BrainListWords.search)
            button.setAccessibilityHelp("/")
            button.setAccessibilityFrameInParentSpace(searchRect)
            button.onPress = { [weak owner] in owner?.openSearch() }
            made.append(button)
        }
        if let rect = failedRect {
            let list = owner.snapshot.list
            let toggle = BrainChipElement()
            toggle.setAccessibilityRole(.button)
            toggle.setAccessibilityParent(self)
            toggle.setAccessibilityLabel("\(list.failedCount) \(BrainListWords.failedWord)")
            toggle.setAccessibilityValue(list.filter.failedOnly ? BrainListWords.on : BrainListWords.off)
            toggle.setAccessibilityHelp("!")
            toggle.setAccessibilityFrameInParentSpace(rect)
            toggle.onPress = { [weak owner] in owner?.toggleFailed() }
            made.append(toggle)
        }
        if !box.isHidden { made.append(box) }
        return made
    }

    private var searchWord: CGFloat {
        owner.painter.fonts.width(BrainListWords.search, owner.painter.fonts.status)
    }

    var searchRect: CGRect {
        let cap = BrainKeyCap.width("/", painter: owner.painter)
        return CGRect(x: 0, y: 0, width: 28 + searchWord + 8 + cap + 6, height: bounds.height)
    }

    /// The failed toggle after the search button, nil while the search is open or the turn has no
    /// failure to filter on.
    var failedRect: CGRect? {
        let list = owner.snapshot.list
        guard !owner.searchOpen, list.offersFailedFilter || list.filter.failedOnly else { return nil }
        let fonts = owner.painter.fonts
        let cap = BrainKeyCap.width("/", painter: owner.painter)
        let x = 28 + searchWord + 8 + cap + 14
        let width = 10 + 12 + 6 + fonts.width("\(list.failedCount)", fonts.count) + 6
            + fonts.width(BrainListWords.failedWord, fonts.status) + 10
        return CGRect(x: x, y: (bounds.height - 24) / 2, width: width, height: 24)
    }

    func target(at point: CGPoint) -> Target? {
        if let failed = failedRect, failed.contains(point) { return .failed }
        if !owner.searchOpen, searchRect.contains(point) { return .search }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let found = target(at: convert(event.locationInWindow, from: nil))
        guard found != hover else { return }
        hover = found
        needsDisplay = true
        if found != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard hover != nil else { return }
        hover = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        switch target(at: convert(event.locationInWindow, from: nil)) {
        case .search: owner.openSearch()
        case .failed: owner.toggleFailed()
        case nil: owner.host?.focusList()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let painter = owner.painter
        let colors = painter.colors
        let fonts = painter.fonts
        let list = owner.snapshot.list
        let mid = bounds.midY
        if !owner.searchOpen {
            let hot = hover == .search
            let ink = hot ? colors.ink : colors.dim
            BrainRowGlyphs.magnifier(at: CGPoint(x: 8, y: mid - 1), color: ink)
            let attributes: [NSAttributedString.Key: Any] = [.font: fonts.status, .foregroundColor: ink]
            let size = (BrainListWords.search as NSString).size(withAttributes: attributes)
            (BrainListWords.search as NSString).draw(
                at: CGPoint(x: 28, y: mid - size.height / 2), withAttributes: attributes)
            BrainKeyCap.draw("/", x: 28 + ceil(size.width) + 8, midY: mid, painter: painter, hot: hot)
        }
        if let rect = failedRect { drawFailed(rect, list: list, painter: painter) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.count, .foregroundColor: list.isFiltered ? colors.accent : colors.dim,
        ]
        let label = list.countLabel as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: bounds.width - 8 - ceil(size.width), y: mid - size.height / 2),
            withAttributes: attributes)
    }

    private func drawFailed(_ rect: CGRect, list: NeuralStepList, painter: BrainRowPainter) {
        let colors = painter.colors
        let fonts = painter.fonts
        let on = list.filter.failedOnly
        let shape = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        (on ? colors.danger.withAlphaComponent(0.18) : colors.card).setFill()
        shape.fill()
        (on ? colors.danger : (hover == .failed ? colors.accent : colors.rule2)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        BrainRowGlyphs.cross(at: CGPoint(x: rect.minX + 16, y: rect.midY), size: 4, color: colors.danger)
        var x = rect.minX + 28
        let count = "\(list.failedCount)" as NSString
        let countAttributes: [NSAttributedString.Key: Any] = [.font: fonts.count, .foregroundColor: colors.ink]
        let countSize = count.size(withAttributes: countAttributes)
        count.draw(at: CGPoint(x: x, y: rect.midY - countSize.height / 2), withAttributes: countAttributes)
        x += ceil(countSize.width) + 6
        let word = BrainListWords.failedWord as NSString
        let wordAttributes: [NSAttributedString.Key: Any] = [.font: fonts.status, .foregroundColor: colors.dim]
        let wordSize = word.size(withAttributes: wordAttributes)
        word.draw(at: CGPoint(x: x, y: rect.midY - wordSize.height / 2), withAttributes: wordAttributes)
    }
}
