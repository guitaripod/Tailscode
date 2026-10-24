import AppKit
import CodingAgentKit
import TailscodeCore

/// Where the hour's columns sit for a width: the lane labels on the left, the last sixty minutes
/// across the rest, the right edge being now. One value for the ruler, the lanes and the legend, so
/// they cannot disagree about where ten minutes ago is.
struct AgentHourGeometry: Equatable {
    var width: CGFloat

    var labelWidth: CGFloat { min(max(190, width * 0.27), 300) }
    var chartLeft: CGFloat { labelWidth + MacTheme.Spacing.m }
    var chartRight: CGFloat { max(chartLeft + 60, width - MacTheme.Spacing.l) }
    var chartWidth: CGFloat { chartRight - chartLeft }

    func x(_ date: Date, now: Date) -> CGFloat {
        let fraction = 1 - now.timeIntervalSince(date) / AgentHour.span
        return chartLeft + CGFloat(min(max(fraction, 0), 1)) * chartWidth
    }

    static let topLane: CGFloat = 54
    static let childLane: CGFloat = 30
}

/// The lanes of the last hour, drawn in one pass: a bar per stretch in its tone, an amber one while
/// a session waited on the person, a dashed outline for work in the background, a mark where a turn
/// ended, hatching where this Mac was not looking, and the line for now at the right edge.
/// Selecting a lane fills the inspector; a resting pointer names the stretch under it.
@MainActor
final class AgentHourView: NSView, NSViewToolTipOwner {
    private(set) var hour: AgentHour?
    private(set) var now = Date()
    private(set) var selectedKey: String?
    private(set) var hovered: Int?
    private var tooltipTags: [NSView.ToolTipTag] = []
    private var tracking: NSTrackingArea?
    private var drawnShift: CGFloat = 0
    var onSelect: ((String?) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onToggleInspector: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    var lanes: [AgentHourLane] { hour?.lanes ?? [] }
    var geometry: AgentHourGeometry { AgentHourGeometry(width: bounds.width) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.list)
        setAccessibilityLabel(Localized.text("The last hour"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func height(of lanes: [AgentHourLane]) -> CGFloat {
        lanes.reduce(0) { $0 + ($1.parentID == nil ? AgentHourGeometry.topLane : AgentHourGeometry.childLane) }
    }

    func rect(ofLane index: Int) -> NSRect {
        var y: CGFloat = 0
        for (offset, lane) in lanes.enumerated() {
            let height = lane.parentID == nil ? AgentHourGeometry.topLane : AgentHourGeometry.childLane
            if offset == index { return NSRect(x: 0, y: y, width: bounds.width, height: height) }
            y += height
        }
        return .zero
    }

    func lane(at point: NSPoint) -> Int? {
        var y: CGFloat = 0
        for (offset, lane) in lanes.enumerated() {
            y += lane.parentID == nil ? AgentHourGeometry.topLane : AgentHourGeometry.childLane
            if point.y < y { return offset }
        }
        return nil
    }

    func update(_ next: AgentHour?, now: Date) {
        let structural = next?.lanes != hour?.lanes || next?.unseen != hour?.unseen
        hour = next
        self.now = now
        if structural {
            let height = next.map { Self.height(of: $0.lanes) } ?? 0
            if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
            rebuildToolTips()
            invalidateAccessibility()
        }
        needsDisplay = true
    }

    /// The clock moved: the picture is redrawn only once the line for now has travelled a whole
    /// point, which at a width of eight hundred is every four seconds and not every frame.
    func advance(to date: Date) {
        now = date
        let shift = geometry.chartWidth * CGFloat(date.timeIntervalSinceReferenceDate / AgentHour.span)
        guard abs(shift - drawnShift) >= 1 else { return }
        drawnShift = shift
        needsDisplay = true
    }

    func select(key: String?) {
        guard key != selectedKey else { return }
        selectedKey = key
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            rebuildToolTips()
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { paint(dirtyRect) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = lane(at: convert(event.locationInWindow, from: nil))
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let index = lane(at: convert(event.locationInWindow, from: nil))
        let key = index.map { Self.key(of: lanes[$0]) }
        select(key: key)
        onSelect?(key)
        if event.clickCount == 2, let key { onOpenChat?(key) }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 125: step(1)
        case 126: step(-1)
        case 36, 76: if let selectedKey { onOpenChat?(selectedKey) }
        case 49: onToggleInspector?()
        default: super.keyDown(with: event)
        }
    }

    func step(_ delta: Int) {
        guard !lanes.isEmpty else { return }
        let current = lanes.firstIndex { Self.key(of: $0) == selectedKey }
        let next = min(max((current ?? (delta > 0 ? -1 : lanes.count)) + delta, 0), lanes.count - 1)
        let key = Self.key(of: lanes[next])
        select(key: key)
        onSelect?(key)
        scrollToVisible(rect(ofLane: next))
    }

    static func key(of lane: AgentHourLane) -> String { lane.profileID + "/" + lane.sessionID }

    private func rebuildToolTips() {
        removeAllToolTips()
        tooltipTags = []
        for index in lanes.indices {
            let tag = addToolTip(rect(ofLane: index), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
            tooltipTags.append(tag)
        }
    }

    nonisolated func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        let index = data.map { Int(bitPattern: $0) - 1 }
        return MainActor.assumeIsolated {
            guard let index, let lane = lanes.indices.contains(index) ? lanes[index] : nil else { return "" }
            return tip(for: lane, at: point)
        }
    }

    func tip(for lane: AgentHourLane, at point: NSPoint) -> String {
        let geometry = geometry
        let at = lane.spans.first { span in
            point.x >= geometry.x(span.start, now: now) && point.x <= geometry.x(max(span.end, span.start), now: now) + 1
        }
        let state = at.map { Self.phaseWord($0.phase) } ?? Localized.text("Idle")
        var parts = [lane.title, state]
        if let at {
            parts.append(Localized.text("since %@", AgentsWords.ago(at.start, now: now)))
        }
        return parts.joined(separator: " · ")
    }

    static func phaseWord(_ phase: AgentHourPhase) -> String {
        switch phase {
        case .working: return Localized.text("Working")
        case .needsYou: return Localized.text("Waiting on you")
        case .background: return Localized.text("In the background")
        }
    }

    private func invalidateAccessibility() {
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func accessibilityChildren() -> [Any]? {
        lanes.enumerated().map { index, lane in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect(ofLane: index))
            element.setAccessibilityLabel(Self.spoken(lane, now: now))
            element.setAccessibilitySelected(Self.key(of: lane) == selectedKey)
            return element
        }
    }

    static func spoken(_ lane: AgentHourLane, now: Date) -> String {
        var parts = [lane.title, lane.machine]
        if let span = lane.spans.last {
            parts.append(phaseWord(span.phase) + " " + Localized.text("since %@", AgentsWords.ago(span.start, now: now)))
        }
        for mark in lane.marks {
            parts.append(markWord(mark.outcome) + " " + AgentsWords.ago(mark.at, now: now))
        }
        return parts.joined(separator: ", ")
    }

    static func markWord(_ outcome: AgentFinish.Outcome) -> String {
        switch outcome {
        case .done: return Localized.text("Done")
        case .failed: return Localized.text("Failed")
        case .stopped: return Localized.text("Stopped")
        case .unknown: return Localized.text("Finished")
        }
    }

    func laneState(_ lane: AgentHourLane) -> String? {
        guard let last = lane.spans.last, last.phase == .needsYou, let end = hour?.end,
            abs(last.end.timeIntervalSince(end)) < 2
        else { return nil }
        return Localized.text("needs you")
    }
}
