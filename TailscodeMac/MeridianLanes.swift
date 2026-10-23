import AppKit
import TailscodeCore

/// The measures the sheet's lanes are laid out from, so the rows, the hour ticks, the overlay and the
/// scrubber agree on where the day starts and ends. Every one that depends on type is read from the
/// ramp at the zoom in force, so a larger scale makes taller rows and a wider label column rather
/// than words with their ends cut off.
@MainActor
enum MeridianMetrics {
    nonisolated static let columnGap: CGFloat = 18
    nonisolated static let rowGap: CGFloat = 10
    nonisolated static let barRadius: CGFloat = 13
    nonisolated static let trackMinimum: CGFloat = 30
    nonisolated static let thumbSize = CGSize(width: 18, height: 24)
    nonisolated static let lineOverhangTop: CGFloat = 8
    nonisolated static let lineOverhangBottom: CGFloat = 4
    nonisolated static let glide: TimeInterval = 0.18
    static var tile: CGFloat { 30 * MacTheme.UIScale.factor }
    nonisolated static let tileGap: CGFloat = 10

    static var rowHeight: CGFloat {
        max(
            44, tile + 14,
            MeridianLabel.height(of: .rowTitleStrong) + MeridianLabel.height(of: .panelFootnote) + 14)
    }

    static var barHeight: CGFloat { rowHeight - 4 }

    static var tickHeight: CGFloat { max(16, MeridianLabel.height(of: .rowStamp) + 2) }

    static var trackHeight: CGFloat { max(trackMinimum, MeridianLabel.height(of: .panelFootnote) + 8) }

    static var clusterWidth: CGFloat { 3 * MeridianIconButton.side + 2 * 2 }

