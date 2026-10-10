import AppKit
import TailscodeCore

/// The Studio's sheet: the generic host holding the Studio's workspace under the toolbar row of lane
/// switch, machine pill, queue count and Done. Nothing here is the host's own — the scrim, the frame,
/// the motion and the keyboard are `SheetView`'s — so the Studio is one instance of what the media
/// viewer is another of.
@MainActor
final class StudioSheetView: SheetView {
    let workspace: StudioWorkspaceView
    let toolbar: StudioSheetToolbar
    private static let gapUnderToolbar: CGFloat = 4

    init() {
        let workspace = StudioWorkspaceView(scoped: false)
        let toolbar = StudioSheetToolbar()
        self.workspace = workspace
        self.toolbar = toolbar
        super.init(
            content: workspace, toolbar: toolbar, dialogName: StudioSheetWords.dialogName,
            closeLabel: StudioSheetWords.closeLabel)
        workspace.paintsGround = false
        workspace.hostChromeHeight = CGFloat(StudioSheetMetrics.toolbarHeight)
        workspace.topPadding = Self.gapUnderToolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The controls that lived in the panel's title bar, in the sheet's own row: the lane switch leading,
/// the machine pill in the middle, the queue count and Done trailing. A sheet has no title bar to lend
/// them one, so they are placed by frame on the sheet's canvas.
@MainActor
final class StudioSheetToolbar: NSView {
    let lanes = NSSegmentedControl(
        labels: StudioLaneID.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let pill = StudioMachinePill()
    let queue = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    let done = NSButton(title: ImageGenSurface.dismissTitle, target: nil, action: nil)

    private static let edge: CGFloat = 12
    private static let spacing: CGFloat = 12

    init() {
        super.init(frame: .zero)
        lanes.segmentStyle = .automatic
        lanes.setAccessibilityLabel(Localized.text("Studio lane"))
        done.bezelStyle = .rounded
        done.keyEquivalent = ""
        for view in [lanes, pill, queue, done] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let lanesSize = lanes.intrinsicContentSize
        let doneSize = done.intrinsicContentSize
        queue.sizeToFit()
        let queueSize = queue.frame.size
        let midY = bounds.height / 2
        lanes.frame = NSRect(
            x: Self.edge, y: midY - lanesSize.height / 2, width: lanesSize.width, height: lanesSize.height)
        done.frame = NSRect(
            x: bounds.width - Self.edge - doneSize.width, y: midY - doneSize.height / 2,
            width: doneSize.width, height: doneSize.height)
        queue.frame = NSRect(
            x: done.frame.minX - Self.spacing - queueSize.width, y: midY - queueSize.height / 2,
            width: queueSize.width, height: queueSize.height)
        let room = queue.frame.minX - lanes.frame.maxX - 2 * Self.spacing
        let pillSize = pill.intrinsicContentSize
        let width = min(pillSize.width, max(0, room))
        let centred = (bounds.width - width) / 2
        let x = min(max(centred, lanes.frame.maxX + Self.spacing), queue.frame.minX - Self.spacing - width)
        pill.frame = NSRect(x: x, y: midY - pillSize.height / 2, width: width, height: pillSize.height)
    }

    /// The count and the lane's hint, redrawn when the lane says something changed.
    func refresh(queue count: Int, hint: String?) {
        queue.stringValue = "\(ImageGenMachineWords.queueLabel) \(count)"
        queue.setAccessibilityLabel(queue.stringValue)
        done.toolTip = hint
        done.setAccessibilityHelp(hint)
        needsLayout = true
    }
}