    static var motionAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func fit(_ field: NSTextField) -> NSSize {
        let size = field.cell?.cellSize ?? field.intrinsicContentSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// The one column every lane's words stand in, measured from the widest of them: the tile, the place
/// and who it is for, and the time there with the day it falls on. The ticks' hint, the Add-a-place
/// row and the sections under the lanes line up with its end, and it is measured again whenever the
/// lanes or the type size change.
@MainActor
struct MeridianColumn: Equatable {
    var textWidth: CGFloat
    var rightWidth: CGFloat

    var textX: CGFloat { MeridianMetrics.tile + MeridianMetrics.tileGap }

    var rightX: CGFloat { textX + textWidth + MeridianMetrics.tileGap }

    var total: CGFloat { rightX + rightWidth }

    var barX: CGFloat { total + MeridianMetrics.columnGap }

    static func measure(_ lanes: [MeridianBoard.Lane]) -> MeridianColumn {
        var text: CGFloat = 0
        var right: CGFloat = MeridianLabel.width(of: "00:00", role: .statusLine)
        for lane in lanes {
            text = max(
                text, MeridianLabel.width(of: lane.name, role: .rowTitleStrong),
                MeridianLabel.width(of: lane.subtitle, role: .panelFootnote))
            right = max(
                right, MeridianLabel.width(of: lane.time, role: .statusLine),
                MeridianLabel.width(of: lane.dayWord, role: .panelFootnote))
        }
        return MeridianColumn(textWidth: text, rightWidth: right)
    }
}

/// One lane: a tile with the body that is up there, the place and who it is for, the time the line
/// reads there and the day it falls on, and the bar. A lane the person pinned carries three small
/// controls at its trailing edge — up, down, remove — that show for a resting pointer and for the
/// keyboard alike and are disabled where they cannot act; the viewer's own lane has none.
@MainActor
final class MeridianLaneRow: NSView {
    var onRemove: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onMark: ((MeridianBoard.Mark) -> Void)?
    var canMoveUp = false {
        didSet { upButton.isEnabled = canMoveUp }
    }
    var canMoveDown = false {
        didSet { downButton.isEnabled = canMoveDown }
    }
    var column = MeridianColumn(textWidth: 0, rightWidth: 0) {
        didSet { needsLayout = true }
    }
    var reservesControls = false {
        didSet { needsLayout = true }
    }

    let bar = MeridianLaneBar()
    private let tile = TintView(fill: { MacTheme.Color.canvasRaised }, radius: 9)
    private let glyph = NSImageView()
    private let name = MeridianLabel.framed(.rowTitleStrong)
    private let subtitle = MeridianLabel.framed(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private let time = MeridianLabel.framed(.statusLine, alignment: .right)
    private let day = MeridianLabel.framed(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .right)
    private var upButton: MeridianIconButton!
    private var downButton: MeridianIconButton!
    private var removeButton: MeridianIconButton!
    private var hovering = false {
        didSet { showControls() }
    }
    private var focusInside = false {
        didSet { showControls() }
    }
    private(set) var lane: MeridianBoard.Lane?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        tile.translatesAutoresizingMaskIntoConstraints = true
        upButton = MeridianIconButton(symbol: "chevron.up", label: Localized.text("Move up")) {
            [weak self] in self?.moveLane(-1)
        }
        downButton = MeridianIconButton(symbol: "chevron.down", label: Localized.text("Move down")) {
            [weak self] in self?.moveLane(1)
        }
        removeButton = MeridianIconButton(symbol: "xmark", label: Localized.text("Remove")) {
            [weak self] in self?.removeLane()
        }
        for button in controls {
            button.alphaValue = 0
            button.onFocusChange = { [weak self] inside in self?.focusInside = inside }
        }
        bar.onMark = { [weak self] mark in self?.onMark?(mark) }
        for view in [tile, glyph, name, subtitle, time, day, bar] + controls as [NSView] { addSubview(view) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private var controls: [MeridianIconButton] { [upButton, downButton, removeButton] }

    var laneID: String { lane?.id ?? "" }

    var controlButtons: [MeridianIconButton] { controls }

    var controlsAreShown: Bool { controls.contains { $0.alphaValue > 0 } }

    func apply(lane: MeridianBoard.Lane, minutes: Int) {
        self.lane = lane
        name.stringValue = lane.name
        subtitle.stringValue = lane.subtitle
        time.stringValue = lane.time
        day.stringValue = lane.dayWord
        bar.apply(lane: lane, minutes: minutes)
        removeButton.relabel(String(format: Localized.text("Remove %@"), lane.name))
        controls.forEach { $0.isHidden = !lane.isRemovable }
        restyle()
        showControls()
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(lane.name), \(lane.time), \(lane.dayWord)")
    }

    private func showControls() {
        let visible = lane?.isRemovable == true && (hovering || focusInside)
        for button in controls { button.alphaValue = visible ? 1 : 0 }
    }

    @objc private func restyle() {
        guard let lane else { return }
        name.font = MacTheme.Ramp.font(.rowTitleStrong)
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        time.font = MacTheme.Ramp.font(.statusLine)
        day.font = MacTheme.Ramp.font(.panelFootnote)
        switch lane.isUp {
        case .some(true):
            glyph.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 15 * MacTheme.UIScale.factor, weight: .medium))
            glyph.contentTintColor = DaylightPalette.sun
        case .some(false):
            glyph.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 14 * MacTheme.UIScale.factor, weight: .medium))
            glyph.contentTintColor = DaylightPalette.moon
        case .none:
            glyph.image = nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let tileSide = MeridianMetrics.tile
        tile.frame = CGRect(x: 0, y: (bounds.height - tileSide) / 2, width: tileSide, height: tileSide)
        let glyphSize = glyph.image?.size ?? .zero
        glyph.frame = CGRect(
            x: tile.frame.midX - glyphSize.width / 2, y: tile.frame.midY - glyphSize.height / 2,
            width: glyphSize.width, height: glyphSize.height)
        let nameHeight = MeridianMetrics.fit(name).height
        let subHeight = MeridianMetrics.fit(subtitle).height
        let textTop = (bounds.height - nameHeight - subHeight) / 2
        name.frame = CGRect(x: column.textX, y: textTop, width: column.textWidth, height: nameHeight)
        subtitle.frame = CGRect(
            x: column.textX, y: textTop + nameHeight, width: column.textWidth, height: subHeight)
        let timeHeight = MeridianMetrics.fit(time).height
        let dayHeight = MeridianMetrics.fit(day).height
        let rightTop = (bounds.height - timeHeight - dayHeight) / 2
        time.frame = CGRect(x: column.rightX, y: rightTop, width: column.rightWidth, height: timeHeight)
        day.frame = CGRect(
            x: column.rightX, y: rightTop + timeHeight, width: column.rightWidth, height: dayHeight)
        let reserve = reservesControls ? MeridianMetrics.clusterWidth + MeridianMetrics.rowGap : 0
        let barX = column.barX
        bar.frame = CGRect(x: barX, y: 0, width: max(0, bounds.width - barX - reserve), height: bounds.height)
        var x = bounds.width - MeridianMetrics.clusterWidth
        for button in controls {
            button.frame = CGRect(
                x: x, y: (bounds.height - MeridianIconButton.side) / 2, width: MeridianIconButton.side,
                height: MeridianIconButton.side)
            x += MeridianIconButton.side + 2
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is MeridianIconButton || hit is MeridianMarkView ? hit : self
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) { hovering = false }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let lane, lane.isRemovable else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(String, Selector, Bool)] = [
            (Localized.text("Remove"), #selector(removePressed), true),
            (Localized.text("Move up"), #selector(moveLaneUp), canMoveUp),
            (Localized.text("Move down"), #selector(moveLaneDown), canMoveDown),
        ]
        for (title, action, enabled) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let lane, lane.isRemovable else { return nil }
        var actions = [
            NSAccessibilityCustomAction(name: Localized.text("Remove")) { [weak self] in
                self?.removeLane()
                return true
            }
        ]
        if canMoveUp {
            actions.append(
                NSAccessibilityCustomAction(name: Localized.text("Move up")) { [weak self] in
                    self?.moveLane(-1)
                    return true
                })
        }
        if canMoveDown {
            actions.append(
                NSAccessibilityCustomAction(name: Localized.text("Move down")) { [weak self] in
                    self?.moveLane(1)
                    return true
                })
        }
        return actions
    }

    private func removeLane() {
        guard let lane, lane.isRemovable else { return }
        onRemove?(lane.id)
    }

    private func moveLane(_ delta: Int) {
        guard let lane, lane.isRemovable else { return }
        onMove?(lane.id, delta)
    }

    @objc private func removePressed() { removeLane() }

    @objc private func moveLaneUp() { moveLane(-1) }

    @objc private func moveLaneDown() { moveLane(1) }
}

/// Every lane, the hour ticks, what lies over them and the scrubber, placed by frame in one column so
/// the bars, the line and the track can never disagree about where an hour is. The label column is
/// measured from the widest place, the rows are as tall as their type, and the hint beside the track
/// wraps in the column instead of being cut. A press on a lane's bar reads the pointer as a moment,
/// exactly as the track does.
@MainActor
final class MeridianLanesView: NSView {
    var onScrub: ((Double, Bool) -> Void)?
    var onStep: ((Int) -> Void)?
    var onRemove: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onMark: ((MeridianBoard.Mark) -> Void)?
    var onColumn: ((MeridianColumn) -> Void)?

    private let ticks = MeridianTickRow()
    private let overlay = MeridianOverlay()
    let track = MeridianTrackView()
    private let hint = MeridianLabel.framed(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private(set) var rows: [MeridianLaneRow] = []
    private(set) var board: MeridianBoard?
    private(set) var column = MeridianColumn(textWidth: 0, rightWidth: 0)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hint.stringValue = Localized.text("Drag to read every desk at that moment")
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        track.onScrub = { [weak self] fraction, animated in self?.onScrub?(fraction, animated) }
        track.onStep = { [weak self] delta in self?.onStep?(delta) }
        addSubview(ticks)
        addSubview(overlay)
        addSubview(hint)
        addSubview(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var overlayView: MeridianOverlay { overlay }

    var laneCount: Int { board?.lanes.count ?? 0 }

    private var reservesControls: Bool { board?.lanes.contains { $0.isRemovable } == true }

    private var hintHeight: CGFloat {
        MeridianLabel.height(
            wrapping: hint.stringValue, role: .panelFootnote, width: column.total)
    }

    private var trackRowHeight: CGFloat { max(MeridianMetrics.trackHeight, hintHeight) }

    override var intrinsicContentSize: NSSize {
        let lanes = CGFloat(max(laneCount, 1))
        let stack = lanes * MeridianMetrics.rowHeight + (lanes - 1) * MeridianMetrics.rowGap
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: MeridianMetrics.tickHeight + MeridianMetrics.rowGap + stack + MeridianMetrics.rowGap
                + trackRowHeight)
    }

    private var lanesTop: CGFloat { MeridianMetrics.tickHeight + MeridianMetrics.rowGap }

    private var lanesBottom: CGFloat {
        lanesTop + CGFloat(rows.count) * MeridianMetrics.rowHeight
            + CGFloat(max(0, rows.count - 1)) * MeridianMetrics.rowGap
    }

    private var barRight: CGFloat {
        bounds.width - (reservesControls ? MeridianMetrics.clusterWidth + MeridianMetrics.rowGap : 0)
    }

    func apply(_ board: MeridianBoard, animateLine: Bool) {
        let changed = rows.map(\.laneID) != board.lanes.map(\.id)
        if changed {
            rows.forEach { $0.removeFromSuperview() }
            rows = board.lanes.map { _ in
                let row = MeridianLaneRow()
                row.onRemove = { [weak self] id in self?.onRemove?(id) }
                row.onMove = { [weak self] id, delta in self?.onMove?(id, delta) }
                row.onMark = { [weak self] mark in self?.onMark?(mark) }
                addSubview(row, positioned: .below, relativeTo: overlay)
                return row
            }
        }
        self.board = board
        hint.font = MacTheme.Ramp.font(.panelFootnote)
        let measured = MeridianColumn.measure(board.lanes)
        let columnChanged = measured != column
        column = measured
        let pinned = board.lanes.filter(\.isRemovable)
        for (row, lane) in zip(rows, board.lanes) {
            row.column = measured
            row.reservesControls = reservesControls
            row.canMoveUp = lane.isRemovable && pinned.first?.id != lane.id
            row.canMoveDown = lane.isRemovable && pinned.last?.id != lane.id
            row.apply(lane: lane, minutes: board.minutes)
        }
        ticks.apply(board.ticks)
        invalidateIntrinsicContentSize()
        if changed || columnChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
            onColumn?(measured)
        }
        overlay.apply(board: board)
        overlay.setLine(board.linePosition, animated: animateLine)
        track.apply(fraction: board.linePosition, value: board.head, animated: animateLine)
    }

    override func layout() {
        super.layout()
        let barX = column.barX
        let barWidth = max(0, barRight - barX)
        ticks.frame = CGRect(x: barX, y: 0, width: barWidth, height: MeridianMetrics.tickHeight)
        var y = lanesTop
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: MeridianMetrics.rowHeight)
            y += MeridianMetrics.rowHeight + MeridianMetrics.rowGap
        }
        let trackY = rows.isEmpty ? y : lanesBottom + MeridianMetrics.rowGap
        let rowHeight = trackRowHeight
        track.frame = CGRect(
            x: barX, y: trackY + (rowHeight - MeridianMetrics.trackHeight) / 2, width: barWidth,
            height: MeridianMetrics.trackHeight)
        hint.frame = CGRect(
            x: 0, y: trackY + (rowHeight - hintHeight) / 2, width: column.total, height: hintHeight)
        let overlayTop = lanesTop - MeridianMetrics.lineOverhangTop
        let overlayHeight = lanesBottom - lanesTop + MeridianMetrics.lineOverhangTop
            + MeridianMetrics.lineOverhangBottom
        overlay.frame = CGRect(x: barX, y: overlayTop, width: barWidth, height: overlayHeight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let fraction = barFraction(event) else { return super.mouseDown(with: event) }
        onScrub?(fraction, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fraction = barFraction(event, clamped: true) else { return }
        onScrub?(fraction, false)
    }

    private func barFraction(_ event: NSEvent, clamped: Bool = false) -> Double? {
        let point = convert(event.locationInWindow, from: nil)
        let barX = column.barX
        let width = barRight - barX
        guard width > 0 else { return nil }
        let inside = point.x >= barX && point.x <= barRight && point.y >= lanesTop && point.y <= lanesBottom
        guard inside || clamped else { return nil }
        return min(max(Double((point.x - barX) / width), 0), 1)
    }
}
